#!/usr/bin/env python3
"""
Patches MapleSAP (StoreModels.swift and StoreSession.swift) to support direct
lookup and extraction of deleted/delisted App Store apps by numeric adamId,
omitting externalVersionId during version discovery and executing the full
4-tier Apple Store download cascade.
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


def patch_store_models(sap_dir: Path) -> None:
    path = sap_dir / "StoreModels.swift"
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


def patch_store_session(sap_dir: Path) -> None:
    path = sap_dir / "StoreSession.swift"

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

    new_payload = """    private static func pickPreferredError(current: Error?, candidate: Error) -> Error {
        guard let current = current else { return candidate }
        if let storeErr = candidate as? StoreError, storeErr == .licenseRequired {
            return candidate
        }
        return current
    }

    private func requestDescriptorDirect(
        _ app: StoreApp,
        version: String,
        expectedBundleID: String?
    ) async throws -> (app: StoreApp, download: StoreDownload) {
        var preferredError: Error?
        var lastError: Error?

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
                lastError = error
                preferredError = Self.pickPreferredError(current: preferredError, candidate: error)
            }
        }

        // 2. Pod volumeStoreDownloadProduct (cookie session, then X-Token)
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
                lastError = error
                preferredError = Self.pickPreferredError(current: preferredError, candidate: error)
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
                    lastError = error
                    preferredError = Self.pickPreferredError(current: preferredError, candidate: error)
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
                    lastError = error
                    preferredError = Self.pickPreferredError(current: preferredError, candidate: error)
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


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: patch_maplesap.py <path-to-MapleSAP-Sources>")
    sap_dir = Path(sys.argv[1]).resolve()
    if not (sap_dir / "StoreSession.swift").exists():
        raise SystemExit(f"[ERROR] StoreSession.swift not found under {sap_dir}")
    patch_store_models(sap_dir)
    patch_store_session(sap_dir)
    print("[SUCCESS] MapleSAP patched cleanly for direct Deleted Apps support.")


if __name__ == "__main__":
    main()
