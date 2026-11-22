import Foundation
import MapleSAP

struct ResolvedAppBundle: Identifiable {
    var id: String { app.id }
    let app: StoreApp
    let latestDownload: StoreDownload
    let isDeletedDirect: Bool

    var versions: [String] { latestDownload.availableVersionIDs }
}

struct DownloadRecord: Codable, Identifiable, Hashable {
    var id: String { filename }
    let filename: String
    let appID: String
    let appName: String
    let bundleID: String
    let version: String
    let build: String?
    let externalVersionID: String
    let date: Date
    let isDeletedDirect: Bool

    static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var fileURL: URL {
        Self.downloadsDirectory.appendingPathComponent(filename)
    }

    var sidecarURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("json")
    }

    var fileSizeBytes: Int64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    static func loadAll() -> [DownloadRecord] {
        let fm = FileManager.default
        let dir = downloadsDirectory
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var records: [DownloadRecord] = []
        let decoder = JSONDecoder()
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let record = try? decoder.decode(DownloadRecord.self, from: data),
               fm.fileExists(atPath: record.fileURL.path) {
                records.append(record)
            }
        }
        return records.sorted { $0.date > $1.date }
    }

    func deleteFiles() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        if fm.fileExists(atPath: sidecarURL.path) {
            try fm.removeItem(at: sidecarURL)
        }
    }
}

struct ITunesSearchResponse: Decodable {
    let results: [ITunesSearchItem]
}

struct ITunesSearchItem: Decodable, Identifiable {
    var id: Int { trackId }
    let trackId: Int
    let trackName: String
    let bundleId: String
    let artistName: String
    let version: String?
    let price: Double?
    let artworkUrl100: String?
}

struct VaultLogEntry: Identifiable {
    enum Level: String {
        case info = "INFO"
        case success = "OK"
        case warning = "WARN"
        case error = "ERR"
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let category: String
    let message: String

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

enum AppIDParser {
    static func extractNumericID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = StoreParsing.identifier(trimmed) {
            return direct
        }
        if trimmed.lowercased().hasPrefix("id"),
           let direct = StoreParsing.identifier(String(trimmed.dropFirst(2))) {
            return direct
        }
        if let regex = try? NSRegularExpression(
            pattern: #"(?:^|/|id)(\d{5,})(?:$|[/?#&])"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.matches(in: trimmed, range: range).last,
               match.numberOfRanges > 1,
               let numRange = Range(match.range(at: 1), in: trimmed) {
                return StoreParsing.identifier(String(trimmed[numRange]))
            }
        }
        return nil
    }
}
