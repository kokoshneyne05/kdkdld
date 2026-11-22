import SwiftUI

struct DeletedExtractorView: View {
    @EnvironmentObject var controller: VaultController
    @State private var versionFilter: String = ""

    private var filteredVersions: [String] {
        guard let bundle = controller.resolvedApp else { return [] }
        let q = versionFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return bundle.versions }
        return bundle.versions.filter { $0.contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !controller.isAuthenticated {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Требуется вход в Apple ID", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("Войдите в Apple ID на вкладке «Аккаунт» (поддерживаются SideStore Anisette серверы и FairPlay SAP), чтобы находить и выгружать удалённые приложения из истории покупок.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Перейти к входу") {
                                controller.selectedTab = 3
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(
                    header: Text("Поиск по App ID (adamId)"),
                    footer: Text("Для удалённых приложений укажите числовой ID (например, 310633997) или ссылку App Store и нажмите «Найти удалённое по ID (без каталога)». Приложение обойдёт публичный поиск и пройдёт 4-ступенчатый каскад Apple.")
                ) {
                    HStack {
                        TextField("App ID (напр. 310633997) или ссылка", text: $controller.appInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !controller.appInput.isEmpty {
                            Button {
                                controller.appInput = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("External Version ID (необязательно)", text: $controller.manualVersionInput)
                            .keyboardType(.numberPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !controller.manualVersionInput.isEmpty {
                            Button {
                                controller.manualVersionInput = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        controller.inspectApp(forceDirectDeleted: true)
                    } label: {
                        HStack {
                            Image(systemName: "archivebox.fill")
                            Text("Найти удалённое по ID (без каталога)")
                            Spacer()
                            if controller.isInspecting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(controller.isInspecting || controller.isDownloading || controller.appInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        controller.inspectApp(forceDirectDeleted: false)
                    } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("Проверить в каталоге App Store")
                            Spacer()
                        }
                    }
                    .disabled(controller.isInspecting || controller.isDownloading || controller.appInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !controller.extractorStatusText.isEmpty || !controller.extractorErrorText.isEmpty {
                    Section(header: Text("Статус")) {
                        if !controller.extractorStatusText.isEmpty {
                            Text(controller.extractorStatusText)
                                .font(.subheadline)
                        }
                        if !controller.extractorErrorText.isEmpty {
                            Text(controller.extractorErrorText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if controller.isDownloading {
                    Section(header: Text("Загрузка IPA")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(controller.activeDownloadTitle)
                                .font(.headline)
                            ProgressView(value: controller.downloadProgress)
                            HStack {
                                Text(controller.downloadDetailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(controller.downloadProgress * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button("Отменить загрузку", role: .destructive) {
                                controller.cancelDownload()
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let completed = controller.lastCompletedRecord {
                    Section(header: Text("Последний собранный IPA")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(completed.appName)
                                .font(.headline)
                            Text("\(completed.bundleID) • v\(completed.version) • \(completed.formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ShareLink(item: completed.fileURL) {
                                Label("Экспортировать IPA", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let bundle = controller.resolvedApp {
                    Section(header: Text("Найденное приложение")) {
                        LabeledContent("Название", value: bundle.app.name)
                        LabeledContent("Bundle ID", value: bundle.app.bundleID)
                        LabeledContent("App ID", value: bundle.app.id)
                        LabeledContent("Режим", value: bundle.isDeletedDirect ? "Удалённое (Direct)" : "Каталог App Store")
                        LabeledContent("Доступно версий", value: "\(bundle.versions.count)")
                    }

                    Section(header: Text("Исторические версии (External Version ID)")) {
                        if bundle.versions.count > 8 {
                            TextField("Фильтр по номеру версии…", text: $versionFilter)
                                .keyboardType(.numberPad)
                        }
                        ForEach(filteredVersions, id: \.self) { versionID in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(versionID)
                                        .font(.system(.body, design: .monospaced))
                                    if versionID == bundle.latestDownload.externalVersionID {
                                        Text("Последняя доступная сборка")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                }
                                Spacer()
                                Button {
                                    controller.startDownload(bundle: bundle, versionID: versionID)
                                } label: {
                                    Label("Скачать", systemImage: "arrow.down.circle.fill")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.bordered)
                                .disabled(controller.isDownloading)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Удалённые IPA")
        }
    }
}
