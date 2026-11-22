import SwiftUI

struct CatalogSearchView: View {
    @EnvironmentObject var controller: VaultController

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Название приложения или Bundle ID…", text: $controller.searchQuery)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                controller.searchCatalog()
                            }
                            .onChange(of: controller.searchQuery) { _ in
                                controller.searchCatalog()
                            }
                        if !controller.searchQuery.isEmpty {
                            Button {
                                controller.searchQuery = ""
                                controller.searchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if controller.isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Поиск в App Store…")
                            Spacer()
                        }
                    }
                } else if controller.searchResults.isEmpty {
                    Section {
                        Text(controller.searchQuery.isEmpty ? "Введите название для поиска в публичном каталоге App Store. Удалённые приложения ищите по числовому App ID на первой вкладке." : "Ничего не найдено.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section(header: Text("Результаты (\(controller.searchResults.count))")) {
                        ForEach(controller.searchResults) { item in
                            Button {
                                controller.selectFromSearch(item)
                            } label: {
                                HStack(spacing: 12) {
                                    if let art = item.artworkUrl100, let url = URL(string: art) {
                                        AsyncImage(url: url) { image in
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } placeholder: {
                                            Color.secondary.opacity(0.2)
                                        }
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.trackName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(item.bundleId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text("ID: \(item.trackId) • \(item.artistName)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(.blue)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Поиск App Store")
        }
    }
}
