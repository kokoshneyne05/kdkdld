import Foundation
import MapleSAP

struct SideStoreAnisetteServer: Codable, Identifiable, Hashable {
    var id: String { address }
    let name: String
    let address: String
    let kind: Int?

    static let serversJSONURL = URL(string: "https://raw.githubusercontent.com/SideStore/anisette-servers/main/servers.json")!

    static let builtInServers: [SideStoreAnisetteServer] = [
        SideStoreAnisetteServer(name: "iDH Server (SideStore)", address: "https://ani.idevicehacked.com", kind: 0),
        SideStoreAnisetteServer(name: "SideStore Official", address: "https://ani.sidestore.io", kind: 0),
        SideStoreAnisetteServer(name: "neoarz", address: "https://ani.neoarz.com", kind: 0),
        SideStoreAnisetteServer(name: "pythonplayer123", address: "https://ani3server.fly.dev", kind: 0),
        SideStoreAnisetteServer(name: "Jayden's Server", address: "https://ani.jaydenha.uk", kind: 0),
        SideStoreAnisetteServer(name: "crystall1nedev", address: "https://anisette.crystall1ne.dev", kind: 0),
        SideStoreAnisetteServer(name: "ethxn omnisette", address: "https://omni.ethxn.xyz", kind: 0),
        SideStoreAnisetteServer(name: "uwucloud", address: "https://ani.uwucloud.fun", kind: 0),
        SideStoreAnisetteServer(name: "koremi", address: "https://ani.sjwon0368.dpdns.org", kind: 0),
    ]
}

struct SideStoreAnisettePayload: Sendable {
    let serverAddress: String
    let serverName: String
    let headers: [String: String]
    let latencyMs: Int

    var oneTimePassword: String { headers["X-Apple-I-MD"] ?? "" }
    var machineID: String { headers["X-Apple-I-MD-M"] ?? "" }
    var routingInfo: String { headers["X-Apple-I-MD-RINFO"] ?? "" }
    var clientInfo: String { headers["X-MMe-Client-Info"] ?? "" }
    var deviceID: String { headers["X-Mme-Device-Id"] ?? "" }

    /// Converts SideStore Anisette headers to Apple Store authentication/commerce headers
    /// following majd/ipatool's header mapping (X-Apple-I-MD -> X-Apple-AMD, X-Apple-I-MD-M -> X-Apple-AMD-M).
    func storeHeaders() -> [String: String] {
        var mapped: [String: String] = [:]
        for (key, value) in headers where !value.isEmpty {
            let lower = key.lowercased()
            if lower == "x-apple-i-md" {
                mapped["X-Apple-AMD"] = value
            } else if lower == "x-apple-i-md-m" {
                mapped["X-Apple-AMD-M"] = value
            } else {
                mapped[key] = value
            }
        }
        return mapped
    }
}

enum SideStoreAnisetteError: Error, LocalizedError {
    case noServers
    case allServersFailed(String)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .noServers:
            return "Список серверов SideStore Anisette пуст."
        case .allServersFailed(let detail):
            return "Ни один SideStore Anisette сервер не ответил: \(detail)"
        case .invalidPayload(let server):
            return "Сервер \(server) вернул неполный Anisette-ответ (нет X-Apple-I-MD / X-Apple-I-MD-M)."
        }
    }
}

private struct SideStoreServersResponse: Decodable {
    let servers: [SideStoreAnisetteServer]
}

actor SideStoreAnisetteClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    func fetchOfficialServerList() async -> [SideStoreAnisetteServer] {
        var req = URLRequest(url: SideStoreAnisetteServer.serversJSONURL)
        req.setValue("SideStore/1.0 IPAVault/3.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return SideStoreAnisetteServer.builtInServers
            }
            if let wrapped = try? JSONDecoder().decode(SideStoreServersResponse.self, from: data),
               !wrapped.servers.isEmpty {
                return wrapped.servers.filter { $0.address.hasPrefix("https://") }
            }
            if let list = try? JSONDecoder().decode([SideStoreAnisetteServer].self, from: data),
               !list.isEmpty {
                return list.filter { $0.address.hasPrefix("https://") }
            }
        } catch {
            return SideStoreAnisetteServer.builtInServers
        }
        return SideStoreAnisetteServer.builtInServers
    }

    func fetchWithFailover(
        preferredAddress: String,
        servers: [SideStoreAnisetteServer]
    ) async throws -> SideStoreAnisettePayload {
        var ordered: [SideStoreAnisetteServer] = []
        let trimmedPreferred = preferredAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreferred.isEmpty {
            if let match = servers.first(where: { $0.address == trimmedPreferred }) {
                ordered.append(match)
            } else if trimmedPreferred.hasPrefix("https://") {
                ordered.append(SideStoreAnisetteServer(name: "Custom Server", address: trimmedPreferred, kind: 0))
            }
        }
        for server in servers where !ordered.contains(where: { $0.address == server.address }) {
            ordered.append(server)
        }
        if ordered.isEmpty {
            ordered = SideStoreAnisetteServer.builtInServers
        }
        guard !ordered.isEmpty else { throw SideStoreAnisetteError.noServers }

        var errors: [String] = []
        for server in ordered {
            do {
                return try await fetchSingle(server: server)
            } catch {
                errors.append("\(server.name): \(error.localizedDescription)")
            }
        }
        throw SideStoreAnisetteError.allServersFailed(errors.prefix(3).joined(separator: " | "))
    }

    func fetchSingle(server: SideStoreAnisetteServer) async throws -> SideStoreAnisettePayload {
        guard let url = URL(string: server.address), url.scheme == "https" else {
            throw SideStoreAnisetteError.invalidPayload(server.address)
        }
        let started = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("SideStore/1.0 (iOS; IPAVault)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SideStoreAnisetteError.invalidPayload(server.address)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SideStoreAnisetteError.invalidPayload(server.address)
        }
        var headers: [String: String] = [:]
        for (key, value) in raw {
            if let text = value as? String {
                headers[key] = text
            } else if let num = value as? NSNumber {
                headers[key] = num.stringValue
            }
        }
        guard let md = headers["X-Apple-I-MD"], !md.isEmpty,
              let mdm = headers["X-Apple-I-MD-M"], !mdm.isEmpty else {
            throw SideStoreAnisetteError.invalidPayload(server.address)
        }
        let elapsedMs = max(1, Int(Date().timeIntervalSince(started) * 1000))
        return SideStoreAnisettePayload(
            serverAddress: server.address,
            serverName: server.name,
            headers: headers,
            latencyMs: elapsedMs
        )
    }
}

/// Wraps AppleAuthenticationTransport to inject live SideStore Anisette headers
/// into Apple Store authentication and commerce endpoints while keeping cookies
/// and FairPlay SAP (X-Apple-ActionSignature) untouched.
final class AnisetteAuthenticatedTransport: AuthenticationTransport {
    private let base: AppleAuthenticationTransport
    private let lock = NSLock()
    private var anisetteHeaders: [String: String]

    init(
        cookies: [StoreCookie] = [],
        isolatedConnections: Bool = false,
        anisetteHeaders: [String: String] = [:]
    ) {
        self.base = AppleAuthenticationTransport(cookies: cookies, isolatedConnections: isolatedConnections)
        self.anisetteHeaders = anisetteHeaders
    }

    func updateAnisetteHeaders(_ headers: [String: String]) {
        lock.lock()
        self.anisetteHeaders = headers
        lock.unlock()
    }

    func close() {
        base.close()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var enriched = request
        let headersToApply: [String: String] = {
            lock.lock()
            defer { lock.unlock() }
            return anisetteHeaders
        }()

        if !headersToApply.isEmpty, let host = request.url?.host?.lowercased(),
           host.hasSuffix(".itunes.apple.com") || host.hasSuffix(".apple.com") {
            let path = request.url?.path ?? ""
            // Attach SideStore Anisette headers to Apple Store auth & commerce endpoints (not bag.xml / public lookup)
            if path != "/bag.xml" && path != "/lookup" && !path.contains("MZStorePlatform") {
                for (key, value) in headersToApply {
                    if enriched.value(forHTTPHeaderField: key) == nil {
                        enriched.setValue(value, forHTTPHeaderField: key)
                    }
                }
            }
        }
        return try await base.send(enriched)
    }

    func cookies() async -> [StoreCookie] {
        await base.cookies()
    }

    func cookieDiagnostic(for url: URL) async -> String {
        let baseDiag = await base.cookieDiagnostic(for: url)
        let count: Int = {
            lock.lock()
            defer { lock.unlock() }
            return anisetteHeaders.count
        }()
        return "\(baseDiag); anisette-headers=\(count)"
    }
}
