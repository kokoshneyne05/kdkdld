import ApplePackage
import Foundation

/// Disables automatic URLSession redirect handling so we can manually capture
/// Set-Cookie / pod / storefront headers and re-sign redirected POST bodies with SAPSigner.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct PendingURLSessionAuth {
    let email: String
    let signer: SAPSigner
    var endpoint: URL
    var cookies: [StoredCookie]
    var pod: String?
    var storeId: String?
}

struct BagEndpoints {
    let authEndpoint: URL
    let redownloadEndpoint: URL?
    let updateEndpoint: URL?
}

struct DownloadFetchResult {
    let info: AppDownloadInfo
    let updatedCookies: [StoredCookie]
}

final class AppleStoreClient {
    static let shared = AppleStoreClient()

    private let noRedirectDelegate = NoRedirectDelegate()
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: noRedirectDelegate, delegateQueue: nil)
    }()

    // Stateful 2FA sessions (MUST be reused when submitting 6-digit 2FA code!)
    private var pendingApplePackageSession: (email: String, authenticator: Authenticator)?
    private var pendingURLSessionSession: PendingURLSessionAuth?

    let deviceGUID: String

    private init() {
        let guid = KeychainStore.shared.loadOrCreateDeviceGUID()
        self.deviceGUID = guid
        Configuration.deviceIdentifier = guid
    }

    func prepareDeviceIdentity() {
        Configuration.deviceIdentifier = deviceGUID
    }

    func hasPendingTwoFactorSession(for email: String, engine: AuthEngineMode) -> Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch engine {
        case .applePackage:
            return pendingApplePackageSession?.email == normalized
        case .urlSessionSAP:
            return pendingURLSessionSession?.email == normalized
        }
    }

    func resetPendingAuthSessions() {
        pendingApplePackageSession = nil
        pendingURLSessionSession = nil
        DiagnosticLogger.shared.logAsync(
            category: .auth,
            level: .info,
            engine: "System",
            message: "Активная 2FA/SAP-сессия сброшена."
        )
    }

    // MARK: - Live Self-Test (Bag + FairPlay SAP Handshake)

    func runBagAndSAPSelfTest(engine: AuthEngineMode) async -> SelfTestReport {
        prepareDeviceIdentity()
        DiagnosticLogger.shared.logAsync(
            category: .system,
            level: .info,
            engine: engine.shortName,
            message: "Запуск проверки Bag + FairPlay SAP (GUID: \(deviceGUID))…"
        )

        var bagOK = false
        var bagMs = 0
        var authEndpointStr = "—"
        var redownloadStr = "—"
        var updateStr = "—"
        var sapOK = false
        var sapMs = 0
        var sigBytes = 0
        var errMsg: String? = nil

        // 1. Bag Check
        let bagStart = Date()
        do {
            let bag = try await fetchBagEndpoints(engine: engine)
            bagMs = Int(Date().timeIntervalSince(bagStart) * 1000)
            bagOK = true
            authEndpointStr = bag.authEndpoint.absoluteString
            redownloadStr = bag.redownloadEndpoint?.absoluteString ?? "https://downloaddispatch.itunes.apple.com/r/redownload"
            updateStr = bag.updateEndpoint?.absoluteString ?? "https://downloaddispatch.itunes.apple.com/up/updateProduct"
            DiagnosticLogger.shared.logAsync(
                category: .bag,
                level: .success,
                engine: engine.shortName,
                httpStatus: 200,
                message: "Bag получен за \(bagMs) мс",
                details: "auth: \(authEndpointStr)\nredownload: \(redownloadStr)\nupdate: \(updateStr)"
            )
        } catch {
            bagMs = Int(Date().timeIntervalSince(bagStart) * 1000)
            errMsg = "Bag: \(error.localizedDescription)"
            DiagnosticLogger.shared.logAsync(
                category: .bag,
                level: .error,
                engine: engine.shortName,
                message: "Ошибка загрузки bag.xml (\(bagMs) мс)",
                details: error.localizedDescription
            )
        }

        // 2. SAP Handshake + Test Sign
        let sapStart = Date()
        do {
            let signer = try await SAPSigner.connect()
            let probeSig = try await signer.sign(Data("ipavault-sap-probe".utf8))
            sapMs = Int(Date().timeIntervalSince(sapStart) * 1000)
            sapOK = !probeSig.isEmpty
            sigBytes = probeSig.count
            DiagnosticLogger.shared.logAsync(
                category: .sap,
                level: .success,
                engine: engine.shortName,
                httpStatus: 200,
                message: "FairPlay SAP рукопожатие пройдено за \(sapMs) мс",
                details: "Тестовая подпись X-Apple-ActionSignature сформирована (\(sigBytes) байт)."
            )
        } catch {
            sapMs = Int(Date().timeIntervalSince(sapStart) * 1000)
            let sapErr = "SAP: \(error.localizedDescription)"
            errMsg = errMsg.map { "\($0) | \(sapErr)" } ?? sapErr
            DiagnosticLogger.shared.logAsync(
                category: .sap,
                level: .error,
                engine: engine.shortName,
                message: "Ошибка FairPlay SAP рукопожатия (\(sapMs) мс)",
                details: error.localizedDescription
            )
        }

        return SelfTestReport(
            engine: engine,
            testedAt: Date(),
            bagSuccess: bagOK,
            bagLatencyMs: bagMs,
            authEndpoint: authEndpointStr,
            redownloadEndpoint: redownloadStr,
            updateEndpoint: updateStr,
            sapSuccess: sapOK,
            sapLatencyMs: sapMs,
            sapSignatureBytes: sigBytes,
            errorSummary: errMsg
        )
    }

    // MARK: - Bag Resolution

    func fetchBagEndpoints(engine: AuthEngineMode) async throws -> BagEndpoints {
        prepareDeviceIdentity()

        if engine == .applePackage {
            let output = try await Bag.fetchBag()
            return BagEndpoints(
                authEndpoint: output.authEndpoint,
                redownloadEndpoint: output.redownloadEndpoint,
                updateEndpoint: output.updateEndpoint
            )
        }

        // URLSession Bag Fetch
        guard var comps = URLComponents(string: "https://init.itunes.apple.com/bag.xml") else {
            throw StoreError.invalidResponse("Некорректный URL bag.xml")
        }
        comps.queryItems = [URLQueryItem(name: "guid", value: deviceGUID)]
        guard let url = comps.url else {
            throw StoreError.invalidResponse("Некорректный URL bag.xml")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StoreError.invalidResponse("Нет HTTP-ответа от bag.xml")
        }

        DiagnosticLogger.shared.logAsync(
            category: .bag,
            level: http.statusCode == 200 ? .info : .warning,
            engine: engine.shortName,
            httpStatus: http.statusCode,
            message: "GET init.itunes.apple.com/bag.xml (\(data.count) байт)"
        )

        let fallbackAuth = URL(string: "https://auth.itunes.apple.com/auth/v1/native/fast")!
        guard http.statusCode == 200,
              let dict = parsePlistDictionary(data),
              let urlBag = dict["urlBag"] as? [String: Any] else {
            return BagEndpoints(authEndpoint: fallbackAuth, redownloadEndpoint: nil, updateEndpoint: nil)
        }

        let authURL = (urlBag["authenticateAccount"] as? String).flatMap { URL(string: $0) } ?? fallbackAuth
        let redownloadURL = (urlBag["redownloadProduct"] as? String).flatMap { URL(string: $0) }
        let updateURL = (urlBag["updateProduct"] as? String).flatMap { URL(string: $0) }

        return BagEndpoints(
            authEndpoint: authURL,
            redownloadEndpoint: redownloadURL,
            updateEndpoint: updateURL
        )
    }

    // MARK: - Unified Authentication (Dual Engine + Stateful SAP 2FA)

    func authenticate(
        email: String,
        password: String,
        authCode: String?,
        countryCode: String,
        engine: AuthEngineMode,
        existingCookies: [StoredCookie] = []
    ) async throws -> AppleAccount {
        prepareDeviceIdentity()
        let cleanedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCode = authCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        DiagnosticLogger.shared.logAsync(
            category: .auth,
            level: .info,
            engine: engine.shortName,
            message: cleanedCode.isEmpty
                ? "Начало входа Apple ID (\(cleanedEmail), регион \(countryCode))"
                : "Отправка 6-значного кода 2FA в активную SAP-сессию (\(cleanedEmail))"
        )

        switch engine {
        case .applePackage:
            return try await authenticateWithApplePackage(
                email: cleanedEmail,
                password: password,
                code: cleanedCode,
                fallbackCountryCode: countryCode,
                existingCookies: existingCookies
            )
        case .urlSessionSAP:
            return try await authenticateWithURLSessionSAP(
                email: cleanedEmail,
                password: password,
                code: cleanedCode,
                fallbackCountryCode: countryCode,
                existingCookies: existingCookies
            )
        }
    }

    // MARK: Engine A — ApplePackage (Full SAP + AsyncHTTPClient)

    private func authenticateWithApplePackage(
        email: String,
        password: String,
        code: String,
        fallbackCountryCode: String,
        existingCookies: [StoredCookie]
    ) async throws -> AppleAccount {
        let normalizedEmail = email.lowercased()
        let authenticator: Authenticator

        if let existing = pendingApplePackageSession, existing.email == normalizedEmail, !code.isEmpty {
            authenticator = existing.authenticator
            DiagnosticLogger.shared.logAsync(
                category: .sap,
                level: .info,
                engine: "ApplePackage",
                message: "Переиспользование активной SAP-сессии для подтверждения 2FA."
            )
        } else {
            DiagnosticLogger.shared.logAsync(
                category: .sap,
                level: .info,
                engine: "ApplePackage",
                message: "Инициализация свежего Bag + SAPSigner рукопожатия…"
            )
            authenticator = try await Authenticator(cookies: existingCookies.map { $0.toApplePackageCookie() })
            pendingApplePackageSession = (email: normalizedEmail, authenticator: authenticator)
        }

        do {
            let apAccount = try await authenticator.authenticate(
                email: email,
                password: password,
                code: code
            )
            pendingApplePackageSession = nil

            let resolvedCountry = StorefrontRegion.countryCode(forStoreId: apAccount.store) ?? fallbackCountryCode.uppercased()
            let resolvedPod = (apAccount.pod?.isEmpty == false) ? apAccount.pod! : "25"
            let resolvedStoreId = apAccount.store.isEmpty
                ? StorefrontRegion.storefrontId(for: resolvedCountry)
                : apAccount.store

            DiagnosticLogger.shared.logAsync(
                category: .auth,
                level: .success,
                engine: "ApplePackage",
                httpStatus: 200,
                message: "Вход выполнен: \(apAccount.email)",
                details: "DSID: \(apAccount.directoryServicesIdentifier)\nPod: \(resolvedPod)\nStore: \(resolvedStoreId) (\(resolvedCountry))\nCookies: \(apAccount.cookie.count)"
            )

            return AppleAccount(
                id: UUID(),
                email: apAccount.email,
                appleId: apAccount.appleId,
                firstName: apAccount.firstName,
                lastName: apAccount.lastName,
                dsid: apAccount.directoryServicesIdentifier,
                passwordToken: apAccount.passwordToken,
                pod: resolvedPod,
                storeId: resolvedStoreId,
                storeFront: "\(resolvedStoreId)-1,29",
                countryCode: resolvedCountry,
                guid: deviceGUID,
                cookies: apAccount.cookie.map { StoredCookie(from: $0) },
                engineUsed: .applePackage,
                createdAt: Date()
            )
        } catch AuthenticationError.verificationCodeRequired {
            // Keep pendingApplePackageSession intact so the 2FA submit reuses the exact same SAP session!
            DiagnosticLogger.shared.logAsync(
                category: .auth,
                level: .warning,
                engine: "ApplePackage",
                message: "Apple запросила 6-значный код 2FA (SAP-сессия сохранена)."
            )
            throw StoreError.twoFactorRequired(
                "Apple отправила 6-значный код на ваши устройства. Введите его ниже — активная SAP-сессия сохранена."
            )
        } catch {
            // Reset broken session unless user just mistyped 2FA code
            let desc = error.localizedDescription
            if !desc.localizedCaseInsensitiveContains("verification") && !desc.localizedCaseInsensitiveContains("5005") {
                pendingApplePackageSession = nil
            }
            DiagnosticLogger.shared.logAsync(
                category: .auth,
                level: .error,
                engine: "ApplePackage",
                message: "Ошибка входа: \(desc)"
            )
            throw StoreError.invalidCredentials(desc)
        }
    }

    // MARK: Engine B — Native URLSession + SAPSigner Bridge

    private func authenticateWithURLSessionSAP(
        email: String,
        password: String,
        code: String,
        fallbackCountryCode: String,
        existingCookies: [StoredCookie]
    ) async throws -> AppleAccount {
        let normalizedEmail = email.lowercased()
        var sessionState: PendingURLSessionAuth

        if let existing = pendingURLSessionSession, existing.email == normalizedEmail, !code.isEmpty {
            sessionState = existing
            DiagnosticLogger.shared.logAsync(
                category: .sap,
                level: .info,
                engine: "URLSession+SAP",
                message: "Переиспользование SAPSigner и \(existing.cookies.count) кук для 2FA."
            )
        } else {
            let bag = try await fetchBagEndpoints(engine: .urlSessionSAP)
            guard var comps = URLComponents(url: bag.authEndpoint, resolvingAgainstBaseURL: true) else {
                throw StoreError.invalidResponse("Некорректный authEndpoint из bag.xml")
            }
            var query = comps.queryItems ?? []
            query.removeAll { $0.name == "guid" }
            query.append(URLQueryItem(name: "guid", value: deviceGUID))
            comps.queryItems = query
            guard let initialURL = comps.url, isApprovedAppleAuthURL(initialURL) else {
                throw StoreError.invalidResponse("Недоверенный URL авторизации")
            }

            DiagnosticLogger.shared.logAsync(
                category: .sap,
                level: .info,
                engine: "URLSession+SAP",
                message: "Выполнение FairPlay SAP рукопожатия…"
            )
            let signer = try await SAPSigner.connect()
            DiagnosticLogger.shared.logAsync(
                category: .sap,
                level: .success,
                engine: "URLSession+SAP",
                message: "SAPSigner готов к подписи запросов."
            )

            sessionState = PendingURLSessionAuth(
                email: normalizedEmail,
                signer: signer,
                endpoint: initialURL,
                cookies: existingCookies,
                pod: nil,
                storeId: nil
            )
            pendingURLSessionSession = sessionState
        }

        var retried = false
        var redirects = 0

        for step in 1...5 {
            let attemptValue = code.isEmpty ? "4" : "2"
            let payload: [String: String] = [
                "appleId": email,
                "attempt": attemptValue,
                "guid": deviceGUID,
                "password": "\(password)\(code)",
                "rmp": "0",
                "why": "signIn"
            ]

            let bodyData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            let signatureData = try await sessionState.signer.sign(bodyData)

            var request = URLRequest(url: sessionState.endpoint)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(signatureData.base64EncodedString(), forHTTPHeaderField: "X-Apple-ActionSignature")

            if let cookieHeader = sessionState.cookies.cookieHeaderValue(for: sessionState.endpoint) {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            DiagnosticLogger.shared.logAsync(
                category: .auth,
                level: .info,
                engine: "URLSession+SAP",
                message: "POST \(sessionState.endpoint.host ?? "")\(sessionState.endpoint.path) (шаг \(step), attempt=\(attemptValue))",
                details: "SAP sig: \(signatureData.count) байт · Cookies: \(sessionState.cookies.count)"
            )

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StoreError.invalidResponse("Отсутствует HTTP-ответ.")
            }

            // Merge incoming cookies
            let incomingCookies = extractCookies(from: http, url: sessionState.endpoint)
            if !incomingCookies.isEmpty {
                sessionState.cookies.merge(incomingCookies)
            }

            // Extract pod & storefront headers
            if let podHeader = headerValue(http, named: "pod") ?? headerValue(http, named: "itspod"),
               !podHeader.isEmpty {
                sessionState.pod = podHeader
            }
            if let sfHeader = headerValue(http, named: "x-set-apple-store-front"),
               let baseStore = sfHeader.components(separatedBy: "-").first,
               !baseStore.isEmpty {
                sessionState.storeId = baseStore
            }

            // Persist latest state in case we hit 2FA
            pendingURLSessionSession = sessionState

            let correlation = headerValue(http, named: "x-apple-jingle-correlation-key") ?? "—"
            DiagnosticLogger.shared.logAsync(
                category: .auth,
                level: (200...399).contains(http.statusCode) ? .info : .error,
                engine: "URLSession+SAP",
                httpStatus: http.statusCode,
                message: "Ответ \(http.statusCode) (\(data.count) байт)",
                details: "Pod: \(sessionState.pod ?? "—") · Store: \(sessionState.storeId ?? "—") · NewCookies: \(incomingCookies.count) · Corr: \(correlation)"
            )

            // Handle 301/302/303/307/308 redirects manually (re-signing on next iteration!)
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard redirects < 3,
                      let location = headerValue(http, named: "location"),
                      let nextURL = URL(string: location, relativeTo: sessionState.endpoint)?.absoluteURL,
                      isApprovedAppleAuthURL(nextURL) else {
                    pendingURLSessionSession = nil
                    throw StoreError.invalidResponse("Некорректный редирект HTTP \(http.statusCode).")
                }
                sessionState.endpoint = nextURL
                pendingURLSessionSession = sessionState
                redirects += 1
                continue
            }

            guard http.statusCode == 200 else {
                pendingURLSessionSession = nil
                throw StoreError.invalidResponse("Сервер вернул HTTP \(http.statusCode) (тело \(data.count) байт). Проверьте панель диагностики.")
            }

            guard !data.isEmpty, let dict = parsePlistDictionary(data) else {
                pendingURLSessionSession = nil
                throw StoreError.invalidResponse("HTTP 200, но тело ответа пустое или не является plist (\(data.count) байт).")
            }

            let failureType = dict["failureType"].map { String(describing: $0) } ?? ""
            let customerMessage = dict["customerMessage"] as? String ?? ""

            // 2FA challenge
            if failureType.isEmpty && code.isEmpty && customerMessage == "MZFinance.BadLogin.Configurator_message" {
                DiagnosticLogger.shared.logAsync(
                    category: .auth,
                    level: .warning,
                    engine: "URLSession+SAP",
                    httpStatus: 200,
                    message: "Apple запросила 6-значный код 2FA (SAP-сессия сохранена)."
                )
                throw StoreError.twoFactorRequired(
                    "Apple отправила 6-значный код на ваши устройства. Введите его ниже — активная SAP-сессия сохранена."
                )
            }

            // Transient -5000 retry
            if failureType == "-5000" {
                if !retried {
                    retried = true
                    DiagnosticLogger.shared.logAsync(
                        category: .auth,
                        level: .warning,
                        engine: "URLSession+SAP",
                        message: "Apple вернула -5000, автоматический повтор…"
                    )
                    continue
                }
                pendingURLSessionSession = nil
                throw StoreError.invalidCredentials("Неверный Apple ID или пароль (код -5000).")
            }

            if failureType == "5005" {
                throw StoreError.twoFactorRequired("Неверный или просроченный 6-значный код 2FA (код 5005).")
            }

            // Success parsing
            if let passwordToken = dict["passwordToken"] as? String,
               let dsidRaw = dict["dsPersonId"],
               !passwordToken.isEmpty {
                let dsid = String(describing: dsidRaw)
                let accountInfo = dict["accountInfo"] as? [String: Any]
                let address = accountInfo?["address"] as? [String: Any]
                let firstName = address?["firstName"] as? String ?? ""
                let lastName = address?["lastName"] as? String ?? ""
                let appleIdValue = accountInfo?["appleId"] as? String ?? email

                let resolvedPod = sessionState.pod ?? "25"
                let resolvedStoreId = sessionState.storeId ?? StorefrontRegion.storefrontId(for: fallbackCountryCode)
                let resolvedCountry = StorefrontRegion.countryCode(forStoreId: resolvedStoreId) ?? fallbackCountryCode.uppercased()

                pendingURLSessionSession = nil

                DiagnosticLogger.shared.logAsync(
                    category: .auth,
                    level: .success,
                    engine: "URLSession+SAP",
                    httpStatus: 200,
                    message: "Вход выполнен: \(email)",
                    details: "DSID: \(dsid) · Pod: \(resolvedPod) · Store: \(resolvedStoreId) (\(resolvedCountry)) · Cookies: \(sessionState.cookies.count)"
                )

                return AppleAccount(
                    id: UUID(),
                    email: email,
                    appleId: appleIdValue,
                    firstName: firstName,
                    lastName: lastName,
                    dsid: dsid,
                    passwordToken: passwordToken,
                    pod: resolvedPod,
                    storeId: resolvedStoreId,
                    storeFront: "\(resolvedStoreId)-1,29",
                    countryCode: resolvedCountry,
                    guid: deviceGUID,
                    cookies: sessionState.cookies,
                    engineUsed: .urlSessionSAP,
                    createdAt: Date()
                )
            }

            let dialogMsg = (dict["dialog"] as? [String: Any])?["explanation"] as? String
            let finalError = dialogMsg ?? (customerMessage.isEmpty ? "Не удалось выполнить вход (failureType: \(failureType.isEmpty ? "—" : failureType))." : customerMessage)
            pendingURLSessionSession = nil
            throw StoreError.invalidCredentials(finalError)
        }

        pendingURLSessionSession = nil
        throw StoreError.invalidResponse("Превышен лимит редиректов авторизации.")
    }

    // MARK: - 3-Stage Auto-Fallback Download Info (volumeStore -> redownload -> updateProduct)

    func fetchDownloadInfo(
        account: AppleAccount,
        adamId: String,
        externalVersionId: String? = nil,
        engine: AuthEngineMode,
        onStageChange: @escaping (String) -> Void
    ) async throws -> DownloadFetchResult {
        prepareDeviceIdentity()

        let cleanedAdamId = adamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let adamIdInt = Int64(cleanedAdamId), adamIdInt > 0 else {
            throw StoreError.appUnavailable("Введите корректный числовой App ID (adamId).")
        }

        let cleanedVer = externalVersionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var workingCookies = account.cookies

        // Stage 1: volumeStoreDownloadProduct
        onStageChange("Этап 1/3: volumeStoreDownloadProduct…")
        let volumeURL = try buildStoreURL(
            host: Configuration.storeAPIHost(pod: account.pod),
            path: "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        )

        let stage1 = try await executeDownloadStage(
            stageName: "volumeStoreDownloadProduct",
            url: volumeURL,
            account: account,
            cookies: &workingCookies,
            adamId: adamIdInt,
            externalVersionKey: "externalVersionId",
            externalVersionValue: cleanedVer,
            engineLabel: engine.shortName
        )

        if let parsed = try interpretStageResult(
            stageName: "volumeStoreDownloadProduct",
            result: stage1,
            account: account,
            adamId: cleanedAdamId,
            requestedVersion: cleanedVer,
            allowFallback: true
        ) {
            return DownloadFetchResult(info: parsed, updatedCookies: workingCookies)
        }

        // Stage 2: redownload (via Bag or downloaddispatch.itunes.apple.com)
        onStageChange("Этап 2/3: fallback на redownload…")
        DiagnosticLogger.shared.logAsync(
            category: .download,
            level: .warning,
            engine: engine.shortName,
            message: "volumeStore не вернул пакет — переход на этап 2/3 (redownload)."
        )

        let bag = try? await fetchBagEndpoints(engine: engine)
        let redownloadBase = bag?.redownloadEndpoint ?? URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload")!
        let redownloadURL = try appendGuid(to: redownloadBase)

        let stage2 = try await executeDownloadStage(
            stageName: "redownload",
            url: redownloadURL,
            account: account,
            cookies: &workingCookies,
            adamId: adamIdInt,
            externalVersionKey: "appExtVrsId",
            externalVersionValue: cleanedVer,
            engineLabel: engine.shortName
        )

        if let parsed = try interpretStageResult(
            stageName: "redownload",
            result: stage2,
            account: account,
            adamId: cleanedAdamId,
            requestedVersion: cleanedVer,
            allowFallback: true
        ) {
            return DownloadFetchResult(info: parsed, updatedCookies: workingCookies)
        }

        // Stage 3: updateProduct
        onStageChange("Этап 3/3: fallback на updateProduct…")
        DiagnosticLogger.shared.logAsync(
            category: .download,
            level: .warning,
            engine: engine.shortName,
            message: "redownload не вернул пакет — переход на этап 3/3 (updateProduct)."
        )

        let updateBase = bag?.updateEndpoint ?? URL(string: "https://downloaddispatch.itunes.apple.com/up/updateProduct")!
        let updateURL = try appendGuid(to: updateBase)

        let stage3 = try await executeDownloadStage(
            stageName: "updateProduct",
            url: updateURL,
            account: account,
            cookies: &workingCookies,
            adamId: adamIdInt,
            externalVersionKey: "appExtVrsId",
            externalVersionValue: cleanedVer,
            engineLabel: engine.shortName
        )

        if let parsed = try interpretStageResult(
            stageName: "updateProduct",
            result: stage3,
            account: account,
            adamId: cleanedAdamId,
            requestedVersion: cleanedVer,
            allowFallback: false
        ) {
            return DownloadFetchResult(info: parsed, updatedCookies: workingCookies)
        }

        throw StoreError.appUnavailable(
            "Все 3 этапа (volumeStore → redownload → updateProduct) не вернули пакет для App ID \(cleanedAdamId). Проверьте, что приложение ранее скачивалось на этот Apple ID."
        )
    }

    private struct RawStageResponse {
        let statusCode: Int
        let data: Data
        let dict: [String: Any]?
    }

    private func executeDownloadStage(
        stageName: String,
        url: URL,
        account: AppleAccount,
        cookies: inout [StoredCookie],
        adamId: Int64,
        externalVersionKey: String,
        externalVersionValue: String,
        engineLabel: String
    ) async throws -> RawStageResponse {
        var currentURL = url

        for hop in 0...3 {
            var payload: [String: Any] = [
                "creditDisplay": "",
                "guid": account.guid,
                "salableAdamId": adamId,
                "serialNumber": "0"
            ]
            if !externalVersionValue.isEmpty {
                payload[externalVersionKey] = externalVersionValue
            }

            let bodyData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

            var request = URLRequest(url: currentURL)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(account.dsid, forHTTPHeaderField: "X-Dsid")
            request.setValue(account.dsid, forHTTPHeaderField: "iCloud-DSID")
            request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
            request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")

            if let cookieHeader = cookies.cookieHeaderValue(for: currentURL) {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StoreError.invalidResponse("Нет HTTP-ответа на этапе \(stageName)")
            }

            let incoming = extractCookies(from: http, url: currentURL)
            if !incoming.isEmpty {
                cookies.merge(incoming)
            }

            DiagnosticLogger.shared.logAsync(
                category: .download,
                level: http.statusCode == 200 ? .info : .warning,
                engine: engineLabel,
                httpStatus: http.statusCode,
                message: "\(stageName) [hop \(hop)] → HTTP \(http.statusCode) (\(data.count) байт)",
                details: "Host: \(currentURL.host ?? "") · Cookies: \(cookies.count)"
            )

            if [301, 302, 303, 307, 308].contains(http.statusCode),
               let location = headerValue(http, named: "location"),
               let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL,
               hop < 3 {
                currentURL = nextURL
                continue
            }

            return RawStageResponse(
                statusCode: http.statusCode,
                data: data,
                dict: parsePlistDictionary(data)
            )
        }

        throw StoreError.invalidResponse("Превышен лимит редиректов на этапе \(stageName)")
    }

    private func interpretStageResult(
        stageName: String,
        result: RawStageResponse,
        account: AppleAccount,
        adamId: String,
        requestedVersion: String,
        allowFallback: Bool
    ) throws -> AppDownloadInfo? {
        // HTTP 500 with empty body or non-200 recoverable when fallback is allowed
        if result.statusCode != 200 {
            if allowFallback && (result.statusCode == 500 || result.statusCode == 404) {
                return nil
            }
            throw StoreError.appUnavailable("Этап \(stageName) вернул HTTP \(result.statusCode).")
        }

        guard let dict = result.dict else {
            if allowFallback { return nil }
            throw StoreError.invalidResponse("Этап \(stageName) вернул некорректный plist.")
        }

        let failureType = dict["failureType"].map { String(describing: $0) } ?? ""
        let customerMessage = dict["customerMessage"] as? String ?? ""

        if !failureType.isEmpty {
            DiagnosticLogger.shared.logAsync(
                category: .download,
                level: .warning,
                engine: stageName,
                message: "Apple failureType=\(failureType)",
                details: customerMessage.isEmpty ? nil : customerMessage
            )

            switch failureType {
            case "9610":
                throw StoreError.licenseRequired
            case "2034", "2042":
                throw StoreError.tokenExpired
            case "5002":
                if allowFallback { return nil }
                throw StoreError.appUnavailable(customerMessage.isEmpty ? "Ошибка Apple 5002 на этапе \(stageName)." : customerMessage)
            default:
                if customerMessage.localizedCaseInsensitiveContains("password") {
                    throw StoreError.tokenExpired
                }
                if allowFallback { return nil }
                throw StoreError.appUnavailable(customerMessage.isEmpty ? "Ошибка Apple Store (код \(failureType))." : "\(customerMessage) (код \(failureType))")
            }
        }

        guard let songList = dict["songList"] as? [[String: Any]],
              let item = songList.first else {
            if allowFallback { return nil }
            return nil
        }

        guard let urlString = item["URL"] as? String,
              let downloadURL = URL(string: urlString) else {
            if allowFallback { return nil }
            throw StoreError.appUnavailable("В ответе Apple отсутствует ссылка на IPA.")
        }

        var metadata = item["metadata"] as? [String: Any] ?? [:]
        metadata["apple-id"] = account.email
        metadata["userName"] = account.email

        let metadataData = try PropertyListSerialization.data(
            fromPropertyList: metadata,
            format: .binary,
            options: 0
        )

        var sinfs: [SinfItem] = []
        if let rawSinfs = item["sinfs"] as? [[String: Any]] {
            for raw in rawSinfs {
                if let sinfData = raw["sinf"] as? Data {
                    let sinfId: Int64
                    if let n = raw["id"] as? Int64 {
                        sinfId = n
                    } else if let n = raw["id"] as? Int {
                        sinfId = Int64(n)
                    } else {
                        sinfId = 0
                    }
                    sinfs.append(SinfItem(id: sinfId, sinf: sinfData))
                }
            }
        }

        let name = (metadata["itemName"] as? String)
            ?? (metadata["bundleDisplayName"] as? String)
            ?? "App_\(adamId)"
        let bundleId = (metadata["softwareVersionBundleId"] as? String) ?? "unknown.bundle.id"
        let artistName = (metadata["artistName"] as? String) ?? "Unknown Developer"
        let shortVersion = (metadata["bundleShortVersionString"] as? String) ?? "1.0"
        let bundleVersion = (metadata["bundleVersion"] as? String) ?? "1"
        let resolvedExtVersion: String = {
            if let v = metadata["softwareVersionExternalIdentifier"] {
                return String(describing: v)
            }
            return requestedVersion.isEmpty ? "latest" : requestedVersion
        }()

        let allVersions: [String] = {
            guard let arr = metadata["softwareVersionExternalIdentifiers"] as? [Any] else {
                return [resolvedExtVersion]
            }
            let mapped = arr.map { String(describing: $0) }
            return mapped.isEmpty ? [resolvedExtVersion] : Array(mapped.reversed())
        }()

        let artworkUrl = (item["artworkURL"] as? String) ?? (metadata["softwareIcon57x57URL"] as? String)

        DiagnosticLogger.shared.logAsync(
            category: .download,
            level: .success,
            engine: stageName,
            httpStatus: 200,
            message: "Пакет получен: \(name) v\(shortVersion)",
            details: "Bundle: \(bundleId) · ExtVer: \(resolvedExtVersion) · Версий в истории: \(allVersions.count) · SINF: \(sinfs.count)"
        )

        return AppDownloadInfo(
            adamId: adamId,
            name: name,
            bundleId: bundleId,
            artistName: artistName,
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            externalVersionId: resolvedExtVersion,
            availableVersionIds: allVersions,
            downloadURL: downloadURL,
            sinfs: sinfs,
            metadataPlistData: metadataData,
            artworkUrl: artworkUrl,
            resolvedStage: stageName
        )
    }

    // MARK: - Acquire Free License (STDQ -> GAME fallback)

    func purchaseFreeApp(account: AppleAccount, adamId: String, engine: AuthEngineMode) async throws {
        prepareDeviceIdentity()
        guard let adamIdInt = Int64(adamId.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw StoreError.appUnavailable("Некорректный App ID.")
        }

        if engine == .applePackage {
            var apAccount = account.toApplePackageAccount()
            let stubSoftware = Software(
                id: adamIdInt,
                bundleID: "",
                name: "App_\(adamId)",
                version: "1.0",
                price: 0,
                artistName: "",
                sellerName: "",
                description: "",
                averageUserRating: 0,
                userRatingCount: 0,
                artworkUrl: "",
                screenshotUrls: [],
                minimumOsVersion: "12.0",
                fileSizeBytes: nil,
                releaseDate: "",
                formattedPrice: "Free",
                primaryGenreName: ""
            )
            try await Purchase.purchase(account: &apAccount, app: stubSoftware)
            DiagnosticLogger.shared.logAsync(
                category: .download,
                level: .success,
                engine: "ApplePackage",
                message: "Лицензия для App ID \(adamId) получена."
            )
            return
        }

        // URLSession STDQ -> GAME fallback
        do {
            try await sendBuyProduct(account: account, adamId: adamId, pricingParameters: "STDQ")
        } catch {
            if error.localizedDescription.contains("2059") {
                try await sendBuyProduct(account: account, adamId: adamId, pricingParameters: "GAME")
            } else {
                throw error
            }
        }
    }

    private func sendBuyProduct(account: AppleAccount, adamId: String, pricingParameters: String) async throws {
        let host = Configuration.purchaseAPIHost(pod: account.pod)
        guard let url = URL(string: "https://\(host)/WebObjects/MZBuy.woa/wa/buyProduct") else {
            throw StoreError.invalidResponse("Некорректный URL buyProduct")
        }

        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": account.guid,
            "needDiv": "0",
            "origPage": "Software-\(adamId)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricingParameters,
            "productType": "C",
            "salableAdamId": adamId
        ]

        let bodyData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(account.dsid, forHTTPHeaderField: "X-Dsid")
        request.setValue(account.dsid, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
        if let cookieHeader = account.cookies.cookieHeaderValue(for: url) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        DiagnosticLogger.shared.logAsync(
            category: .download,
            level: status == 200 ? .info : .warning,
            engine: "URLSession+SAP",
            httpStatus: status,
            message: "buyProduct (\(pricingParameters)) → HTTP \(status)"
        )

        guard let dict = parsePlistDictionary(data) else {
            throw StoreError.invalidResponse("Некорректный plist от buyProduct (HTTP \(status)).")
        }

        if let failureType = dict["failureType"].map({ String(describing: $0) }), !failureType.isEmpty {
            let message = dict["customerMessage"] as? String ?? "Не удалось получить лицензию (код \(failureType))"
            if failureType == "2034" || failureType == "2042" {
                throw StoreError.tokenExpired
            }
            if message.localizedCaseInsensitiveContains("already") {
                return
            }
            throw StoreError.appUnavailable("\(message) (код \(failureType))")
        }
    }

    // MARK: - Public App Store Search & Lookup

    func searchApps(term: String, countryCode: String, limit: Int = 25) async throws -> [AppSearchItem] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            throw StoreError.invalidResponse("Некорректный URL поиска")
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: countryCode.lowercased()),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw StoreError.invalidResponse("Некорректный URL поиска") }

        let (data, _) = try await urlSession.data(from: url)
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results
    }

    func lookupApp(adamId: String?, bundleId: String?, countryCode: String) async throws -> AppSearchItem? {
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else {
            return nil
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "country", value: countryCode.lowercased()),
            URLQueryItem(name: "entity", value: "software")
        ]
        if let adamId = adamId, !adamId.isEmpty {
            items.append(URLQueryItem(name: "id", value: adamId))
        } else if let bundleId = bundleId, !bundleId.isEmpty {
            items.append(URLQueryItem(name: "bundleId", value: bundleId))
        } else {
            return nil
        }
        components.queryItems = items

        guard let url = components.url else { return nil }
        let (data, _) = try await urlSession.data(from: url)
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results.first
    }

    // MARK: - Helpers

    private func buildStoreURL(host: String, path: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = path
        comps.queryItems = [URLQueryItem(name: "guid", value: deviceGUID)]
        guard let url = comps.url else {
            throw StoreError.invalidResponse("Не удалось собрать URL для \(path)")
        }
        return url
    }

    private func appendGuid(to baseURL: URL) throws -> URL {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw StoreError.invalidResponse("Некорректный базовый URL")
        }
        var query = comps.queryItems ?? []
        query.removeAll { $0.name == "guid" }
        query.append(URLQueryItem(name: "guid", value: deviceGUID))
        comps.queryItems = query
        guard let url = comps.url else {
            throw StoreError.invalidResponse("Не удалось собрать URL с guid")
        }
        return url
    }

    private func isApprovedAppleAuthURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "apple.com" || host.hasSuffix(".apple.com") else {
            return false
        }
        return true
    }

    private func parsePlistDictionary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else {
            return nil
        }
        return obj as? [String: Any]
    }

    private func headerValue(_ response: HTTPURLResponse, named name: String) -> String? {
        for (key, value) in response.allHeaderFields {
            if let keyStr = key as? String, keyStr.caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    private func extractCookies(from response: HTTPURLResponse, url: URL) -> [StoredCookie] {
        var stringHeaders: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String {
                stringHeaders[ks] = String(describing: v)
            }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: url)
        return parsed.map { StoredCookie(from: $0) }
    }
}
