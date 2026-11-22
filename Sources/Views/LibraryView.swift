import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var manager: AppStoreManager

    var body: some View {
        NavigationStack {
            List {
                if manager.savedIPAs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Скачанных IPA пока нет")
                                .font(.headline)
                            Text("Все собранные файлы сохраняются в «Файлы → На iPhone → IPAVault → IPAs» и готовы к передаче в TrollStore, SideStore или AltStore.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section("Сохранённые пакеты (\(manager.savedIPAs.count))") {
                        ForEach(manager.savedIPAs) { file in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.zipper")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.fileName)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    Text("\(file.formattedSize) · \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                ShareLink(item: file.url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                manager.deleteLocalIPA(manager.savedIPAs[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Файлы IPA")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        manager.refreshLibrary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                manager.refreshLibrary()
            }
        }
    }
}
