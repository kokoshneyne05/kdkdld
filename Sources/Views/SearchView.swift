import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var manager: AppStoreManager
    @Binding var selectedTab: MainTab

    var body: some View {
        NavigationStack {
            List {
                if let error = manager.searchError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if manager.isSearching {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Поиск в App Store (\(manager.activeAccount?.countryCode ?? "RU"))…")
                                .font(.subheadline)
                        }
                    }
                } else if manager.searchResults.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Поиск в публичном каталоге App Store")
                                .font(.headline)
                            Text("Введите название, Bundle ID (например, com.vk.vkclient) или числовой App ID. Если приложение удалено из App Store, используйте вкладку «По App ID».")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section("Результаты (\(manager.searchResults.count))") {
                        ForEach(manager.searchResults) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    if let urlStr = item.artworkUrl100, let url = URL(string: urlStr) {
                                        AsyncImage(url: url) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Color.secondary.opacity(0.2)
                                        }
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.trackName)
                                            .font(.subheadline.weight(.semibold))
                                        Text("ID: \(item.adamIdString) · v\(item.version ?? "—") · \(item.formattedSize)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                        Text(item.bundleId)
                                            .font(.caption2.monospaced())
                                            .foregroundColor(.secondary)
                                    }
                                }

                                HStack(spacing: 8) {
                                    Button {
                                        manager.inputAdamId = item.adamIdString
                                        manager.inputVersionId = ""
                                        selectedTab = .extractor
                                        Task { await manager.inspectByAppID() }
                                    } label: {
                                        Label("Открыть по ID", systemImage: "arrow.down.doc")
                                            .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                    if (item.price ?? 0) == 0 {
                                        Button {
                                            Task { await manager.purchaseFromSearch(item) }
                                        } label: {
                                            Label("Взять лицензию", systemImage: "plus.circle")
                                                .font(.caption.weight(.medium))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Поиск в App Store")
            .searchable(text: $manager.searchQuery, prompt: "Название, Bundle ID или App ID")
            .onSubmit(of: .search) {
                Task { await manager.performSearch() }
            }
        }
    }
}
