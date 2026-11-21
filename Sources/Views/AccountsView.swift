import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var manager: AppStoreManager

    @State private var email = ""
    @State private var password = ""
    @State private var authCode = ""
    @State private var selectedCountry = "RU"

    var body: some View {
        NavigationStack {
            Form {
                signInSection
                savedAccountsSection
            }
            .navigationTitle("Аккаунты Apple ID")
        }
    }

    private var signInSection: some View {
        Section {
            TextField("Apple ID (Email)", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Пароль", text: $password)
                .textContentType(.password)

            Picker("Регион Storefront", selection: $selectedCountry) {
                ForEach(StorefrontRegion.all) { region in
                    Text(region.name).tag(region.code)
                }
            }

            if manager.requiresTwoFactor || !authCode.isEmpty {
                TextField("6-значный код 2FA", text: $authCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
            }

            if let error = manager.authErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(manager.requiresTwoFactor ? .orange : .red)
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
                        Text("Авторизация…")
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
            Text("Токен сессии и DSID хранятся локально в зашифрованном iOS Keychain. Пароль на диске не сохраняется.")
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

                        HStack(spacing: 8) {
                            Text("DSID: \(account.dsid)")
                            Text("·")
                            Text("Pod: \(account.pod)")
                            Text("·")
                            Text("GUID: \(account.guid)")
                        }
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
