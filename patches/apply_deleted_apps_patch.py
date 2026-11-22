#!/usr/bin/env python3
"""
Patches nxtcoreee3/WaffleStore (commit 921f364bb4659d5bc01b808c5bcd6d1119e4d2c5)
to combine its working MapleSAP / Unicorn-TCI / KBSync Apple ID login engine
with direct Deleted/Delisted App extraction by numeric App ID (adamId),
historical externalVersionId browsing, and unblocked FairPlay IPA export.
"""

from pathlib import Path
import sys


def patch_exact(path: Path, old: str, new: str, label: str) -> None:
    content = path.read_text(encoding="utf-8")
    count = content.count(old)
    if count != 1:
        raise SystemExit(
            f"[ERROR] Anchor mismatch in {path} for '{label}': expected 1 occurrence, found {count}."
        )
    path.write_text(content.replace(old, new, 1), encoding="utf-8")
    print(f"[OK] {path.name}: {label}")


def patch_store_models(root: Path) -> None:
    path = root / "MapleSyrup/SAPKit/Sources/MapleSAP/StoreModels.swift"
    old = """        return StoreDownload(url: url, externalVersionID: version,
            availableVersionIDs: Array(Set(versions + [version])).sorted { (UInt64($0) ?? 0) > (UInt64($1) ?? 0) },
            metadata: try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0),
            sinfs: sinfs, md5: item["md5"] as? String ?? "")
    }
    static func failure(_ root: [String: Any]) throws {"""

    new = """        return StoreDownload(url: url, externalVersionID: version,
            availableVersionIDs: Array(Set(versions + [version])).sorted { (UInt64($0) ?? 0) > (UInt64($1) ?? 0) },
            metadata: try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0),
            sinfs: sinfs, md5: item["md5"] as? String ?? "")
    }
    public static func downloadDirect(
        _ root: [String: Any],
        appID: String,
        requestedVersion: String = "",
        expectedBundleID: String? = nil,
        email: String
    ) throws -> (app: StoreApp, download: StoreDownload) {
        try failure(root)
        guard let items = root["songList"] as? [[String: Any]], let item = items.first,
              var metadata = item["metadata"] as? [String: Any] else { throw StoreError.unavailable }
        guard identifier(metadata["itemId"]) == appID else { throw StoreError.versionMismatch }
        let versions = (metadata["softwareVersionExternalIdentifiers"] as? [Any] ?? []).compactMap(identifier)
        let actualVersion = identifier(metadata["softwareVersionExternalIdentifier"]) ?? versions.last ?? ""
        guard !actualVersion.isEmpty else { throw StoreError.invalidResponse }
        if !requestedVersion.isEmpty && actualVersion != requestedVersion {
            throw StoreError.versionMismatch
        }
        guard let bundleID = metadata["softwareVersionBundleId"] as? String, !bundleID.isEmpty else {
            throw StoreError.invalidResponse
        }
        if let expectedBundleID = expectedBundleID, !expectedBundleID.isEmpty, bundleID != expectedBundleID {
            throw StoreError.versionMismatch
        }
        guard let text = item["URL"] as? String else { throw StoreError.invalidResponse }
        let url = try CDNPolicy.validate(text)
        let rawName = (metadata["itemName"] as? String)
            ?? (metadata["bundleDisplayName"] as? String)
            ?? (metadata["playlistName"] as? String)
            ?? bundleID
        let resolvedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? bundleID : rawName
        metadata["apple-id"] = email; metadata["userName"] = email
        let sinfItems = item["sinfs"] as? [[String: Any]] ?? []
        var sinfs: [Data] = []
        for entry in sinfItems {
            guard let data = entry["sinf"] as? Data, !data.isEmpty, data.count <= 1 << 20 else { throw StoreError.invalidResponse }
            sinfs.append(data)
        }
        let app = StoreApp(id: appID, bundleID: bundleID, name: resolvedName, price: nil)
        let download = StoreDownload(
            url: url,
            externalVersionID: actualVersion,
            availableVersionIDs: Array(Set(versions + [actualVersion])).sorted { (UInt64($0) ?? 0) > (UInt64($1) ?? 0) },
            metadata: try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0),
            sinfs: sinfs,
            md5: item["md5"] as? String ?? ""
        )
        return (app, download)
    }
    static func failure(_ root: [String: Any]) throws {"""

    patch_exact(path, old, new, "add StoreParsing.downloadDirect")


def patch_store_session(root: Path) -> None:
    path = root / "MapleSyrup/SAPKit/Sources/MapleSAP/StoreSession.swift"

    old_descriptor_end = """            return try await requestDescriptor(app, version: version)
        }
    }
    private func catalogCountry(_ override: String?) throws -> String {"""

    new_descriptor_end = """            return try await requestDescriptor(app, version: version)
        }
    }
    public func inspectDeleted(
        appID: String,
        externalVersionID: String = "",
        expectedBundleID: String? = nil
    ) async throws -> (app: StoreApp, download: StoreDownload) {
        guard !busy else { throw SAPError.invalidState }
        busy = true; defer { busy = false }
        guard StoreParsing.identifier(appID) != nil else { throw StoreError.invalidApp }
        guard externalVersionID.isEmpty || StoreParsing.identifier(externalVersionID) != nil else { throw StoreError.invalidApp }
        try await resolveBag()
        let placeholder = StoreApp(id: appID, bundleID: expectedBundleID ?? "", name: "App \\(appID)", price: nil)
        return try await requestDescriptorDirect(placeholder, version: externalVersionID, expectedBundleID: expectedBundleID)
    }
    private func catalogCountry(_ override: String?) throws -> String {"""

    patch_exact(path, old_descriptor_end, new_descriptor_end, "add inspectDeleted API")

    old_payload = """    private func payload(_ app: StoreApp, version: String, key: String) -> [String: Any] {
        ["creditDisplay": "", "guid": identity.guid, "salableAdamId": NSNumber(value: UInt64(app.id) ?? 0), "serialNumber": "0", key: version]
    }"""

    new_payload = """    private func requestDescriptorDirect(
        _ app: StoreApp,
        version: String,
        expectedBundleID: String?
    ) async throws -> (app: StoreApp, download: StoreDownload) {
        var preferredError: Error?
        var lastError: Error?

        func record(_ error: Error) {
            lastError = error
            if preferredError == nil {
                preferredError = error
            } else if let storeErr = error as? StoreError, storeErr == .licenseRequired {
                preferredError = error
            }
        }

        // 1. Enterprise / Configurator ent/download with account-bound kbsync
        if let endpoint = bag?["volumeStoreDownloadProduct"],
           URL(string: endpoint)?.path == "/WebObjects/DownloadDispatch.woa/wa/ent/download" {
            do {
                let url = try dispatchURL(endpoint, path: "/WebObjects/DownloadDispatch.woa/wa/ent/download")
                if let cached = try persistence.load(dsid: account.dsid, guid: account.guid) {
                    do {
                        return try await entDirect(url, app: app, version: version, expectedBundleID: expectedBundleID, blob: cached)
                    } catch {
                        try Task.checkCancellation()
                        if (error as? StoreError) == .sessionExpired { throw error }
                        if (error as? StoreError) == .licenseRequired { throw error }
                        await diagnostic("recovery=deleted-rejected-cached-kbsync; category=\\(ResponseDiagnostic.category(error))")
                        try? persistence.clear()
                    }
                }
                guard let dsid = UInt64(account.dsid), dsid > 0 else { throw AuthenticationError.invalidSession }
                await progress(.kbsync)
                let blob = try generator.generate(identity: identity, dsid: dsid)
                try Task.checkCancellation()
                let result = try await entDirect(url, app: app, version: version, expectedBundleID: expectedBundleID, blob: blob)
                try? persistence.save(blob, dsid: account.dsid, guid: account.guid)
                return result
            } catch {
                try Task.checkCancellation()
                if (error as? StoreError) == .sessionExpired { throw error }
                await diagnostic("recovery=deleted-ent-to-pod; category=\\(ResponseDiagnostic.category(error))")
                record(error)
            }
        }

        // 2. Pod volumeStoreDownloadProduct (try cookie session first, then with X-Token)
        let prefix = account.pod.map { "p\\($0)-" } ?? ""
        let legacy = URL(string: "https://\\(prefix)buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct")!
        for useToken in [false, true] {
            do {
                await progress(.legacy)
                let root = try await post(legacy, body: payload(app, version: version, key: "externalVersionId"), token: useToken)
                return try StoreParsing.downloadDirect(root, appID: app.id, requestedVersion: version, expectedBundleID: expectedBundleID, email: account.email)
            } catch {
                try Task.checkCancellation()
                if (error as? StoreError) == .sessionExpired && useToken { throw error }
                await diagnostic("recovery=deleted-pod-token-\\(useToken); category=\\(ResponseDiagnostic.category(error))")
                record(error)
            }
        }

        // 3. Bag redownloadProduct (/r/redownload)
        if let redownload = bag?["redownloadProduct"] {
            for useToken in [false, true] {
                do {
                    await progress(.redownload)
                    let root = try await post(dispatchURL(redownload, path: "/r/redownload"), body: payload(app, version: version, key: "appExtVrsId"), token: useToken)
                    return try StoreParsing.downloadDirect(root, appID: app.id, requestedVersion: version, expectedBundleID: expectedBundleID, email: account.email)
                } catch {
                    try Task.checkCancellation()
                    if (error as? StoreError) == .sessionExpired && useToken { throw error }
                    await diagnostic("recovery=deleted-redownload-token-\\(useToken); category=\\(ResponseDiagnostic.category(error))")
                    record(error)
                }
            }
        }

        // 4. Bag updateProduct (/up/updateProduct)
        if let update = bag?["updateProduct"] {
            for useToken in [false, true] {
                do {
                    await progress(.update)
                    let root = try await post(dispatchURL(update, path: "/up/updateProduct"), body: payload(app, version: version, key: "appExtVrsId"), token: useToken)
                    return try StoreParsing.downloadDirect(root, appID: app.id, requestedVersion: version, expectedBundleID: expectedBundleID, email: account.email)
                } catch {
                    try Task.checkCancellation()
                    if (error as? StoreError) == .sessionExpired && useToken { throw error }
                    await diagnostic("recovery=deleted-update-token-\\(useToken); category=\\(ResponseDiagnostic.category(error))")
                    record(error)
                }
            }
        }

        throw preferredError ?? lastError ?? StoreError.unavailable
    }

    private func entDirect(
        _ url: URL,
        app: StoreApp,
        version: String,
        expectedBundleID: String?,
        blob: Data
    ) async throws -> (app: StoreApp, download: StoreDownload) {
        guard !blob.isEmpty else { throw StoreError.native(8) }
        var body = payload(app, version: version, key: "externalVersionId")
        body["salableAdamId"] = app.id
        body["kbsync"] = blob.base64EncodedString()
        body["serialNumber"] = (Data([0x54, 0xc8, 0xb0, 0xa9, 0x88]) + identity.hardwareID.dropFirst(2)).base64EncodedString()
        await progress(.ent)
        let root = try await post(url, body: body, token: true, ent: true)
        return try StoreParsing.downloadDirect(root, appID: app.id, requestedVersion: version, expectedBundleID: expectedBundleID, email: account.email)
    }

    private func payload(_ app: StoreApp, version: String, key: String) -> [String: Any] {
        var body: [String: Any] = ["creditDisplay": "", "guid": identity.guid, "salableAdamId": NSNumber(value: UInt64(app.id) ?? 0), "serialNumber": "0"]
        if !version.isEmpty {
            body[key] = version
        }
        return body
    }"""

    patch_exact(path, old_payload, new_payload, "add 4-tier deleted-app cascade and optional version payload")


def patch_ipatool(root: Path) -> None:
    path = root / "WaffleStore/Functions/IPATool.swift"

    old_diag = """                if event.hasPrefix("scope=purchase;") || event.hasPrefix("purchase-") || event.hasPrefix("recovery=") {"""
    new_diag = """                if event.hasPrefix("scope=purchase;") || event.hasPrefix("scope=ent;") || event.hasPrefix("scope=pod;") || event.hasPrefix("scope=redownload;") || event.hasPrefix("scope=update;") || event.hasPrefix("purchase-") || event.hasPrefix("recovery=") {"""
    patch_exact(path, old_diag, new_diag, "expose store stage diagnostics in LogView")

    old_end = """        catch {
            print("Apple Store failure: category=\\(ResponseDiagnostic.category(error))")
            throw error
        }
    }
}"""

    new_end = """        catch {
            print("Apple Store failure: category=\\(ResponseDiagnostic.category(error))")
            throw error
        }
    }

    static func parseNumericAppID(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = StoreParsing.identifier(trimmed) {
            return direct
        }
        if trimmed.lowercased().hasPrefix("id"),
           let direct = StoreParsing.identifier(String(trimmed.dropFirst(2))) {
            return direct
        }
        if let regex = try? NSRegularExpression(pattern: #"(?:^|/|id)(\\d{5,})(?:$|[/?#&])"#, options: [.caseInsensitive]) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.matches(in: trimmed, range: range).last,
               match.numberOfRanges > 1,
               let numRange = Range(match.range(at: 1), in: trimmed) {
                return StoreParsing.identifier(String(trimmed[numRange]))
            }
        }
        return nil
    }

    func inspectAny(
        _ input: String,
        version: String = "",
        forceDirectDeleted: Bool = false
    ) async throws -> (app: StoreApp, download: StoreDownload, isDeleted: Bool) {
        AppData.shared.storeRequestCount += 1
        defer { AppData.shared.storeRequestCount -= 1 }
        let cleanVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let numericID = Self.parseNumericAppID(input)

        if forceDirectDeleted {
            guard let appID = numericID else { throw StoreError.invalidApp }
            print("Direct Deleted App mode: adamId=\\(appID) version=\\(cleanVersion.isEmpty ? "latest" : cleanVersion)")
            do {
                let resolved = try await session().inspectDeleted(appID: appID, externalVersionID: cleanVersion)
                return (resolved.app, resolved.download, true)
            } catch {
                print("Direct Deleted App failure: category=\\(ResponseDiagnostic.category(error))")
                throw error
            }
        }

        do {
            let app = try await session().lookup(input)
            let download = try await session().descriptor(app: app, externalVersionID: cleanVersion)
            return (app, download, false)
        } catch {
            if let appID = numericID,
               let storeErr = error as? StoreError,
               storeErr == .unavailable || storeErr == .http(404) || storeErr == .invalidResponse {
                print("Catalog lookup unavailable for ID \\(appID); falling back to Direct Deleted App mode…")
                do {
                    let resolved = try await session().inspectDeleted(appID: appID, externalVersionID: cleanVersion)
                    return (resolved.app, resolved.download, true)
                } catch {
                    print("Direct Deleted App fallback failure: category=\\(ResponseDiagnostic.category(error))")
                    throw error
                }
            }
            print("Apple Store failure: category=\\(ResponseDiagnostic.category(error))")
            throw error
        }
    }

    func descriptorDirect(app: StoreApp, version: String) async throws -> StoreDownload {
        AppData.shared.storeRequestCount += 1
        defer { AppData.shared.storeRequestCount -= 1 }
        do {
            let resolved = try await session().inspectDeleted(
                appID: app.id,
                externalVersionID: version,
                expectedBundleID: app.bundleID
            )
            return resolved.download
        } catch {
            print("Direct Deleted App download failure: category=\\(ResponseDiagnostic.category(error))")
            throw error
        }
    }
}"""

    patch_exact(path, old_end, new_end, "add inspectAny and descriptorDirect")


def patch_downgrader(root: Path) -> None:
    path = root / "WaffleStore/Functions/Downgrader.swift"

    old_fn = """func downgradeApp(appId: String, ipaTool: IPATool) {
    let appData = AppData.shared
    appData.applicationStatus = "Finding available versions…"
    Task { @MainActor in
        do {
            let app = try await ipaTool.lookup(appId)
            let latest = try await ipaTool.descriptor(app: app)
            let versions = latest.availableVersionIDs
            guard !versions.isEmpty else { throw StoreError.unavailable }
            appData.isDowngrading = false
            let alert = UIAlertController(title: "Select a version".localized,
                                          message: "Select a version to downgrade".localized,
                                          preferredStyle: UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet)
            for version in versions {
                alert.addAction(UIAlertAction(title: version, style: .default) { _ in
                    appData.isDowngrading = true
                    appData.download(app: app, version: version, tool: ipaTool)
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel) { _ in
                resetDowngradeProgress()
            })
            UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true)
        } catch {
            resetDowngradeProgress()
            Alertinator.shared.alert(title: "Failed to find app versions".localized,
                                     body: (error as? LocalizedError)?.errorDescription ?? "Store operation failed." )
        }
    }
}"""

    new_fn = """@MainActor
private func topViewControllerForPresentation() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let keyWindow = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
        ?? scenes.flatMap { $0.windows }.first
        ?? UIApplication.shared.windows.first
    var top = keyWindow?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}

func downgradeApp(appId: String, ipaTool: IPATool, manualVersion: String = "", forceDirectDeleted: Bool = false) {
    let appData = AppData.shared
    let cleanVersion = manualVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    appData.applicationStatus = forceDirectDeleted
        ? "Direct lookup for deleted App ID \\(appId)…"
        : "Finding available versions…"
    Task { @MainActor in
        do {
            let (app, latest, isDeleted) = try await ipaTool.inspectAny(
                appId,
                version: cleanVersion,
                forceDirectDeleted: forceDirectDeleted
            )
            appData.appBundleID = app.bundleID
            appData.appVersion = latest.externalVersionID
            appData.isDeletedMode = isDeleted
            print("Resolved: \\(app.name) (\\(app.bundleID)) • versions=\\(latest.availableVersionIDs.count) • mode=\\(isDeleted ? "deleted-direct" : "catalog")")

            if !cleanVersion.isEmpty {
                appData.isDowngrading = true
                appData.download(app: app, version: latest.externalVersionID, tool: ipaTool, isDeletedDirect: isDeleted)
                return
            }

            let versions = latest.availableVersionIDs
            guard !versions.isEmpty else { throw StoreError.unavailable }
            appData.isDowngrading = false
            let title = isDeleted ? "\\(app.name) [Deleted]" : app.name
            let message = "Bundle ID: \\(app.bundleID)\\nApp ID: \\(app.id) • Versions: \\(versions.count)"
            let alert = UIAlertController(
                title: title,
                message: message,
                preferredStyle: UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet
            )
            for version in versions {
                let label = version == latest.externalVersionID ? "\\(version) (Latest)" : version
                alert.addAction(UIAlertAction(title: label, style: .default) { _ in
                    appData.isDowngrading = true
                    appData.download(app: app, version: version, tool: ipaTool, isDeletedDirect: isDeleted)
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel) { _ in
                resetDowngradeProgress()
            })
            if let presenter = topViewControllerForPresentation() {
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                    popover.permittedArrowDirections = []
                }
                presenter.present(alert, animated: true)
            }
        } catch {
            resetDowngradeProgress()
            Alertinator.shared.alert(title: "Failed to find app versions".localized,
                                     body: (error as? LocalizedError)?.errorDescription ?? "Store operation failed." )
        }
    }
}"""

    patch_exact(path, old_fn, new_fn, "upgrade downgradeApp for deleted apps & version selection")

    old_dl_sig = """    func download(app: StoreApp, version: String, tool: IPATool, expectedVersion: String? = nil, installWhenReady: Bool = false) {"""
    new_dl_sig = """    func download(app: StoreApp, version: String, tool: IPATool, expectedVersion: String? = nil, installWhenReady: Bool = false, isDeletedDirect: Bool = false) {"""
    patch_exact(path, old_dl_sig, new_dl_sig, "add isDeletedDirect flag to download")

    old_desc = """                let descriptor = try await tool.descriptor(app: app, version: version)"""
    new_desc = """                let descriptor = isDeletedDirect
                    ? try await tool.descriptorDirect(app: app, version: version)
                    : try await tool.descriptor(app: app, version: version)"""
    patch_exact(path, old_desc, new_desc, "route deleted-app downloads via descriptorDirect")

    old_enc = """                case .encrypted:
                    print("[diagnostic] IPA is FairPlay-encrypted")
                    guard AppData.shared.allowEncryptedIPASigning else { throw IPAHandlingError.encryptedIPA }
                    storeStage("Encrypted IPA allowed for signing attempt")"""

    new_enc = """                case .encrypted:
                    print("[diagnostic] IPA is FairPlay-encrypted (kept in Downloads for Export / Apple ID backup)")
                    storeStage("FairPlay IPA validated — saving for export")"""
    patch_exact(path, old_enc, new_enc, "allow saving FairPlay-encrypted IPAs for export")


def patch_app_data(root: Path) -> None:
    path = root / "WaffleStore/AppData.swift"
    old = """    @Published var appLink: String = "" """.rstrip()
    new = """    @Published var appLink: String = ""
    @Published var manualVersionId: String = ""
    @Published var isDeletedMode: Bool = false"""
    patch_exact(path, old, new, "add manualVersionId and isDeletedMode state")


def patch_content_view(root: Path) -> None:
    path = root / "WaffleStore/ContentView.swift"
    old = """    private var InputAppSection: some View {
        Section(header: HeaderLabel(text: "Downgrade App".localized, icon: "arrow.down.app"), footer: Text("To downgrade an app, it must have been purchased on your account at some point in the past (when the app has a cloud icon next to it). The apps now need some sort of signing to work. Either export the IPAs and sign it yourself or import your signing certificates in Settings.".localized)) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("App Store Link".localized, text: $appData.appLink)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !appData.appLink.isEmpty {
                        Button {
                            appData.appLink = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear app link")
                    }
                }
                .modifier(TextFieldBackground())

                Button(action: {
                    Haptic.shared.play(.soft)
                    showSearchView.toggle()
                }) {
                    ButtonLabel(text: "Search App Store".localized, icon: "magnifyingglass")
                }
                .buttonStyle(TranslucentButtonStyle())
            }
        }
    }"""

    new = """    private var InputAppSection: some View {
        Section(
            header: HeaderLabel(text: "Downgrade / Deleted App".localized, icon: "arrow.down.app"),
            footer: Text("Введите ссылку App Store или числовой App ID (adamId), в том числе для удалённых приложений, которые ранее были в покупках этого Apple ID. Готовый IPA сохраняется в Documents/Downloads и доступен через Export IPA.".localized)
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("App Store Link или App ID (напр. 310633997)", text: $appData.appLink)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !appData.appLink.isEmpty {
                        Button {
                            appData.appLink = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear app link")
                    }
                }
                .modifier(TextFieldBackground())

                HStack(spacing: 8) {
                    TextField("External Version ID (необязательно)", text: $appData.manualVersionId)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !appData.manualVersionId.isEmpty {
                        Button {
                            appData.manualVersionId = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear version ID")
                    }
                }
                .modifier(TextFieldBackground())

                Button(action: {
                    Haptic.shared.play(.soft)
                    guard let ipaTool = appData.ipaTool else { return }
                    let appID = extractAppId(from: appData.appLink)
                    guard !appID.isEmpty else {
                        Alertinator.shared.alert(
                            title: "Введите App ID",
                            body: "Укажите числовой App ID (например, 310633997) или ссылку App Store."
                        )
                        return
                    }
                    appData.isDowngrading = true
                    appData.hasAppBeenServed = false
                    downgradeApp(
                        appId: appID,
                        ipaTool: ipaTool,
                        manualVersion: appData.manualVersionId,
                        forceDirectDeleted: true
                    )
                }) {
                    ButtonLabel(text: "Найти удалённое по ID (без каталога)", icon: "archivebox.fill")
                }
                .buttonStyle(TranslucentButtonStyle())
                .disabled(appData.appLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: {
                    Haptic.shared.play(.soft)
                    showSearchView.toggle()
                }) {
                    ButtonLabel(text: "Search App Store".localized, icon: "magnifyingglass")
                }
                .buttonStyle(TranslucentButtonStyle())
            }
        }
    }"""

    patch_exact(path, old, new, "add Deleted App ID & optional External Version ID controls")


def patch_navigation_buttons(root: Path) -> None:
    path = root / "WaffleStore/App/NavigationButtons.swift"
    old = """    private func startDowngrade() {
        guard !appData.appLink.isEmpty, let ipaTool = appData.ipaTool else { return }
        let appID = extractAppId(from: appData.appLink)
        guard !appID.isEmpty else { return }
        print("App ID: \\(appID)")
        appData.isDowngrading = true
        appData.hasAppBeenServed = false
        downgradeApp(appId: appID, ipaTool: ipaTool)
    }
}

func extractAppId(from link: String) -> String {
    var parsed = link.components(separatedBy: "id").last ?? ""
    for char in parsed {
        if !char.isNumber {
            if let index = parsed.firstIndex(of: char) {
                parsed = String(parsed.prefix(upTo: index))
            }
            break
        }
    }
    return parsed
}"""

    new = """    private func startDowngrade() {
        guard !appData.appLink.isEmpty, let ipaTool = appData.ipaTool else { return }
        let appID = extractAppId(from: appData.appLink)
        guard !appID.isEmpty else {
            Alertinator.shared.alert(
                title: "Неверный App ID",
                body: "Введите числовой App ID (например, 310633997) или корректную ссылку App Store."
            )
            return
        }
        print("App ID: \\(appID)")
        appData.isDowngrading = true
        appData.hasAppBeenServed = false
        downgradeApp(
            appId: appID,
            ipaTool: ipaTool,
            manualVersion: appData.manualVersionId,
            forceDirectDeleted: false
        )
    }
}

func extractAppId(from link: String) -> String {
    let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty && trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
        return trimmed
    }
    if trimmed.lowercased().hasPrefix("id") {
        let tail = String(trimmed.dropFirst(2))
        if !tail.isEmpty && tail.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return tail
        }
    }
    if let regex = try? NSRegularExpression(pattern: #"(?:^|/|id)(\\d{5,})(?:$|[/?#&])"#, options: [.caseInsensitive]) {
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if let match = regex.matches(in: trimmed, range: range).last,
           match.numberOfRanges > 1,
           let numRange = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[numRange])
        }
    }
    var parsed = trimmed.components(separatedBy: "id").last ?? ""
    for char in parsed {
        if !char.isNumber {
            if let index = parsed.firstIndex(of: char) {
                parsed = String(parsed.prefix(upTo: index))
            }
            break
        }
    }
    return parsed
}"""

    patch_exact(path, old, new, "harden extractAppId and pass manualVersion")


def patch_ipabuild(root: Path) -> None:
    path = root / "ipabuild.sh"
    old = """    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO" """.rstrip()
    new = """    DEVELOPMENT_TEAM="" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO" """.rstrip()
    content = path.read_text(encoding="utf-8")
    if content.count(old) < 1:
        raise SystemExit(f"[ERROR] Anchor mismatch in {path} for ipabuild.sh")
    path.write_text(content.replace(old, new), encoding="utf-8")
    print(f"[OK] {path.name}: strip DEVELOPMENT_TEAM for unsigned CI builds")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: apply_deleted_apps_patch.py <path-to-WaffleStore>")
    root = Path(sys.argv[1]).resolve()
    if not (root / "WaffleStore.xcodeproj").exists():
        raise SystemExit(f"[ERROR] WaffleStore.xcodeproj not found under {root}")

    patch_store_models(root)
    patch_store_session(root)
    patch_ipatool(root)
    patch_downgrader(root)
    patch_app_data(root)
    patch_content_view(root)
    patch_navigation_buttons(root)
    patch_ipabuild(root)
    print("[SUCCESS] All Deleted Apps & FairPlay Export patches applied cleanly.")


if __name__ == "__main__":
    main()
