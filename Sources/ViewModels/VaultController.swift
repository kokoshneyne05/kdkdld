import Foundation
import SwiftUI
import MapleSAP

@MainActor
final class PreparedAppleLoginSession {
    let email: String
    let identity: MachineIdentity
    let loginTransport: AnisetteAuthenticatedTransport
    private let sapTransport = AppleSAPTransport()
    private var signer: SAPSession?
    private var closed = false
    var endpoint: URL?
    private(set) var expiresAt = Date.distantPast

    init(email: String, cookies: [StoreCookie], anisetteHeaders: [String: String]) throws {
        self.email = email
        self.identity = try KeychainMachineIdentity.loadOrCreate()
        self.loginTransport = AnisetteAuthenticatedTransport(
            cookies: cookies,
            isolatedConnections: true,
            anisetteHeaders: anisetteHeaders
        )
    }

    func canReuse(for email: String) -> Bool {
        !closed && self.email == email && signer != nil && expiresAt > Date()
    }

    func prepare(progress: (AuthenticationStage) -> Void) async throws -> SAPSession {
        guard !closed else { throw CancellationError() }
        if let signer = signer {
            progress(.prepared)
            return signer
        }
        progress(.bag)
        let config = try await SAPProtocol(transport: sapTransport).bag(identity: identity)
        endpoint = try AuthenticationEndpoint.validate(config.authenticationURL)
        progress(.sap)
        let created = try SAPSession(guest: NativeSAPGuest(), transport: sapTransport)
        signer = created
        try await created.initialize(configuration: config, identity: identity)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        expiresAt = Date().addingTimeInterval(300)
        return created
    }

    func close() async {
        guard !closed else { return }
        closed = true
        sapTransport.close()
        loginTransport.close()
        if let signer = signer {
            await signer.close()
        }
    }
}

@MainActor
final class VaultController: ObservableObject {
    // MARK: - Navigation
    @Published var selectedTab: Int = 0

    // MARK: - SideStore Anisette State
    @Published var useSideStoreAnisette: Bool = UserDefaults.standard.object(forKey: "useSideStoreAnisette") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useSideStoreAnisette, forKey: "useSideStoreAnisette") }
    }
    @Published var anisetteServers: [SideStoreAnisetteServer] = SideStoreAnisetteServer.builtInServers
    @Published var selectedAnisetteURL: String = UserDefaults.standard.string(forKey: "selectedAnisetteURL") ?? SideStoreAnisetteServer.builtInServers[0].address {
        didSet { UserDefaults.standard.set(selectedAnisetteURL, forKey: "selectedAnisetteURL") }
    }
    @Published var customAnisetteURL: String = UserDefaults.standard.string(forKey: "customAnisetteURL") ?? "" {
        didSet { UserDefaults.standard.set(customAnisetteURL, forKey: "customAnisetteURL") }
    }
    @Published var anisetteStatusText: String = "Не проверено"
    @Published var isTestingAnisette: Bool = false
    @Published var lastAnisettePayload: SideStoreAnisettePayload?

    // MARK: - Auth State
    @Published var appleId: String = ""
    @Published var password: String = ""
    @Published var twoFactorCode: String = ""
    @Published var requires2FA: Bool = false
    @Published var isAuthenticating: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var activeAccount: StoreAccount?
    @Published var authStatusText: String = "Не выполнен вход"
    @Published var authErrorText: String = ""

    // MARK: - Deleted App / Extractor State
    @Published var appInput: String = ""
    @Published var manualVersionInput: String = ""
    @Published var isInspecting: Bool = false
    @Published var resolvedApp: ResolvedAppBundle?
    @Published var extractorStatusText: String = ""
    @Published var extractorErrorText: String = ""

    // MARK: - Download State
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var downloadDetailText: String = ""
    @Published var activeDownloadTitle: String = ""
    @Published var lastCompletedRecord: DownloadRecord?
    @Published var downloads: [DownloadRecord] = []

    // MARK: - Catalog Search State
    @Published var searchQuery: String = ""
    @Published var searchResults: [ITunesSearchItem] = []
    @Published var isSearching: Bool = false

    // MARK: - Logs
    @Published var logs: [VaultLogEntry] = []

    private let anisetteClient = SideStoreAnisetteClient()
    private var storeSession: StoreSession?
    private var storeTransport: AnisetteAuthenticatedTransport?
    private var preparedLogin: PreparedAppleLoginSession?
    private var pendingCookies: [StoreCookie] = []
    private var authTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var didBootstrap = false

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        downloads = DownloadRecord.loadAll()
        restoreSavedAccount()
        Task {
            await refreshAnisetteServers()
        }
    }

    // MARK: - Logging (redacted)
    func log(_ level: VaultLogEntry.Level, category: String, _ message: String) {
        var clean = message
        for secret in [password, activeAccount?.passwordToken ?? "", activeAccount?.dsid ?? ""] where !secret.isEmpty {
            clean = clean.replacingOccurrences(of: secret, with: "[redacted]")
        }
        let entry = VaultLogEntry(timestamp: Date(), level: level, category: category, message: clean)
        logs.insert(entry, at: 0)
        if logs.count > 250 {
            logs.removeLast(logs.count - 250)
        }
    }

    var formattedLogsText: String {
        logs.reversed().map { "[\($0.formattedTime)] [\($0.level.rawValue)] [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }

    // MARK: - SideStore Anisette Management
    func refreshAnisetteServers() async {
        let fetched = await anisetteClient.fetchOfficialServerList()
        if !fetched.isEmpty {
            anisetteServers = fetched
            log(.info, category: "Anisette", "Загружен список SideStore серверов: \(fetched.count) шт.")
        }
    }

    func activePreferredAnisetteAddress() -> String {
        let custom = customAnisetteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.hasPrefix("https://") ? custom : selectedAnisetteURL
    }

    func testSideStoreAnisette() {
        guard !isTestingAnisette else { return }
        isTestingAnisette = true
        anisetteStatusText = "Проверка SideStore Anisette…"
        Task {
            defer { isTestingAnisette = false }
            do {
                let payload = try await anisetteClient.fetchWithFailover(
                    preferredAddress: activePreferredAnisetteAddress(),
                    servers: anisetteServers
                )
                lastAnisettePayload = payload
                selectedAnisetteURL = payload.serverAddress
                anisetteStatusText = "OK: \(payload.serverName) (\(payload.latencyMs) мс)"
                log(.success, category: "Anisette", "Получены заголовки от \(payload.serverName) за \(payload.latencyMs) мс (RINFO=\(payload.routingInfo))")
            } catch {
                anisetteStatusText = "Ошибка: \(error.localizedDescription)"
                log(.error, category: "Anisette", error.localizedDescription)
            }
        }
    }

    private func fetchAnisetteHeadersIfEnabled() async -> [String: String] {
        guard useSideStoreAnisette else {
            log(.info, category: "Anisette", "Режим без Anisette (только FairPlay SAP)")
            return [:]
        }
        do {
            let payload = try await anisetteClient.fetchWithFailover(
                preferredAddress: activePreferredAnisetteAddress(),
                servers: anisetteServers
            )
            lastAnisettePayload = payload
            anisetteStatusText = "OK: \(payload.serverName) (\(payload.latencyMs) мс)"
            log(.success, category: "Anisette", "SideStore Anisette активен: \(payload.serverName) (\(payload.latencyMs) мс)")
            return payload.storeHeaders()
        } catch {
            anisetteStatusText = "Fallback без Anisette: \(error.localizedDescription)"
            log(.warning, category: "Anisette", "Серверы Anisette недоступны, продолжение с FairPlay SAP: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Apple ID Authentication (SideStore Anisette + Native MapleSAP)
    func restoreSavedAccount() {
        do {
            guard let saved = try KeychainStoreAccount().load() else { return }
            try saved.validate(identity: KeychainMachineIdentity.loadOrCreate())
            activeAccount = saved
            appleId = saved.email
            isAuthenticated = true
            authStatusText = "Сессия восстановлена: \(saved.email)"
            log(.success, category: "Auth", "Сохранённая сессия восстановлена из Keychain (\(saved.email))")
        } catch {
            log(.warning, category: "Auth", "Не удалось восстановить сохранённую сессию — требуется повторный вход")
        }
    }

    func signIn() {
        let email = appleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAuthenticating, !email.isEmpty, !password.isEmpty else { return }
        let secret = password
        let code = requires2FA ? twoFactorCode : ""
        let challengeCookies = requires2FA ? pendingCookies : []

        isAuthenticating = true
        authErrorText = ""
        authStatusText = "Подготовка входа…"

        authTask = Task {
            defer {
                isAuthenticating = false
                authTask = nil
            }
            var currentPrep: PreparedAppleLoginSession?
            var keepPrepared = false

            do {
                _ = try TwoFactorAuthentication.normalize(code)
                let anisetteHeaders = await fetchAnisetteHeadersIfEnabled()

                let prepared: PreparedAppleLoginSession
                if let existing = preparedLogin, existing.canReuse(for: email) {
                    prepared = existing
                    prepared.loginTransport.updateAnisetteHeaders(anisetteHeaders)
                    log(.info, category: "SAP", "Переиспользована активная SAP-сессия для 2FA")
                } else {
                    if let existing = preparedLogin {
                        await existing.close()
                    }
                    preparedLogin = nil
                    prepared = try PreparedAppleLoginSession(
                        email: email,
                        cookies: challengeCookies,
                        anisetteHeaders: anisetteHeaders
                    )
                    preparedLogin = prepared
                }
                currentPrep = prepared

                let signer = try await prepared.prepare { stage in
                    self.authStatusText = stage.rawValue
                    self.log(.info, category: "SAP", stage.rawValue)
                }
                guard let endpoint = prepared.endpoint else { throw CancellationError() }

                let authentication = AppleAuthentication(
                    transport: prepared.loginTransport,
                    signer: signer,
                    persistence: KeychainStoreAccount(),
                    diagnostic: { [weak self] event in
                        await MainActor.run {
                            self?.log(.info, category: "Auth", event)
                        }
                    },
                    automaticRecovery: true
                )

                let outcome = try await authentication.login(
                    email: email,
                    password: secret,
                    code: code,
                    identity: prepared.identity,
                    endpoint: endpoint,
                    resolvedEndpoint: { resolved in
                        await MainActor.run {
                            prepared.endpoint = resolved
                        }
                    }
                ) { stage in
                    await MainActor.run {
                        self.authStatusText = stage.rawValue
                        self.log(.info, category: "Auth", stage.rawValue)
                    }
                }

                switch outcome {
                case .twoFactorRequired(let cookies):
                    pendingCookies = cookies
                    keepPrepared = true
                    requires2FA = true
                    twoFactorCode = ""
                    authStatusText = "Введите 6-значный код 2FA с доверенного устройства"
                    log(.warning, category: "2FA", "Apple запросил 6-значный код подтверждения")

                case .authenticated(let account):
                    resetStoreSession()
                    activeAccount = account
                    isAuthenticated = true
                    requires2FA = false
                    password = ""
                    twoFactorCode = ""
                    pendingCookies = []
                    authStatusText = "Вход выполнен: \(account.email)"
                    log(.success, category: "Auth", "Успешный вход! Storefront=\(account.storefront), pod=\(account.pod ?? "default")")
                }
            } catch is CancellationError {
                authStatusText = "Вход отменён"
                log(.warning, category: "Auth", "Вход отменён пользователем")
            } catch {
                if let prep = currentPrep {
                    if requires2FA {
                        pendingCookies = await prep.loginTransport.cookies()
                    }
                    if let authErr = error as? AuthenticationError {
                        switch authErr {
                        case .http, .network, .rateLimited, .retryLater, .invalidResponse, .verificationRejected, .invalidCode:
                            keepPrepared = true
                        default:
                            break
                        }
                    }
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                authErrorText = message
                authStatusText = "Ошибка входа"
                twoFactorCode = ""
                log(.error, category: "Auth", message)
            }

            if let prep = currentPrep, !keepPrepared {
                if preparedLogin === prep {
                    preparedLogin = nil
                }
                await prep.close()
            }
        }
    }

    func resetTwoFactor() {
        authTask?.cancel()
        if let prep = preparedLogin {
            preparedLogin = nil
            Task { await prep.close() }
        }
        requires2FA = false
        twoFactorCode = ""
        pendingCookies = []
        authErrorText = ""
        authStatusText = "Готово к новому входу"
    }

    func signOut() {
        authTask?.cancel()
        downloadTask?.cancel()
        resetTwoFactor()
        resetStoreSession()
        try? KeychainKBSync().clear()
        try? KeychainStoreAccount().clear()
        activeAccount = nil
        isAuthenticated = false
        password = ""
        resolvedApp = nil
        authStatusText = "Выход выполнен"
        log(.info, category: "Auth", "Сессия и kbsync очищены")
    }

    // MARK: - StoreSession Factory
    private func resetStoreSession() {
        storeTransport?.close()
        storeTransport = nil
        storeSession = nil
    }

    private func getStoreSession() async throws -> StoreSession {
        if let existing = storeSession {
            return existing
        }
        guard let account = activeAccount else {
            throw AuthenticationError.invalidSession
        }
        let anisetteHeaders = await fetchAnisetteHeadersIfEnabled()
        let transport = AnisetteAuthenticatedTransport(
            cookies: account.cookies,
            isolatedConnections: false,
            anisetteHeaders: anisetteHeaders
        )
        let session = try StoreSession(
            account: account,
            identity: KeychainMachineIdentity.loadOrCreate(),
            transport: transport,
            generator: NativeKBSyncGenerator(),
            persistence: KeychainKBSync(),
            progress: { [weak self] stage in
                await MainActor.run {
                    self?.extractorStatusText = stage.rawValue
                    self?.downloadDetailText = stage.rawValue
                    self?.log(.info, category: "Store", stage.rawValue)
                }
            },
            diagnostic: { [weak self] event in
                await MainActor.run {
                    self?.log(.info, category: "StoreDiag", event)
                }
            }
        )
        self.storeTransport = transport
        self.storeSession = session
        return session
    }

    // MARK: - Direct Deleted App & Version Discovery
    func inspectApp(forceDirectDeleted: Bool) {
        guard isAuthenticated else {
            extractorErrorText = "Сначала войдите в Apple ID на вкладке «Аккаунт»."
            return
        }
        let rawInput = appInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty else {
            extractorErrorText = "Введите числовой App ID (например, 310633997) или ссылку App Store."
            return
        }
        let cleanVersion = manualVersionInput.trimmingCharacters(in: .whitespacesAndNewlines)

        isInspecting = true
        extractorErrorText = ""
        extractorStatusText = forceDirectDeleted
            ? "Прямой запрос удалённого приложения без каталога…"
            : "Поиск приложения и списка версий…"

        Task {
            defer { isInspecting = false }
            do {
                let session = try await getStoreSession()
                let numericID = AppIDParser.extractNumericID(from: rawInput)

                let bundle: ResolvedAppBundle
                if forceDirectDeleted {
                    guard let appID = numericID else { throw StoreError.invalidApp }
                    log(.info, category: "Deleted", "Прямой запрос adamId=\(appID), version=\(cleanVersion.isEmpty ? "latest" : cleanVersion)")
                    let result = try await session.inspectDeleted(appID: appID, externalVersionID: cleanVersion)
                    bundle = ResolvedAppBundle(app: result.app, latestDownload: result.download, isDeletedDirect: true)
                } else {
                    do {
                        let app = try await session.lookup(rawInput)
                        let dl = try await session.descriptor(app: app, externalVersionID: cleanVersion)
                        bundle = ResolvedAppBundle(app: app, latestDownload: dl, isDeletedDirect: false)
                    } catch {
                        if let appID = numericID,
                           let storeErr = error as? StoreError,
                           storeErr == .unavailable || storeErr == .http(404) || storeErr == .invalidResponse {
                            log(.warning, category: "Deleted", "Нет в публичном каталоге — автопереход в прямой режим для ID \(appID)")
                            let result = try await session.inspectDeleted(appID: appID, externalVersionID: cleanVersion)
                            bundle = ResolvedAppBundle(app: result.app, latestDownload: result.download, isDeletedDirect: true)
                        } else {
                            throw error
                        }
                    }
                }

                resolvedApp = bundle
                extractorStatusText = "Найдено: \(bundle.app.name) • версий: \(bundle.versions.count)"
                log(.success, category: "Extractor", "\(bundle.app.name) (\(bundle.app.bundleID)) — доступно \(bundle.versions.count) версий (\(bundle.isDeletedDirect ? "Deleted Direct" : "Catalog"))")

                if !cleanVersion.isEmpty {
                    startDownload(bundle: bundle, versionID: bundle.latestDownload.externalVersionID)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                extractorErrorText = msg
                extractorStatusText = "Не удалось получить данные"
                log(.error, category: "Extractor", msg)
            }
        }
    }

    // MARK: - Streaming Download & Native SINF IPA Packaging
    func startDownload(bundle: ResolvedAppBundle, versionID: String) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        activeDownloadTitle = "\(bundle.app.name) (\(versionID))"
        downloadDetailText = "Запрос ссылки на скачивание…"
        extractorErrorText = ""

        downloadTask = Task {
            defer {
                isDownloading = false
                downloadTask = nil
            }
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory.appendingPathComponent("ipavault-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }

            do {
                try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                let session = try await getStoreSession()
                let descriptor: StoreDownload
                if bundle.isDeletedDirect {
                    descriptor = try await session.inspectDeleted(
                        appID: bundle.app.id,
                        externalVersionID: versionID,
                        expectedBundleID: bundle.app.bundleID
                    ).download
                } else {
                    descriptor = try await session.descriptor(app: bundle.app, externalVersionID: versionID)
                }

                try Task.checkCancellation()
                downloadDetailText = "Загрузка IPA с CDN Apple…"
                let sourceURL = scratch.appendingPathComponent("source.ipa")
                var receivedURL: URL?

                for attempt in 0..<3 {
                    do {
                        let downloader = CDNDownload(destination: sourceURL) { progress, written, expected in
                            Task { @MainActor in
                                self.downloadProgress = progress * 0.85
                                let writtenMB = Double(written) / 1_048_576.0
                                if expected > 0 {
                                    let totalMB = Double(expected) / 1_048_576.0
                                    self.downloadDetailText = String(format: "Скачивание: %.1f / %.1f МБ", writtenMB, totalMB)
                                } else {
                                    self.downloadDetailText = String(format: "Скачивание: %.1f МБ", writtenMB)
                                }
                            }
                        }
                        receivedURL = try await downloader.run(descriptor.url)
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard attempt < 2 else { throw error }
                        try? fm.removeItem(at: sourceURL)
                        downloadDetailText = "Повтор подключения к CDN (\(attempt + 2)/3)…"
                        try await Task.sleep(nanoseconds: UInt64((attempt + 1) * 2) * 1_000_000_000)
                    }
                }

                guard let downloadedSource = receivedURL else { throw StoreError.packageInvalid }

                downloadProgress = 0.88
                downloadDetailText = "Проверка MD5, инжект SINF и iTunesMetadata…"
                let stagedURL = scratch.appendingPathComponent("prepared.ipa")
                let appCopy = bundle.app
                let info = try await Task.detached(priority: .userInitiated) {
                    try NativePackage.prepare(source: downloadedSource, destination: stagedURL, app: appCopy, descriptor: descriptor)
                }.value

                try Task.checkCancellation()
                let safeName = bundle.app.name
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                    .prefix(3)
                    .joined(separator: "_")
                let prefix = safeName.isEmpty ? "App" : safeName
                let filename = "\(prefix)-\(bundle.app.id)-\(descriptor.externalVersionID).ipa"
                let destination = DownloadRecord.downloadsDirectory.appendingPathComponent(filename)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }

                let record = DownloadRecord(
                    filename: filename,
                    appID: bundle.app.id,
                    appName: bundle.app.name,
                    bundleID: info.bundleID,
                    version: info.version,
                    build: info.build,
                    externalVersionID: descriptor.externalVersionID,
                    date: Date(),
                    isDeletedDirect: bundle.isDeletedDirect
                )
                let sidecarData = try JSONEncoder().encode(record)
                try sidecarData.write(to: record.sidecarURL, options: .atomic)
                try fm.moveItem(at: stagedURL, to: destination)

                downloadProgress = 1.0
                downloadDetailText = "Готово! Сохранено в Documents/Downloads"
                lastCompletedRecord = record
                downloads = DownloadRecord.loadAll()
                log(.success, category: "IPA", "Сохранён \(filename) (v\(info.version), \(record.formattedSize))")
            } catch is CancellationError {
                downloadDetailText = "Загрузка отменена"
                log(.warning, category: "IPA", "Загрузка отменена")
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                extractorErrorText = msg
                downloadDetailText = "Ошибка загрузки"
                log(.error, category: "IPA", msg)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func deleteRecord(_ record: DownloadRecord) {
        try? record.deleteFiles()
        if lastCompletedRecord?.id == record.id {
            lastCompletedRecord = nil
        }
        downloads = DownloadRecord.loadAll()
    }

    // MARK: - Public App Store Search
    func searchCatalog() {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=software&limit=25") else {
                isSearching = false
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
                searchResults = decoded.results
            } catch {
                log(.error, category: "Search", error.localizedDescription)
            }
            isSearching = false
        }
    }

    func selectFromSearch(_ item: ITunesSearchItem) {
        appInput = String(item.trackId)
        manualVersionInput = ""
        selectedTab = 0
        inspectApp(forceDirectDeleted: false)
    }
}
