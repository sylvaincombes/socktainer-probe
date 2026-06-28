import Foundation

public struct HistoryEntry: Identifiable, Hashable {
    public var id: String { report.runId }
    public let report: RunReport
    public let kind: SessionRecord.Kind
    public let fileURL: URL   // needed for deletion

    public static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct SessionRecord: Codable {
    public enum Kind: String, Codable, CaseIterable {
        case integration, parity, compose, coverage, config
    }
    public let id: String
    public let timestamp: Date
    public let kind: Kind
    public let summary: String
    public let reportPath: String?

    public init(id: String, timestamp: Date, kind: Kind, summary: String, reportPath: String?) {
        self.id = id; self.timestamp = timestamp; self.kind = kind
        self.summary = summary; self.reportPath = reportPath
    }
}

public actor Sessions {
    public static let shared = Sessions()

    private let dir: URL

    private init() {
        dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func save(_ record: SessionRecord) throws {
        let fileName = "\(formatTimestamp(record.timestamp))-\(record.kind.rawValue).json"
        let path = dir.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: path)
    }

    public func saveReport(_ report: RunReport, kind: SessionRecord.Kind = .integration) throws -> URL {
        let fileName = "\(isoNow())-\(kind.rawValue).json"
        let path = dir.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: path)
        return path
    }

    public func last(kind: SessionRecord.Kind) -> SessionRecord? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.lastPathComponent.hasSuffix("-\(kind.rawValue).json") }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .first
    }

    public func sessionsDir() -> URL { dir }

    public func delete(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
    }

    public func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil) else { return }
        let kinds = SessionRecord.Kind.allCases.filter { $0 != .config }
        for file in files where kinds.contains(where: { file.lastPathComponent.hasSuffix("-\($0.rawValue).json") }) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Returns the N most recent run reports across all suite kinds.
    public func loadRecentReports(limit: Int = 50) -> [HistoryEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        let kinds = SessionRecord.Kind.allCases.filter { $0 != .config }
        return files
            .filter { f in kinds.contains { f.lastPathComponent.hasSuffix("-\($0.rawValue).json") } }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { url -> HistoryEntry? in
                guard let report = try? decoder.decode(RunReport.self, from: Data(contentsOf: url))
                else { return nil }
                let kind = kinds.first { url.lastPathComponent.hasSuffix("-\($0.rawValue).json") }
                    ?? .integration
                return HistoryEntry(report: report, kind: kind, fileURL: url)
            }
    }

    /// Most recent report of any kind.
    public func loadLatestReport() -> HistoryEntry? {
        loadRecentReports(limit: 1).first
    }

    /// Returns the most recent integration run report, if any.
    public func loadLastReport() -> RunReport? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let decoder = JSONDecoder()
        return files
            .filter { $0.lastPathComponent.hasSuffix("-integration.json") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst()  // skip the one we just saved
            .compactMap { try? decoder.decode(RunReport.self, from: Data(contentsOf: $0)) }
            .first
    }

    private func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    private func isoNow() -> String { formatTimestamp(Date()) }
}
