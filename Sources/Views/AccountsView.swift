import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var manager: AppStoreManager
    @ObservedObject private var logger = DiagnosticLogger.shared

    @State private var email = ""
    @State private var password = ""
    @State private var authCode = ""
    @State private var selectedCountry = "RU"

    var body: some View {
        NavigationStack {
            Form {
                engineAndDiagnosticsSection
                signInSection
                savedAccountsSection
            }
            .navigationTitle("Аккаунты Apple ID")
        }
    }

    private var engineAndDiagnosticsSection: some View {
        Section {
            Picker("Движок авторизации", selection: $manager.selectedEngine) {
                ForEach(AuthEngineMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Text(manager.selectedEngine.subtitle)
                .font(.caption)
                .foregroundColor(.secondary)

            NavigationLink {
                DiagnosticsView()
            } label: {
                HStack {
                    Label("Диагностика: лог HTTP и тест SAP", systemImage: "stethoscope")
                    Spacer()
                    if !logger.entries.isEmpty {
                        Text("\(logger.entries.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Движок и диагностика")
        }
    }

    private var signInSection: some View {
        Section {
            TextField("Apple ID (Email)", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: email) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let pending = manager.pendingTwoFactorEmail?.lowercased(),
                       pending != trimmed {
                        manager.resetTwoFactorSession()
                    }
                }

            SecureField("Пароль", text: $password)
                .textContentType(.password)

            Picker("Регион Storefront", selection: $selectedCountry) {
                ForEach(StorefrontRegion.all) { region in
                    Text(region.name).tag(region.code)
                }
            }

            if manager.requiresTwoFactor || !authCode.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("6-значный код 2FA", text: $authCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)

                    HStack {
                        Text("Сессия FairPlay SAP активна — введите код")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Сбросить 2FA") {
                            authCode = ""
                            manager.resetTwoFactorSession()
                        }
                        .font(.caption2)
                    }
                }
            }

            if let error = manager.authErrorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(manager.requiresTwoFactor ? .orange : .red)
                }
            }

            Button {
                Task {
                    let success = await manager.signIn(
                        email: email,
                        password: password,
                        authCode: authCode.isEmpty ? nil : authCode,
                        countryCode: selectedCountry
                    )
                    if success {
                        password = ""
                        authCode = ""
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    if manager.isAuthenticating {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text(manager.requiresTwoFactor ? "Проверка 2FA…" : "SAP + Авторизация…")
                    } else {
                        Text(manager.requiresTwoFactor ? "Подтвердить 2FA и войти" : "Войти в Apple ID")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(email.isEmpty || password.isEmpty || manager.isAuthenticating)
        } header: {
            Text("Добавить Apple ID")
        } footer: {
            Text("Device GUID (\(manager.deviceGUID)), токены и куки сессии хранятся локально в зашифрованном iOS Keychain. Пароль на диске не сохраняется.")
        }
    }

    private var savedAccountsSection: some View {
        Section("Сохранённые аккаунты (\(manager.accounts.count))") {
            if manager.accounts.isEmpty {
                Text("Нет сохранённых аккаунтов.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.accounts) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(account.email)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if manager.activeAccount?.id == account.id {
                                Text("Активный")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.green)
                            } else {
                                Button("Выбрать") {
                                    manager.selectedAccountId = account.id
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }

                        HStack(spacing: 6) {
                            Text("DSID: \(account.dsid)")
                            Text("·")
                            Text("Pod: \(account.pod)")
                            Text("·")
                            Text("Cookies: \(account.cookies.count)")
                        }
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)

                        Text("Движок входа: \(account.engineUsed.shortName) · GUID: \(account.guid)")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)

                        Picker("Регион", selection: Binding(
                            get: { account.countryCode },
                            set: { manager.updateAccountRegion(account, newCountryCode: $0) }
                        )) {
                            ForEach(StorefrontRegion.all) { region in
                                Text(region.name).tag(region.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    for idx in offsets {
                        manager.removeAccount(manager.accounts[idx])
                    }
                }
            }
        }
    }
}
