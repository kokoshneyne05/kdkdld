import SwiftUI

struct DownloadsLibraryView: View {
    @EnvironmentObject var controller: VaultController

    var body: some View {
        NavigationStack {
            List {
                if controller.downloads.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Нет сохранённых IPA")
                                .font(.headline)
                            Text("Все скачанные приложения (включая FairPlay-зашифрованные удалённые сборки с инжектированным SINF) сохраняются в Documents/Downloads и также видны в стандартном приложении «Файлы» → На iPhone → IPAVault.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section(header: Text("Сохранённые IPA (\(controller.downloads.count))")) {
                        ForEach(controller.downloads) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(record.appName)
                                        .font(.headline)
                                    Spacer()
                                    Text(record.formattedSize)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(record.bundleID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("v\(record.version) • extID: \(record.externalVersionID) • ID: \(record.appID)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    ShareLink(item: record.fileURL) {
                                        Label("Экспорт IPA", systemImage: "square.and.arrow.up")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Spacer()

                                    Button(role: .destructive) {
                                        controller.deleteRecord(record)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.top, 4)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Файлы IPA")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controller.downloads = DownloadRecord.loadAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
