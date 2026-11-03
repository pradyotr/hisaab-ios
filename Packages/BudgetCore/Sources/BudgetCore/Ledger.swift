import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Lock screen shows percentages only.
    public var hideValues: Bool

    public init(hideValues: Bool = false) {
        self.hideValues = hideValues
    }
}

public struct LogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var message: String
    public var rawText: String?

    public init(id: UUID = UUID(), date: Date = Date(), message: String, rawText: String? = nil) {
        self.id = id
        self.date = date
        self.message = message
        self.rawText = rawText
    }
}

/// All app data. Stored as one JSON file in the App Group container, shared by the app, the App Intent and the widget.
public struct Ledger: Codable, Equatable, Sendable {
    public static let maxLogEntries = 200

    public var config: BudgetConfig?
    /// Newest first.
    public var transactions: [Transaction]
    public var settings: AppSettings
    /// Newest first. Debug log for the parser and storage, shown in Settings > Debug log.
    public var log: [LogEntry]

    public init(config: BudgetConfig? = nil, transactions: [Transaction] = [], settings: AppSettings = AppSettings(), log: [LogEntry] = []) {
        self.config = config
        self.transactions = transactions
        self.settings = settings
        self.log = log
    }

    // Tolerant decoding: new fields must not make old files unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decodeIfPresent(BudgetConfig.self, forKey: .config)
        transactions = try c.decodeIfPresent([Transaction].self, forKey: .transactions) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        log = try c.decodeIfPresent([LogEntry].self, forKey: .log) ?? []
    }

    /// Adds a transaction. Returns false if it is a duplicate SMS (same text within `dedupeWindow` seconds).
    @discardableResult
    public mutating func add(_ transaction: Transaction, dedupeWindow: TimeInterval = 600) -> Bool {
        if transaction.source == .sms, let raw = transaction.rawText {
            let isDuplicate = transactions.contains {
                $0.rawText == raw && abs($0.date.timeIntervalSince(transaction.date)) < dedupeWindow
            }
            if isDuplicate { return false }
        }
        transactions.append(transaction)
        transactions.sort { $0.date > $1.date }
        return true
    }

    public mutating func update(_ transaction: Transaction) {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        transactions[index] = transaction
        transactions.sort { $0.date > $1.date }
    }

    public mutating func remove(ids: Set<UUID>) {
        transactions.removeAll { ids.contains($0.id) }
    }

    public mutating func appendLog(_ message: String, rawText: String? = nil, at date: Date = Date()) {
        log.insert(LogEntry(date: date, message: message, rawText: rawText), at: 0)
        if log.count > Self.maxLogEntries { log.removeLast(log.count - Self.maxLogEntries) }
    }
}

/// Reads and writes the ledger JSON file. Writes are atomic.
public struct LedgerStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Returns an empty ledger if the file does not exist.
    /// If the file exists but cannot be decoded, it is moved aside (never silently overwritten).
    public func load() -> Ledger {
        guard let data = try? Data(contentsOf: url) else { return Ledger() }
        do {
            return try JSONDecoder().decode(Ledger.self, from: data)
        } catch {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            var ledger = Ledger()
            ledger.appendLog("Ledger file unreadable, moved to \(backup.lastPathComponent): \(error)")
            return ledger
        }
    }

    public func save(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }

    /// Load, change, save. Always re-reads first, because another process (widget / App Intent) may have written.
    @discardableResult
    public func update(_ body: (inout Ledger) -> Void) throws -> Ledger {
        var ledger = load()
        body(&ledger)
        try save(ledger)
        return ledger
    }
}
