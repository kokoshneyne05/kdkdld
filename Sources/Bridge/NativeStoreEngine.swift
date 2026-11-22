import Foundation
import MapleSAP

final class NativeSAPGuest: AppleSAPGuest {
    let executionMode = SAPExecutionMode.interpreted
    private var handle: UInt64 = 0
    private let cache: URL

    init() throws {
        cache = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MapleSAP", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    func initialize(hardwareID: Data) throws {
        guard handle == 0 else { throw SAPError.invalidState }
        let status = cache.path.withCString { path in
            hardwareID.withUnsafeBytes { bytes in
                WaffleSAPOpen(
                    UnsafeMutablePointer(mutating: path),
                    UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress),
                    hardwareID.count,
                    &handle
                )
            }
        }
        guard status == 0 else { throw SAPError.nativeRuntime(Int32(status)) }
    }

    func exchange(version: UInt32, hardwareID: Data, input: Data) throws -> (output: Data, state: Int32) {
        guard handle != 0 else { throw SAPError.invalidState }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        var state: Int32 = -1
        let status = input.withUnsafeBytes { bytes in
            WaffleSAPExchange(
                handle,
                version,
                UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress),
                input.count,
                &output,
                &length,
                &state
            )
        }
        defer { WaffleSAPFree(output, length) }
        guard status == 0 else { throw SAPError.nativeRuntime(Int32(status)) }
        guard length <= 16 << 20 else { throw SAPError.invalidExchange }
        return (output.map { Data(bytes: $0, count: length) } ?? Data(), state)
    }

    func sign(body: Data) throws -> Data {
        guard handle != 0 else { throw SAPError.invalidState }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = body.withUnsafeBytes { bytes in
            WaffleSAPSign(
                handle,
                UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress),
                body.count,
                &output,
                &length
            )
        }
        defer { WaffleSAPFree(output, length) }
        guard status == 0 else { throw SAPError.nativeRuntime(Int32(status)) }
        guard let output = output, length > 0, length <= 16 << 20 else { throw SAPError.emptySignature }
        return Data(bytes: output, count: length)
    }

    func close() {
        if handle != 0 {
            WaffleSAPClose(handle)
            handle = 0
        }
    }

    deinit { close() }
}

final class NativeKBSyncGenerator: KBSyncGenerator {
    func generate(identity: MachineIdentity, dsid: UInt64) throws -> Data {
        let cache = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MapleSAP", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = cache.path.withCString { path in
            identity.hardwareID.withUnsafeBytes { bytes in
                WaffleSAPKBSync(
                    UnsafeMutablePointer(mutating: path),
                    UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress),
                    identity.hardwareID.count,
                    dsid,
                    &output,
                    &length
                )
            }
        }
        defer { WaffleSAPFree(output, length) }
        guard status == 0 else { throw StoreError.native(Int32(status)) }
        guard let output = output, length > 0, length <= 16 << 20 else { throw StoreError.native(8) }
        return Data(bytes: output, count: length)
    }
}

enum NativePackage {
    struct Parameters: Encodable {
        let appID: String
        let bundleID: String
        let externalVersionID: String
        let md5: String
        let metadata: Data
        let sinfs: [Data]
    }

    struct Info: Codable, Sendable {
        let bundleID: String
        let version: String
        let build: String?
    }

    static func prepare(source: URL, destination: URL, app: StoreApp, descriptor: StoreDownload) throws -> Info {
        let input = try JSONEncoder().encode(
            Parameters(
                appID: app.id,
                bundleID: app.bundleID,
                externalVersionID: descriptor.externalVersionID,
                md5: descriptor.md5,
                metadata: descriptor.metadata,
                sinfs: descriptor.sinfs
            )
        )
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destPath in
                input.withUnsafeBytes { bytes in
                    WafflePrepareIPA(
                        UnsafeMutablePointer(mutating: sourcePath),
                        UnsafeMutablePointer(mutating: destPath),
                        UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress),
                        input.count,
                        &output,
                        &length
                    )
                }
            }
        }
        defer { WaffleSAPFree(output, length) }
        guard status == 0 else { throw StoreError.native(Int32(status)) }
        guard let output = output, length > 0, length < 4096 else { throw StoreError.packageInvalid }
        return try JSONDecoder().decode(Info.self, from: Data(bytes: output, count: length))
    }
}

struct CDNHTTPFailure: Error, LocalizedError {
    let status: Int
    let retryAfter: String?

    var errorDescription: String? {
        "CDN вернул HTTP \(status)"
    }
}

final class CDNDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double, Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var redirects = 0
    private var result: Result<URL, Error>?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(destination: URL, progress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws -> URL {
        _ = try CDNPolicy.validate(url.absoluteString)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let download = session.downloadTask(with: request)
                task = download
                lock.unlock()
                download.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let active = task
        lock.unlock()
        active?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > 8 << 30 {
            downloadTask.cancel()
            return
        }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)
            : 0.0
        progress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirects += 1
        guard redirects <= 8,
              let url = request.url,
              (try? CDNPolicy.validate(url.absoluteString)) != nil else {
            completionHandler(nil)
            return
        }
        var clean = URLRequest(url: url)
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(clean)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw StoreError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw CDNHTTPFailure(
                    status: response.statusCode,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                )
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0,
                  size <= 8 << 30,
                  response.expectedContentLength < 0 || response.expectedContentLength == Int64(size) else {
                throw StoreError.packageInvalid
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled {
            try? FileManager.default.removeItem(at: destination)
            cont?.resume(throwing: CancellationError())
        } else if let error = error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(with: result ?? .failure(StoreError.invalidResponse))
        }
        session.finishTasksAndInvalidate()
    }
}
