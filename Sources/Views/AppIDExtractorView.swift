import SwiftUI

struct AppIDExtractorView: View {
    @EnvironmentObject private var manager: AppStoreManager
    @Binding var selectedTab: MainTab
    @State private var showAllVersions = false

    var body: some View {
        NavigationStack {
            Form {
                activeAccountSection
                inputSection
                statusSection
                if let info = manager.inspectedInfo {
                    inspectedAppSection(info)
                }
            }
            .navigationTitle("Извлечь по ID")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let account = manager.activeAccount {
                        Menu {
                            ForEach(manager.accounts) { acc in
                                Button {
                                    manager.selectedAccountId = acc.id
                                } label: {
                                    HStack {
                                        Text("\(acc.email) (\(acc.countryCode))")
                                        if acc.id == account.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(account.countryCode)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var activeAccountSection: some View {
        Section {
            if let account = manager.activeAccount {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("\(account.email) · Регион \(account.countryCode) · Pod \(account.pod)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Сменить") {
                        selectedTab = .accounts
                    }
                    .font(.caption.weight(.medium))
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Нет активного Apple ID")
                            .font(.subheadline.weight(.semibold))
                        Text("Войдите в аккаунт для доступа к серверам Apple")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Войти") {
                        selectedTab = .accounts
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Активный аккаунт")
        }
    }

    private var inputSection: some View {
        Section {
            TextField("App ID / adamId (например, 310633997)", text: $manager.inputAdamId)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("ID версии (опционально, externalVersionId)", text: $manager.inputVersionId)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack(spacing: 12) {
                Button {
                    Task { await manager.inspectByAppID() }
                } label: {
                    Label("Проверить ID", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(manager.activeAccount == nil || isBusy)

                Button {
                    Task { await manager.startDownload() }
                } label: {
                    Label("Скачать IPA", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.activeAccount == nil || isBusy)
            }
            .padding(.vertical, 4)

            Button {
                Task { await manager.claimLicenseForCurrentID() }
            } label: {
                Label("Получить бесплатную лицензию (если ошибка 9610)", systemImage: "checkmark.seal")
                    .font(.footnote)
            }
            .disabled(manager.activeAccount == nil || manager.inputAdamId.isEmpty || isBusy)
        } header: {
            Text("Прямая выгрузка (включая удалённые)")
        } footer: {
            Text("Запрос идёт напрямую к volumeStoreDownloadProduct. Работает с удалёнными из App Store приложениями, если они ранее были куплены/скачаны на выбранный Apple ID.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch manager.downloadState {
        case .idle:
            if let banner = manager.statusBanner {
                Section {
                    Text(banner)
                        .font(.footnote)
                        .foregroundColor(.green)
                }
            }
        case .inspecting:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Запрос метаданных и списка версий с сервера Apple…")
                        .font(.subheadline)
                }
            }
        case .downloading(let progress, let received, let total):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Загрузка пакета…")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.subheadline.monospacedDigit())
                    }
                    ProgressView(value: progress)
                    HStack {
                        Text("\(formatBytes(received)) / \(total > 0 ? formatBytes(total) : "—")")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Отмена", role: .destructive) {
                            manager.cancelDownload()
                        }
                        .font(.caption.weight(.medium))
                    }
                }
                .padding(.vertical, 4)
            }
        case .patching:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Инжект iTunesMetadata.plist и FairPlay SINF в IPA…")
                        .font(.subheadline)
                }
            }
        case .finished(let file):
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("IPA успешно собран", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.subheadline.weight(.semibold))
                    Text("\(file.fileName) (\(file.formattedSize))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        ShareLink(item: file.url) {
                            Label("Поделиться / TrollStore", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("В библиотеку") {
                            selectedTab = .library
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        case .failed(let message):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ошибка", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.primary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func inspectedAppSection(_ info: AppDownloadInfo) -> some View {
        Section {
            HStack(spacing: 12) {
                if let urlStr = info.artworkUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "app.dashed")
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name)
                        .font(.headline)
                    Text(info.bundleId)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    Text("Версия \(info.shortVersion) (\(info.bundleVersion)) · SINF: \(info.sinfs.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Текущий External Version ID")
                    .font(.footnote)
                Spacer()
                Text(info.externalVersionId)
                    .font(.footnote.monospaced())
                    .foregroundColor(.secondary)
            }

            if !info.availableVersionIds.isEmpty {
                DisclosureGroup("Доступные версии в истории (\(info.availableVersionIds.count))", isExpanded: $showAllVersions) {
                    ForEach(info.availableVersionIds, id: \.self) { verId in
                        HStack {
                            Text(verId)
                                .font(.footnote.monospaced())
                            Spacer()
                            Button("Выбрать") {
                                manager.inputVersionId = verId
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("Скачать") {
                                manager.inputVersionId = verId
                                Task { await manager.startDownload(externalVersionOverride: verId) }
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .disabled(isBusy)
                        }
                    }
                }
            }
        } header: {
            Text("Найденный пакет")
        }
    }

    private var isBusy: Bool {
        switch manager.downloadState {
        case .inspecting, .downloading, .patching:
            return true
        default:
            return false
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
