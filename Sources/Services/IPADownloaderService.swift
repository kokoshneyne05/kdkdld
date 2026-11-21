import Foundation
import ZIPFoundation

final class IPADownloaderService: NSObject, URLSessionDownloadDelegate {
    static let shared = IPADownloaderService()

    private var progressHandler: ((Double, Int64, Int64) -> Void)?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var activeTask: URLSessionDownloadTask?

    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    var ipaDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("IPAs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func listSavedIPAs() -> [LocalIPAFile] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: ipaDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .compactMap { url -> LocalIPAFile? in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let date = values?.contentModificationDate ?? Date()
                return LocalIPAFile(
                    id: url.lastPathComponent,
                    url: url,
                    fileName: url.lastPathComponent,
                    sizeBytes: size,
                    modifiedAt: date
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func deleteIPA(_ file: LocalIPAFile) throws {
        try FileManager.default.removeItem(at: file.url)
    }

    func cancelActiveDownload() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - Download + Patch Pipeline

    func downloadAndPatchIPA(
        info: AppDownloadInfo,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onPatching: @escaping () -> Void
    ) async throws -> LocalIPAFile {
        self.progressHandler = onProgress

        let tempFileURL = try await downloadRawFile(from: info.downloadURL)

        let safeName = sanitizeFilename("\(info.name)_\(info.shortVersion)_\(info.adamId)")
        let targetURL = ipaDirectoryURL.appendingPathComponent("\(safeName).ipa")

        let fm = FileManager.default
        if fm.fileExists(atPath: targetURL.path) {
            try fm.removeItem(at: targetURL)
        }
        try fm.moveItem(at: tempFileURL, to: targetURL)

        onPatching()

        // Inject iTunesMetadata.plist + FairPlay SINF files inside the IPA archive on a background thread
        try await Task.detached(priority: .userInitiated) {
            try Self.patchIPAArchive(at: targetURL, info: info)
        }.value

        let values = try targetURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return LocalIPAFile(
            id: targetURL.lastPathComponent,
            url: targetURL,
            fileName: targetURL.lastPathComponent,
            sizeBytes: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? Date()
        )
    }

    private func downloadRawFile(from url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            self.downloadContinuation = continuation
            let task = downloadSession.downloadTask(with: url)
            self.activeTask = task
            task.resume()
        }
    }

    // MARK: - ZIPFoundation SINF & Metadata Patching

    private static func patchIPAArchive(at ipaURL: URL, info: AppDownloadInfo) throws {
        let archive: Archive
        do {
            archive = try Archive(url: ipaURL, accessMode: .update)
        } catch {
            throw StoreError.zipPatchFailed("Не удалось открыть IPA как ZIP: \(error.localizedDescription)")
        }

        // 1. Write iTunesMetadata.plist into IPA root
        try upsertEntry(in: archive, path: "iTunesMetadata.plist", data: info.metadataPlistData)

        // 2. Locate Payload/<AppName>.app/ bundle prefix
        guard let appBundlePrefix = findAppBundlePrefix(in: archive) else {
            throw StoreError.zipPatchFailed("Не найден .app внутри папки Payload/.")
        }

        // 3. Inject FairPlay SINF files if provided by Apple
        guard !info.sinfs.isEmpty else { return }

        // Check SC_Info/Manifest.plist first (standard Apple App Store SINF manifest)
        let manifestPath = "\(appBundlePrefix)SC_Info/Manifest.plist"
        if let manifestData = extractData(from: archive, path: manifestPath),
           let manifest = try? PropertyListSerialization.propertyList(from: manifestData, options: [], format: nil) as? [String: Any],
           let sinfPaths = manifest["SinfPaths"] as? [String],
           !sinfPaths.isEmpty {
            for (index, relativeSinfPath) in sinfPaths.enumerated() {
                guard index < info.sinfs.count else { break }
                let cleanRel = relativeSinfPath.hasPrefix("/") ? String(relativeSinfPath.dropFirst()) : relativeSinfPath
                let fullPath = "\(appBundlePrefix)\(cleanRel)"
                try upsertEntry(in: archive, path: fullPath, data: info.sinfs[index].sinf)
            }
            return
        }

        // Fallback: read CFBundleExecutable from Info.plist -> Payload/<App>.app/SC_Info/<Executable>.sinf
        let infoPlistPath = "\(appBundlePrefix)Info.plist"
        if let infoData = extractData(from: archive, path: infoPlistPath),
           let infoDict = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
           let executableName = infoDict["CFBundleExecutable"] as? String,
           !executableName.isEmpty,
           let firstSinf = info.sinfs.first {
            let fullPath = "\(appBundlePrefix)SC_Info/\(executableName).sinf"
            try upsertEntry(in: archive, path: fullPath, data: firstSinf.sinf)
        }
    }

    private static func findAppBundlePrefix(in archive: Archive) -> String? {
        for entry in archive {
            let path = entry.path
            if path.hasPrefix("Payload/"), let range = path.range(of: ".app/") {
                return String(path[..<range.upperBound])
            }
        }
        return nil
    }

    private static func extractData(from archive: Archive, path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var output = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                output.append(chunk)
            }
            return output
        } catch {
            return nil
        }
    }

    private static func upsertEntry(in archive: Archive, path: String, data: Data) throws {
        if let existing = archive[path] {
            try archive.remove(existing)
        }
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            bufferSize: 16384,
            provider: { position, size -> Data in
                let start = Int(position)
                let end = min(start + size, data.count)
                if start >= data.count {
                    return Data()
                }
                return data.subdata(in: start..<end)
            }
        )
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        progressHandler?(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fm = FileManager.default
        let stableTemp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa")
        do {
            if fm.fileExists(atPath: stableTemp.path) {
                try fm.removeItem(at: stableTemp)
            }
            try fm.copyItem(at: location, to: stableTemp)
            activeTask = nil
            downloadContinuation?.resume(returning: stableTemp)
            downloadContinuation = nil
        } catch {
            activeTask = nil
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        activeTask = nil
        downloadContinuation?.resume(throwing: StoreError.networkError(error.localizedDescription))
        downloadContinuation = nil
    }
}
