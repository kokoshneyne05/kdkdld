import ApplePackage
import Foundation

// MARK: - Auth Engine Selection

enum AuthEngineMode: String, Codable, CaseIterable, Identifiable {
    case applePackage = "applePackage"
    case urlSessionSAP = "urlSessionSAP"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applePackage:
            return "ApplePackage (SAP + AsyncHTTP)"
        case .urlSessionSAP:
            return "URLSession + SAP Bridge (iOS VPN)"
        }
    }

    var shortName: String {
        switch self {
        case .applePackage:
            return "ApplePackage"
        case .urlSessionSAP:
            return "URLSession+SAP"
        }
    }

    var subtitle: String {
        switch self {
        case .applePackage:
            return "Эталонный движок на базе Lakr233/ApplePackage с полным SAP-обменом и AsyncHTTPClient."
        case .urlSessionSAP:
            return "Нативный сетевой стек iOS (учитывает системный VPN и прокси) с общей подписью SAPSigner."
        }
    }
}

// MARK: - Cookie & Account Models

struct StoredCookie: Codable, Equatable, Hashable {
    var name: String
    var value: String
    var path: String
    var domain: String?
    var expiresAt: TimeInterval?
    var httpOnly: Bool
    var secure: Bool

    init(
        name: String,
        value: String,
        path: String = "/",
        domain: String? = nil,
        expiresAt: TimeInterval? = nil,
        httpOnly: Bool = false,
        secure: Bool = true
    ) {
        self.name = name
        self.value = value
        self.path = path
        self.domain = domain
        self.expiresAt = expiresAt
        self.httpOnly = httpOnly
        self.secure = secure
    }

    init(from cookie: ApplePackage.Cookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.path = cookie.path
        self.domain = cookie.domain
        self.expiresAt = cookie.expiresAt
        self.httpOnly = cookie.httpOnly
        self.secure = cookie.secure
    }

    init(from httpCookie: HTTPCookie) {
        self.name = httpCookie.name
        self.value = httpCookie.value
        self.path = httpCookie.path
        self.domain = httpCookie.domain
        self.expiresAt = httpCookie.expiresDate?.timeIntervalSince1970
        self.httpOnly = httpCookie.isHTTPOnly
        self.secure = httpCookie.isSecure
    }

    func toApplePackageCookie() -> ApplePackage.Cookie {
        ApplePackage.Cookie(
            name: name,
            value: value,
            path: path,
            domain: domain,
            expiresAt: expiresAt,
            httpOnly: httpOnly,
            secure: secure
        )
    }
}

extension Array where Element == StoredCookie {
    mutating func merge(_ incoming: [StoredCookie]) {
        for cookie in incoming {
            if let idx = firstIndex(where: {
                $0.name == cookie.name &&
                ($0.domain ?? "").lowercased() == (cookie.domain ?? "").lowercased() &&
                $0.path == cookie.path
            }) {
                self[idx] = cookie
            } else {
                append(cookie)
            }
        }
    }

    func cookieHeaderValue(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date().timeIntervalSince1970

        let pairs: [String] = compactMap { cookie in
            guard !cookie.name.isEmpty, !cookie.value.isEmpty else { return nil }
            if let exp = cookie.expiresAt, exp <= now { return nil }
            if cookie.secure && url.scheme?.lowercased() != "https" { return nil }

            if let rawDomain = cookie.domain?.lowercased(), !rawDomain.isEmpty {
                let normalizedDomain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
                let hostMatches = host == normalizedDomain || host.hasSuffix("." + normalizedDomain)
                if !hostMatches { return nil }
            }

            if cookie.path != "/" && !path.hasPrefix(cookie.path) {
                return nil
            }

            return "\(cookie.name)=\(cookie.value)"
        }

        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
}

struct AppleAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var email: String
    var appleId: String
    var firstName: String
    var lastName: String
    var dsid: String
    var passwordToken: String
    var pod: String
    var storeId: String
    var storeFront: String
    var countryCode: String
    var guid: String
    var cookies: [StoredCookie]
    var engineUsed: AuthEngineMode
    var createdAt: Date

    var displayName: String {
        let full = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? email : full
    }

    func toApplePackageAccount() -> ApplePackage.Account {
        ApplePackage.Account(
            email: email,
            password: "",
            appleId: appleId.isEmpty ? email : appleId,
            store: storeId,
            firstName: firstName,
            lastName: lastName,
            passwordToken: passwordToken,
            directoryServicesIdentifier: dsid,
            cookie: cookies.map { $0.toApplePackageCookie() },
            pod: pod
        )
    }
}

// MARK: - Storefront Regions

struct StorefrontRegion: Identifiable, Hashable {
    let code: String
    let name: String
    let storefrontId: String

    var id: String { code }

    static let all: [StorefrontRegion] = [
        StorefrontRegion(code: "RU", name: "Россия (RU)", storefrontId: "143469"),
        StorefrontRegion(code: "US", name: "США (US)", storefrontId: "143441"),
        StorefrontRegion(code: "TR", name: "Турция (TR)", storefrontId: "143480"),
        StorefrontRegion(code: "KZ", name: "Казахстан (KZ)", storefrontId: "143517"),
        StorefrontRegion(code: "UA", name: "Украина (UA)", storefrontId: "143492"),
        StorefrontRegion(code: "GB", name: "Великобритания (GB)", storefrontId: "143444"),
        StorefrontRegion(code: "DE", name: "Германия (DE)", storefrontId: "143443"),
        StorefrontRegion(code: "JP", name: "Япония (JP)", storefrontId: "143462"),
        StorefrontRegion(code: "CN", name: "Китай (CN)", storefrontId: "143465"),
        StorefrontRegion(code: "HK", name: "Гонконг (HK)", storefrontId: "143463"),
        StorefrontRegion(code: "KR", name: "Южная Корея (KR)", storefrontId: "143466"),
        StorefrontRegion(code: "CA", name: "Канада (CA)", storefrontId: "143455"),
        StorefrontRegion(code: "FR", name: "Франция (FR)", storefrontId: "143442"),
        StorefrontRegion(code: "PL", name: "Польша (PL)", storefrontId: "143478"),
        StorefrontRegion(code: "AE", name: "ОАЭ (AE)", storefrontId: "143481"),
        StorefrontRegion(code: "IN", name: "Индия (IN)", storefrontId: "143467")
    ]

    static func storefrontId(for countryCode: String) -> String {
        if let official = Configuration.storeId(for: countryCode.uppercased()) {
            return official
        }
        return all.first(where: { $0.code.uppercased() == countryCode.uppercased() })?.storefrontId ?? "143441"
    }

    static func countryCode(forStoreId storeId: String) -> String? {
        let base = storeId.components(separatedBy: "-").first ?? storeId
        if let official = Configuration.countryCode(for: base) {
            return official
        }
        return all.first(where: { $0.storefrontId == base })?.code
    }

    static func storefrontHeader(for countryCode: String) -> String {
        "\(storefrontId(for: countryCode))-1,29"
    }
}

// MARK: - Search, Download & Library Models

struct AppSearchItem: Identifiable, Decodable {
    let trackId: Int
    let bundleId: String
    let trackName: String
    let sellerName: String?
    let version: String?
    let artworkUrl100: String?
    let price: Double?
    let formattedPrice: String?
    let fileSizeBytes: String?

    var id: Int { trackId }
    var adamIdString: String { String(trackId) }

    var formattedSize: String {
        guard let str = fileSizeBytes, let bytes = Int64(str) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ITunesSearchResponse: Decodable {
    let resultCount: Int
    let results: [AppSearchItem]
}

struct SinfItem {
    let id: Int64
    let sinf: Data
}

struct AppDownloadInfo: Identifiable {
    let id = UUID()
    let adamId: String
    let name: String
    let bundleId: String
    let artistName: String
    let shortVersion: String
    let bundleVersion: String
    let externalVersionId: String
    let availableVersionIds: [String]
    let downloadURL: URL
    let sinfs: [SinfItem]
    let metadataPlistData: Data
    let artworkUrl: String?
    let resolvedStage: String
}

struct LocalIPAFile: Identifiable, Equatable {
    let id: String
    let url: URL
    let fileName: String
    let sizeBytes: Int64
    let modifiedAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum DownloadState: Equatable {
    case idle
    case inspecting(stage: String)
    case downloading(progress: Double, received: Int64, total: Int64)
    case patching
    case finished(LocalIPAFile)
    case failed(String)
}

// MARK: - Diagnostics Models

enum DiagnosticCategory: String, CaseIterable, Identifiable {
    case all = "Все"
    case bag = "Bag"
    case sap = "SAP"
    case auth = "Auth"
    case download = "Download"
    case system = "System"

    var id: String { rawValue }
}

enum DiagnosticLevel: String {
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERR"
}

struct DiagnosticEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let level: DiagnosticLevel
    let engine: String
    let httpStatus: Int?
    let message: String
    let details: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        engine: String,
        httpStatus: Int? = nil,
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.engine = engine
        self.httpStatus = httpStatus
        self.message = message
        self.details = details
    }
}

struct SelfTestReport: Equatable {
    let engine: AuthEngineMode
    let testedAt: Date
    let bagSuccess: Bool
    let bagLatencyMs: Int
    let authEndpoint: String
    let redownloadEndpoint: String
    let updateEndpoint: String
    let sapSuccess: Bool
    let sapLatencyMs: Int
    let sapSignatureBytes: Int
    let errorSummary: String?
}

// MARK: - Localized Store Errors

enum StoreError: LocalizedError {
    case twoFactorRequired(String)
    case invalidCredentials(String)
    case tokenExpired
    case licenseRequired
    case appUnavailable(String)
    case invalidResponse(String)
    case networkError(String)
    case zipPatchFailed(String)

    var errorDescription: String? {
        switch self {
        case .twoFactorRequired(let msg):
            return msg.isEmpty
                ? "Требуется 6-значный код двухфакторной аутентификации (2FA)."
                : msg
        case .invalidCredentials(let msg):
            return msg
        case .tokenExpired:
            return "Сессия Apple ID истекла. Войдите в аккаунт повторно во вкладке «Аккаунты»."
        case .licenseRequired:
            return "Приложение не привязано к этому Apple ID (код 9610). Для доступного бесплатного приложения нажмите «Получить бесплатную лицензию»; для удалённого — войдите в аккаунт, на котором оно ранее скачивалось."
        case .appUnavailable(let msg):
            return msg
        case .invalidResponse(let detail):
            return detail.isEmpty
                ? "Не удалось разобрать ответ сервера Apple (некорректный plist)."
                : "Некорректный ответ сервера Apple: \(detail)"
        case .networkError(let msg):
            return "Сетевая ошибка: \(msg)"
        case .zipPatchFailed(let msg):
            return "Ошибка сборки IPA (инжект SINF/метаданных): \(msg)"
        }
    }
}
