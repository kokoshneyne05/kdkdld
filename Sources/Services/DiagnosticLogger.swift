import ApplePackage
import Foundation
import Logging

@MainActor
final class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()

    @Published private(set) var entries: [DiagnosticEntry] = []

    private let maxEntries = 250
    private var isBootstrapped = false

    private init() {}

    func bootstrapApplePackageLogging() {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        APLogger.verbose = true
        APLogger.logger = Logger(label: "com.ipavault.applepackage") { label in
            ApplePackageDiagnosticHandler(label: label)
        }
    }

    func log(
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        engine: String,
        httpStatus: Int? = nil,
        message: String,
        details: String? = nil
    ) {
        let entry = DiagnosticEntry(
            category: category,
            level: level,
            engine: engine,
            httpStatus: httpStatus,
            message: Self.redact(message),
            details: details.map { Self.redact($0) }
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    nonisolated func logAsync(
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        engine: String,
        httpStatus: Int? = nil,
        message: String,
        details: String? = nil
    ) {
        Task { @MainActor in
            self.log(
                category: category,
                level: level,
                engine: engine,
                httpStatus: httpStatus,
                message: message,
                details: details
            )
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportText(deviceGUID: String, activeEngine: AuthEngineMode) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = [
            "IPAVault Diagnostics Log",
            "Engine: \(activeEngine.title)",
            "Device GUID: \(deviceGUID)",
            "Entries: \(entries.count)",
            "----------------------------------------"
        ]
        for entry in entries.reversed() {
            let statusPart = entry.httpStatus.map { " [HTTP \($0)]" } ?? ""
            lines.append("[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] [\(entry.category.rawValue)] [\(entry.engine)]\(statusPart) \(entry.message)")
            if let details = entry.details, !details.isEmpty {
                lines.append("    \(details.replacingOccurrences(of: "\n", with: "\n    "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func redact(_ raw: String) -> String {
        var result = raw
        let patterns = [
            #"(<key>password</key>\s*<string>)[^<]+(</string>)"#,
            #"(<key>passwordToken</key>\s*<string>)[^<]+(</string>)"#,
            #"(X-Token:\s*)[^\s\n]+"#,
            #"(X-Apple-ActionSignature:\s*)[^\s\n]+"#,
            #"(Cookie:\s*)[^\n]+"#,
            #"(Set-Cookie:\s*)[^\n]+"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                if pattern.contains("password") {
                    result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1<redacted>$2")
                } else {
                    result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1<redacted>")
                }
            }
        }
        return result
    }
}

/// Bridges ApplePackage's swift-log APLogger events directly into the in-app DiagnosticLogger.
private struct ApplePackageDiagnosticHandler: LogHandler {
    let label: String
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let text = message.description
        let mappedLevel: DiagnosticLevel
        switch level {
        case .error, .critical:
            mappedLevel = .error
        case .warning:
            mappedLevel = .warning
        case .info, .notice:
            mappedLevel = .info
        default:
            mappedLevel = .info
        }

        let lower = text.lowercased()
        let category: DiagnosticCategory
        if lower.contains("bag") {
            category = .bag
        } else if lower.contains("sap") || lower.contains("setupcert") || lower.contains("fpinit") {
            category = .sap
        } else if lower.contains("auth") || lower.contains("signin") || lower.contains("authenticate") {
            category = .auth
        } else if lower.contains("download") || lower.contains("redownload") || lower.contains("updateproduct") || lower.contains("volumestore") {
            category = .download
        } else {
            category = .system
        }

        var parsedStatus: Int? = nil
        if text.hasPrefix("<<< ") {
            let parts = text.dropFirst(4).split(separator: " ")
            if let first = parts.first, let code = Int(first) {
                parsedStatus = code
            }
        }

        let lines = text.components(separatedBy: .newlines)
        let headline = lines.first ?? text
        let extra = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : nil

        DiagnosticLogger.shared.logAsync(
            category: category,
            level: mappedLevel,
            engine: "ApplePackage",
            httpStatus: parsedStatus,
            message: headline,
            details: extra
        )
    }
}
