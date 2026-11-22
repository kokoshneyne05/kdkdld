import SwiftUI
import UIKit

struct AccountAnisetteView: View {
    @EnvironmentObject var controller: VaultController
    @State private var showPassword: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - SideStore Anisette Section
                Section(
                    header: Text("SideStore Anisette серверы"),
                    footer: Text("Серверы берутся из официального репозитория SideStore/anisette-servers с авто-переключением (failover) при недоступности. Заголовки X-Apple-AMD / X-Apple-AMD-M / X-MMe-Client-Info прикрепляются вместе с нативной подписью FairPlay SAP.")
                ) {
                    Toggle("SideStore Anisette + FairPlay SAP", isOn: $controller.useSideStoreAnisette)

                    Picker("Сервер Anisette", selection: $controller.selectedAnisetteURL) {
                        ForEach(controller.anisetteServers) { server in
                            Text(server.name).tag(server.address)
                        }
                    }

                    TextField("Свой URL Anisette (https://… необязательно)", text: $controller.customAnisetteURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    HStack {
                        Button {
                            controller.testSideStoreAnisette()
                        } label: {
                            HStack {
                                Image(systemName: "bolt.shield.fill")
                                Text("Проверить Anisette сервер")
                            }
                        }
                        .disabled(controller.isTestingAnisette)

                        Spacer()

                        if controller.isTestingAnisette {
                            ProgressView()
                        }
                    }

                    Button {
                        Task { await controller.refreshAnisetteServers() }
                    } label: {
                        Label("Обновить список SideStore (GitHub)", systemImage: "arrow.triangle.2.circlepath")
                    }

                    LabeledContent("Статус Anisette", value: controller.anisetteStatusText)
                        .font(.caption)
                }

                // MARK: - Apple ID Login Section
                Section(
                    header: Text("Вход в Apple ID"),
                    footer: Text("Токен сессии, DSID и kbsync сохраняются только в зашифрованном iOS Keychain. Пароль не записывается на диск.")
                ) {
                    if controller.isAuthenticated, let account = controller.activeAccount {
                        LabeledContent("Apple ID", value: account.email)
                        LabeledContent("Storefront", value: account.storefront)
                        if let pod = account.pod, !pod.isEmpty {
                            LabeledContent("Store Pod", value: "p\(pod)")
                        }
                        Button("Выйти из аккаунта", role: .destructive) {
                            controller.signOut()
                        }
                    } else {
                        TextField("Apple ID (email)", text: $controller.appleId)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .disabled(controller.requires2FA || controller.isAuthenticating)

                        HStack {
                            if showPassword {
                                TextField("Пароль", text: $controller.password)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            } else {
                                SecureField("Пароль", text: $controller.password)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .disabled(controller.requires2FA || controller.isAuthenticating)

                        if controller.requires2FA {
                            TextField("6-значный код 2FA", text: $controller.twoFactorCode)
                                .keyboardType(.numberPad)
                                .autocorrectionDisabled()
                        }

                        if !controller.authErrorText.isEmpty {
                            Text(controller.authErrorText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        Button {
                            controller.signIn()
                        } label: {
                            HStack {
                                Image(systemName: controller.requires2FA ? "checkmark.shield.fill" : "key.fill")
                                Text(controller.requires2FA ? "Подтвердить код 2FA и войти" : "Войти в Apple ID")
                                Spacer()
                                if controller.isAuthenticating {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(
                            controller.isAuthenticating
                            || controller.appleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || controller.password.isEmpty
                            || (controller.requires2FA && controller.twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        )

                        if controller.requires2FA {
                            Button("Сбросить 2FA и начать заново", role: .destructive) {
                                controller.resetTwoFactor()
                            }
                        }
                    }

                    LabeledContent("Статус входа", value: controller.authStatusText)
                        .font(.caption)
                }

                // MARK: - Live Redacted Diagnostic Logs
                Section(header: Text("Журнал диагностики (\(controller.logs.count))")) {
                    if controller.logs.isEmpty {
                        Text("Событий пока нет.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button {
                                UIPasteboard.general.string = controller.formattedLogsText
                            } label: {
                                Label("Копировать лог", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            Spacer()
                            Button("Очистить", role: .destructive) {
                                controller.logs.removeAll()
                            }
                            .font(.caption)
                        }

                        ForEach(controller.logs.prefix(40)) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("[\(entry.formattedTime)] \(entry.category)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(entry.level.rawValue)
                                        .font(.caption2.monospaced().bold())
                                        .foregroundStyle(colorForLevel(entry.level))
                                }
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Аккаунт и Anisette")
        }
    }

    private func colorForLevel(_ level: VaultLogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
