import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject private var manager: AppStoreManager
    @ObservedObject private var logger = DiagnosticLogger.shared

    @State private var selectedCategory: DiagnosticCategory = .all
    @State private var onlyErrors = false
    @State private var copiedNotice = false

    private var filteredEntries: [DiagnosticEntry] {
        logger.entries.filter { entry in
            if onlyErrors && entry.level != .error && entry.level != .warning {
                return false
            }
            if selectedCategory != .all && entry.category != selectedCategory {
                return false
            }
            return true
        }
    }

    var body: some View {
        List {
            environmentSection
            selfTestSection
            logFilterSection
            logEntriesSection
        }
        .navigationTitle("Диагностика SAP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    let text = logger.exportText(
                        deviceGUID: manager.deviceGUID,
                        activeEngine: manager.selectedEngine
                    )
                    UIPasteboard.general.string = text
                    copiedNotice = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedNotice = false
                    }
                } label: {
                    Image(systemName: copiedNotice ? "checkmark" : "doc.on.doc")
                }
                .disabled(logger.entries.isEmpty)

                Button(role: .destructive) {
                    logger.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(logger.entries.isEmpty)
            }
        }
    }

    private var environmentSection: some View {
        Section("Сетевой профиль") {
            LabeledContent("Движок", value: manager.selectedEngine.shortName)
            LabeledContent("Device GUID") {
                Text(manager.deviceGUID)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            if let acc = manager.activeAccount {
                LabeledContent("Активный Pod", value: "p\(acc.pod)")
                LabeledContent("Сохранённые Cookies", value: "\(acc.cookies.count)")
            }
        }
    }

    private var selfTestSection: some View {
        Section {
            Button {
                Task { await manager.runSelfTest() }
            } label: {
                HStack {
                    if manager.isRunningSelfTest {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text("Проверка Bag + FairPlay SAP…")
                    } else {
                        Label("Проверить Bag + SAP рукопожатие", systemImage: "waveform.path.ecg")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(manager.isRunningSelfTest)

            if let report = manager.selfTestReport {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bag (init.itunes.apple.com)")
                            .font(.subheadline)
                        Spacer()
                        Text(report.bagSuccess ? "OK · \(report.bagLatencyMs) мс" : "Ошибка")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundColor(report.bagSuccess ? .green : .red)
                    }

                    Text(report.authEndpoint)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    Divider()

                    HStack {
                        Text("FairPlay SAP (setupCert + fpinit)")
                            .font(.subheadline)
                        Spacer()
                        Text(report.sapSuccess ? "OK · \(report.sapLatencyMs) мс" : "Ошибка")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundColor(report.sapSuccess ? .green : .red)
                    }

                    if report.sapSuccess {
                        Text("Подпись X-Apple-ActionSignature: \(report.sapSignatureBytes) байт")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }

                    if let err = report.errorSummary {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Живой тест соединения (без пароля)")
        } footer: {
            Text("Проверяет доступность bag.xml и прохождение криптографического рукопожатия FairPlay SAP из текущей сети или VPN.")
        }
    }

    private var logFilterSection: some View {
        Section {
            Picker("Категория", selection: $selectedCategory) {
                ForEach(DiagnosticCategory.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Только ошибки и предупреждения", isOn: $onlyErrors)
                .font(.subheadline)

            if copiedNotice {
                Text("Лог скопирован в буфер обмена (пароли и токены скрыты).")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        } header: {
            Text("Журнал запросов (\(filteredEntries.count))")
        }
    }

    private var logEntriesSection: some View {
        Section {
            if filteredEntries.isEmpty {
                Text("Записей по выбранному фильтру пока нет. Нажмите «Проверить Bag + SAP» или выполните вход.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(entry.level.rawValue)
                                .font(.caption2.monospaced().weight(.bold))
                                .foregroundColor(levelColor(entry.level))
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(entry.category.rawValue)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(entry.engine)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                            if let status = entry.httpStatus {
                                Text("· HTTP \(status)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundColor((200...399).contains(status) ? .green : .red)
                            }
                            Spacer()
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }

                        Text(entry.message)
                            .font(.footnote)
                            .foregroundColor(.primary)

                        if let details = entry.details, !details.isEmpty {
                            Text(details)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func levelColor(_ level: DiagnosticLevel) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
