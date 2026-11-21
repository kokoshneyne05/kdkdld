import Foundation
import SwiftUI

@MainActor
final class AppStoreManager: ObservableObject {
    // Accounts
    @Published var accounts: [AppleAccount] = []
    @Published var selectedAccountId: UUID?

    // Auth state
    @Published var isAuthenticating = false
    @Published var requiresTwoFactor = false
    @Published var authErrorMessage: String?

    // Direct App ID / Deleted App Extractor state
    @Published var inputAdamId: String = ""
    @Published var inputVersionId: String = ""
    @Published var inspectedInfo: AppDownloadInfo?
    @Published var downloadState: DownloadState = .idle

    // Search state
    @Published var searchQuery: String = ""
    @Published var searchResults: [AppSearchItem] = []
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var statusBanner: String?

    // Local Library
    @Published var savedIPAs: [LocalIPAFile] = []

    var activeAccount: AppleAccount? {
        if let id = selectedAccountId, let found = accounts.first(where: { $0.id == id }) {
            return found
        }
        return accounts.first
    }

    init() {
        self.accounts = KeychainStore.shared.loadAccounts()
        self.selectedAccountId = accounts.first?.id
        refreshLibrary()
    }

    // MARK: - Accounts & Auth

    func signIn(email: String, password: String, authCode: String?, countryCode: String) async -> Bool {
        isAuthenticating = true
        authErrorMessage = nil
        defer { isAuthenticating = false }

        do {
            let existing = accounts.first(where: { $0.email.lowercased() == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            let account = try await AppleStoreClient.shared.authenticate(
                email: email,
                password: password,
                authCode: authCode,
                countryCode: countryCode,
                existingGuid: existing?.guid
            )

            accounts.removeAll(where: { $0.email.lowercased() == account.email.lowercased() })
            accounts.insert(account, at: 0)
            selectedAccountId = account.id
            requiresTwoFactor = false
            try KeychainStore.shared.saveAccounts(accounts)
            return true
        } catch let error as StoreError {
            if case .twoFactorRequired(let msg) = error {
                requiresTwoFactor = true
                authErrorMessage = msg
            } else {
                authErrorMessage = error.localizedDescription
            }
            return false
        } catch {
            authErrorMessage = error.localizedDescription
            return false
        }
    }

    func removeAccount(_ account: AppleAccount) {
        accounts.removeAll(where: { $0.id == account.id })
        if selectedAccountId == account.id {
            selectedAccountId = accounts.first?.id
        }
        try? KeychainStore.shared.saveAccounts(accounts)
    }

    func updateAccountRegion(_ account: AppleAccount, newCountryCode: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].countryCode = newCountryCode.uppercased()
        accounts[idx].storeFront = StorefrontRegion.storefrontHeader(for: newCountryCode)
        try? KeychainStore.shared.saveAccounts(accounts)
    }

    // MARK: - Inspect & Download by App ID (Including Deleted Apps)

    func inspectByAppID() async {
        guard let account = activeAccount else {
            downloadState = .failed("Сначала войдите в Apple ID во вкладке «Аккаунты».")
            return
        }

        let cleanId = inputAdamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            downloadState = .failed("Укажите числовой App ID (adamId).")
            return
        }

        downloadState = .inspecting
        inspectedInfo = nil

        do {
            let versionArg = inputVersionId.trimmingCharacters(in: .whitespacesAndNewlines)
            let info = try await AppleStoreClient.shared.fetchDownloadInfo(
                account: account,
                adamId: cleanId,
                externalVersionId: versionArg.isEmpty ? nil : versionArg
            )
            inspectedInfo = info
            downloadState = .idle
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    func startDownload(externalVersionOverride: String? = nil) async {
        guard let account = activeAccount else {
            downloadState = .failed("Сначала войдите в Apple ID во вкладке «Аккаунты».")
            return
        }

        let cleanId = inputAdamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            downloadState = .failed("Укажите числовой App ID (adamId).")
            return
        }

        downloadState = .inspecting

        do {
            let targetVer = externalVersionOverride ?? inputVersionId.trimmingCharacters(in: .whitespacesAndNewlines)
            let info = try await AppleStoreClient.shared.fetchDownloadInfo(
                account: account,
                adamId: cleanId,
                externalVersionId: targetVer.isEmpty ? nil : targetVer
            )
            inspectedInfo = info

            let savedFile = try await IPADownloaderService.shared.downloadAndPatchIPA(
                info: info,
                onProgress: { [weak self] progress, received, total in
                    Task { @MainActor in
                        self?.downloadState = .downloading(progress: progress, received: received, total: total)
                    }
                },
                onPatching: { [weak self] in
                    Task { @MainActor in
                        self?.downloadState = .patching
                    }
                }
            )

            refreshLibrary()
            downloadState = .finished(savedFile)
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    func claimLicenseForCurrentID() async {
        guard let account = activeAccount else {
            downloadState = .failed("Сначала войдите в Apple ID.")
            return
        }
        let cleanId = inputAdamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        downloadState = .inspecting
        do {
            try await AppleStoreClient.shared.purchaseFreeApp(account: account, adamId: cleanId)
            statusBanner = "Лицензия для ID \(cleanId) получена. Теперь можно извлекать IPA."
            await inspectByAppID()
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    func cancelDownload() {
        IPADownloaderService.shared.cancelActiveDownload()
        downloadState = .idle
    }

    // MARK: - Public Search

    func performSearch() async {
        let term = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }

        isSearching = true
        searchError = nil
        defer { isSearching = false }

        let country = activeAccount?.countryCode ?? "RU"
        do {
            // If user entered a numeric App ID or bundle ID, try lookup first
            if term.allSatisfy({ $0.isNumber }) {
                if let item = try await AppleStoreClient.shared.lookupApp(adamId: term, bundleId: nil, countryCode: country) {
                    searchResults = [item]
                    return
                }
            } else if term.contains(".") && !term.contains(" ") {
                if let item = try await AppleStoreClient.shared.lookupApp(adamId: nil, bundleId: term, countryCode: country) {
                    searchResults = [item]
                    return
                }
            }
            searchResults = try await AppleStoreClient.shared.searchApps(term: term, countryCode: country)
        } catch {
            searchError = error.localizedDescription
        }
    }

    func purchaseFromSearch(_ item: AppSearchItem) async {
        guard let account = activeAccount else {
            searchError = "Войдите в Apple ID, чтобы привязать бесплатную лицензию."
            return
        }
        do {
            try await AppleStoreClient.shared.purchaseFreeApp(account: account, adamId: item.adamIdString)
            statusBanner = "Лицензия «\(item.trackName)» добавлена на аккаунт."
        } catch {
            searchError = error.localizedDescription
        }
    }

    // MARK: - Local Library

    func refreshLibrary() {
        savedIPAs = IPADownloaderService.shared.listSavedIPAs()
    }

    func deleteLocalIPA(_ file: LocalIPAFile) {
        try? IPADownloaderService.shared.deleteIPA(file)
        refreshLibrary()
    }
}
