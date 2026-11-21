import Foundation

/// Preserves HTTP POST method, body, and headers across Apple's 302 pod redirects
/// (e.g. buy.itunes.apple.com -> p48-buy.itunes.apple.com).
private final class RedirectPreservingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest,
              let newURL = request.url else {
            completionHandler(request)
            return
        }

        var redirected = URLRequest(url: newURL)
        redirected.httpMethod = original.httpMethod
        redirected.httpBody = original.httpBody
        redirected.allHTTPHeaderFields = original.allHTTPHeaderFields
        completionHandler(redirected)
    }
}

final class AppleStoreClient {
    static let shared = AppleStoreClient()

    private let userAgent = "Configurator/2.15 (Macintosh; OS X 11.0.0; 16G29) AppleWebKit/2603.3.8"
    private let redirectDelegate = RedirectPreservingDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()

    private init() {}

    /// Generates a deterministic-format 12-character hex GUID (MAC-style) for Apple Store endpoints.
    static func generateGUID() -> String {
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Authentication (Apple ID + 2FA)

    func authenticate(
        email: String,
        password: String,
        authCode: String?,
        countryCode: String,
        existingGuid: String? = nil
    ) async throws -> AppleAccount {
        let guid = existingGuid ?? Self.generateGUID()
        let cleanedCode = authCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combinedPassword = cleanedCode.isEmpty ? password : "\(password)\(cleanedCode)"

        var currentPod: String? = nil
        var lastError: Error = StoreError.invalidResponse

        // Apple's MZFinance endpoint expects attempt=4 on 2FA submission and may redirect pods across attempts.
        let attemptsToTry = cleanedCode.isEmpty ? [1, 2, 4] : [4, 2]

        for attempt in attemptsToTry {
            let host = currentPod.map { "p\($0)-buy.itunes.apple.com" } ?? "buy.itunes.apple.com"
            guard let url = URL(string: "https://\(host)/WebObjects/MZFinance.woa/wa/authenticate?guid=\(guid)") else {
                throw StoreError.invalidResponse
            }

            let payload: [String: Any] = [
                "appleId": email.trimmingCharacters(in: .whitespacesAndNewlines),
                "attempt": String(attempt),
                "createSession": "true",
                "guid": guid,
                "password": combinedPassword,
                "rmp": "0",
                "why": "signIn"
            ]

            let bodyData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            // MZFinance authenticate specifically expects x-www-form-urlencoded header with XML plist body.
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StoreError.invalidResponse
            }

            if let podHeader = headerValue(http, named: "pod") ?? headerValue(http, named: "itspod"),
               !podHeader.isEmpty {
                currentPod = podHeader
            }

            guard let dict = parsePlistDictionary(data) else {
                if http.statusCode == 404 {
                    lastError = StoreError.networkError("Сервер Apple вернул 404 (попробуйте сменить сеть или повторить попытку).")
                    continue
                }
                throw StoreError.invalidResponse
            }

            // Successful sign-in check
            if let passwordToken = dict["passwordToken"] as? String,
               let dsidRaw = dict["dsPersonId"] {
                let dsid = String(describing: dsidRaw)
                if !passwordToken.isEmpty && !dsid.isEmpty {
                    let accountInfo = dict["accountInfo"] as? [String: Any]
                    let address = accountInfo?["address"] as? [String: Any]
                    let firstName = address?["firstName"] as? String ?? ""
                    let lastName = address?["lastName"] as? String ?? ""

                    let resolvedPod = currentPod ?? "25"
                    let serverStoreFront = headerValue(http, named: "x-set-apple-store-front")
                    let resolvedStoreFront = (serverStoreFront?.isEmpty == false)
                        ? serverStoreFront!
                        : StorefrontRegion.storefrontHeader(for: countryCode)

                    return AppleAccount(
                        id: UUID(),
                        email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                        firstName: firstName,
                        lastName: lastName,
                        dsid: dsid,
                        passwordToken: passwordToken,
                        pod: resolvedPod,
                        storeFront: resolvedStoreFront,
                        countryCode: countryCode.uppercased(),
                        guid: guid,
                        createdAt: Date()
                    )
                }
            }

            let failureType = dict["failureType"] as? String ?? ""
            let customerMessage = dict["customerMessage"] as? String ?? ""

            // Apple triggers 2FA with empty failureType and MZFinance.BadLogin.Configurator_message
            if failureType.isEmpty &&
                (customerMessage == "MZFinance.BadLogin.Configurator_message" ||
                 customerMessage.localizedCaseInsensitiveContains("verification") ||
                 customerMessage.localizedCaseInsensitiveContains("code")) {
                if cleanedCode.isEmpty {
                    throw StoreError.twoFactorRequired(
                        "Apple отправила 6-значный код подтверждения на ваши устройства. Введите его ниже и нажмите «Войти»."
                    )
                } else {
                    lastError = StoreError.twoFactorRequired(
                        "Код 2FA не принят или истёк. Запросите новый код и повторите вход."
                    )
                    continue
                }
            }

            // Wrong credentials or explicit Apple failure message
            if !customerMessage.isEmpty {
                lastError = StoreError.invalidCredentials("\(customerMessage) (код: \(failureType.isEmpty ? "—" : failureType))")
                if failureType == "-5000" || failureType == "2034" || failureType == "2042" {
                    break
                }
            } else {
                lastError = StoreError.invalidCredentials("Не удалось выполнить вход. Проверьте Apple ID и пароль.")
            }
        }

        throw lastError
    }

    // MARK: - Public App Store Search & Lookup

    func searchApps(term: String, countryCode: String, limit: Int = 25) async throws -> [AppSearchItem] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            throw StoreError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: countryCode.lowercased()),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { throw StoreError.invalidResponse }

        let (data, _) = try await session.data(from: url)
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
        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results.first
    }

    // MARK: - Acquire Free License (buyProduct)

    func purchaseFreeApp(account: AppleAccount, adamId: String) async throws {
        let podHost = "p\(account.pod)-buy.itunes.apple.com"
        guard let url = URL(string: "https://\(podHost)/WebObjects/MZBuy.woa/wa/buyProduct") else {
            throw StoreError.invalidResponse
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
            "pricingParameters": "STDQ",
            "productType": "C",
            "salableAdamId": adamId
        ]

        let bodyData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(account.dsid, forHTTPHeaderField: "X-Dsid")
        request.setValue(account.dsid, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")

        let (data, _) = try await session.data(for: request)
        guard let dict = parsePlistDictionary(data) else {
            throw StoreError.invalidResponse
        }

        if let failureType = dict["failureType"] as? String, !failureType.isEmpty {
            let message = dict["customerMessage"] as? String ?? "Не удалось получить лицензию (код \(failureType))"
            if failureType == "2034" || failureType == "2042" {
                throw StoreError.tokenExpired
            }
            // Already purchased / owned is fine to proceed
            if message.localizedCaseInsensitiveContains("already") {
                return
            }
            throw StoreError.appUnavailable(message)
        }
    }

    // MARK: - Direct Download Info by App ID (Works for Deleted/Delisted Purchased Apps!)

    func fetchDownloadInfo(
        account: AppleAccount,
        adamId: String,
        externalVersionId: String? = nil
    ) async throws -> AppDownloadInfo {
        let cleanedAdamId = adamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAdamId.isEmpty else {
            throw StoreError.appUnavailable("Введите корректный числовой App ID (adamId).")
        }

        let podHost = "p\(account.pod)-buy.itunes.apple.com"
        guard let url = URL(string: "https://\(podHost)/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(account.guid)") else {
            throw StoreError.invalidResponse
        }

        var payload: [String: Any] = [
            "creditDisplay": "",
            "guid": account.guid,
            "salableAdamId": cleanedAdamId
        ]
        if let ver = externalVersionId?.trimmingCharacters(in: .whitespacesAndNewlines), !ver.isEmpty {
            payload["externalVersionId"] = ver
        }

        let bodyData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(account.dsid, forHTTPHeaderField: "X-Dsid")
        request.setValue(account.dsid, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")

        let (data, _) = try await session.data(for: request)
        guard let dict = parsePlistDictionary(data) else {
            throw StoreError.invalidResponse
        }

        if let failureType = dict["failureType"] as? String, !failureType.isEmpty {
            let customerMessage = dict["customerMessage"] as? String ?? ""
            switch failureType {
            case "9610":
                throw StoreError.licenseRequired
            case "2034", "2042":
                throw StoreError.tokenExpired
            default:
                let msg = customerMessage.isEmpty
                    ? "Ошибка Apple Store (failureType: \(failureType))"
                    : "\(customerMessage) (код: \(failureType))"
                throw StoreError.appUnavailable(msg)
            }
        }

        guard let songList = dict["songList"] as? [[String: Any]],
              let item = songList.first else {
            throw StoreError.appUnavailable("Сервер Apple не вернул пакет для App ID \(cleanedAdamId). Возможно, приложение не было куплено на этом аккаунте или полностью удалено с CDN.")
        }

        guard let urlString = item["URL"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw StoreError.appUnavailable("В ответе Apple отсутствует ссылка на скачивание IPA.")
        }

        var metadata = item["metadata"] as? [String: Any] ?? [:]
        // Attach purchaser appleId for valid iTunesMetadata.plist
        metadata["apple-id"] = account.email
        metadata["userName"] = account.email

        let metadataData = try PropertyListSerialization.data(
            fromPropertyList: metadata,
            format: .xml,
            options: 0
        )

        var sinfs: [SinfItem] = []
        if let rawSinfs = item["sinfs"] as? [[String: Any]] {
            for raw in rawSinfs {
                if let sinfData = raw["sinf"] as? Data {
                    let sinfId = (raw["id"] as? Int) ?? 0
                    sinfs.append(SinfItem(id: sinfId, sinf: sinfData))
                }
            }
        }

        let name = (metadata["itemName"] as? String)
            ?? (metadata["bundleDisplayName"] as? String)
            ?? "App_\(cleanedAdamId)"
        let bundleId = (metadata["softwareVersionBundleId"] as? String) ?? "unknown.bundle.id"
        let artistName = (metadata["artistName"] as? String) ?? "Unknown Developer"
        let shortVersion = (metadata["bundleShortVersionString"] as? String) ?? "1.0"
        let bundleVersion = (metadata["bundleVersion"] as? String) ?? "1"
        let resolvedExtVersion: String = {
            if let v = metadata["softwareVersionExternalIdentifier"] {
                return String(describing: v)
            }
            return externalVersionId ?? "latest"
        }()

        let allVersions: [String] = {
            guard let arr = metadata["softwareVersionExternalIdentifiers"] as? [Any] else {
                return [resolvedExtVersion]
            }
            let mapped = arr.map { String(describing: $0) }
            return mapped.isEmpty ? [resolvedExtVersion] : Array(mapped.reversed())
        }()

        let artworkUrl = (item["artworkURL"] as? String) ?? (metadata["softwareIcon57x57URL"] as? String)

        return AppDownloadInfo(
            adamId: cleanedAdamId,
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
            artworkUrl: artworkUrl
        )
    }

    // MARK: - Helpers

    private func parsePlistDictionary(_ data: Data) -> [String: Any]? {
        guard let obj = try? PropertyListSerialization.propertyList(
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
}
