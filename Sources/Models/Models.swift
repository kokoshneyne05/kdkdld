import Foundation

struct AppleAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var email: String
    var firstName: String
    var lastName: String
    var dsid: String
    var passwordToken: String
    var pod: String
    var storeFront: String
    var countryCode: String
    var guid: String
    var createdAt: Date

    var displayName: String {
        let full = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? email : full
    }
}

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

    static func storefrontHeader(for countryCode: String) -> String {
        let base = all.first(where: { $0.code.uppercased() == countryCode.uppercased() })?.storefrontId ?? "143441"
        return "\(base)-1,29"
    }
}

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
    let id: Int
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
    case inspecting
    case downloading(progress: Double, received: Int64, total: Int64)
    case patching
    case finished(LocalIPAFile)
    case failed(String)
}

enum StoreError: LocalizedError {
    case twoFactorRequired(String)
    case invalidCredentials(String)
    case tokenExpired
    case licenseRequired
    case appUnavailable(String)
    case invalidResponse
    case networkError(String)
    case zipPatchFailed(String)

    var errorDescription: String? {
        switch self {
        case .twoFactorRequired(let msg):
            return msg.isEmpty ? "Требуется 6-значный код двухфакторной аутентификации (2FA)." : msg
        case .invalidCredentials(let msg):
            return msg
        case .tokenExpired:
            return "Сессия Apple ID истекла. Войдите в аккаунт повторно во вкладке «Аккаунты»."
        case .licenseRequired:
            return "Приложение не привязано к этому Apple ID (ошибка 9610). Для доступного бесплатного приложения нажмите «Получить лицензию»; для удалённого — войдите в аккаунт, на котором оно ранее скачивалось."
        case .appUnavailable(let msg):
            return msg
        case .invalidResponse:
            return "Не удалось разобрать ответ сервера Apple (некорректный plist)."
        case .networkError(let msg):
            return "Сетевая ошибка: \(msg)"
        case .zipPatchFailed(let msg):
            return "Ошибка сборки IPA (инжект SINF/метаданных): \(msg)"
        }
    }
}
