import Foundation

/// Reads and writes Hisaab's files. They sit in one folder (the App Group container), each with its own
/// iOS file protection class:
///
/// | File                 | Contents                                    | Protection                                   |
/// |----------------------|---------------------------------------------|----------------------------------------------|
/// | `ledger.json`        | everything                                  | Complete: unreadable while the iPhone is locked |
/// | `inbox/*.json`       | SMS received while the ledger was unreadable | Complete Unless Open: can be created while locked, read after unlock |
/// | `widget-digest.json` | what the budget widgets show (`WidgetDigest`) | Until First User Authentication             |
///
/// The Shortcuts automation can run while the iPhone is locked. It then can't read the ledger (`Unavailable`),
/// so it saves the SMS in the inbox and adds an estimate to the digest. The next `update` while unlocked
/// (app, App Intent or widget) moves the inbox into the ledger and rewrites the digest from it.
///
/// All writes are atomic. On Linux and Windows (tests) there is no file protection and no coordination.
public struct LedgerStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var inboxURL: URL { url.deletingLastPathComponent().appendingPathComponent("inbox", isDirectory: true) }
    public var digestURL: URL { url.deletingLastPathComponent().appendingPathComponent("widget-digest.json") }

    /// The ledger file exists but can't be read, normally because the iPhone is locked.
    /// Never treat this as "no data": saving would replace the real ledger.
    public struct Unavailable: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { "Hisaab's data can't be read while the iPhone is locked (\(reason))." }
    }

    // MARK: Ledger

    /// The ledger, or an empty one if the file does not exist or can't be read right now.
    /// For display only. To change data, use `update`, which never overwrites a ledger it could not read.
    public func load() -> Ledger {
        (try? loadAvailable()) ?? Ledger()
    }

    /// The ledger, or an empty one if the file does not exist. Throws `Unavailable` if it exists but can't be read.
    /// If it exists but can't be decoded, it is moved aside (never silently overwritten).
    public func loadAvailable() throws -> Ledger {
        do {
            return try coordinated(url, writing: false) { try rawLoad() }
        } catch let error as Unavailable {
            throw error
        } catch {
            return try rawLoad()
        }
    }

    /// Replaces the ledger. Prefer `update`.
    public func save(_ ledger: Ledger, now: Date = Date()) throws {
        try coordinated(url, writing: true) { try rawSave(ledger) }
        saveDigest(WidgetDigest(ledger: ledger, now: now))
    }

    /// Load, take in waiting SMS, change, save, as one coordinated write. Always re-reads first, because another
    /// process (widget / App Intent) may have written; the file coordinator makes it wait.
    /// Throws `Unavailable` without calling `body` when the ledger can't be read.
    @discardableResult
    public func update(now: Date = Date(), _ body: (inout Ledger) -> Void) throws -> Ledger {
        let ledger: Ledger = try coordinated(url, writing: true) {
            var ledger = try rawLoad()
            let pending = readInbox()
            for item in pending.items { ledger.logSMS(item.message, at: item.date) }
            body(&ledger)
            try rawSave(ledger)
            for file in pending.files { try? FileManager.default.removeItem(at: file) }
            return ledger
        }
        saveDigest(WidgetDigest(ledger: ledger, now: now))
        return ledger
    }

    /// Erases all data: the ledger, unreadable copies that `load()` moved aside, the inbox and the digest.
    /// The next `load()` returns an empty ledger.
    public func deleteAll() throws {
        let fileManager = FileManager.default
        try coordinated(url, writing: true, deleting: true) {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            let prefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
            let siblings = (try? fileManager.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                 includingPropertiesForKeys: nil)) ?? []
            for file in siblings where file.lastPathComponent.hasPrefix(prefix) {
                try fileManager.removeItem(at: file)
            }
            if fileManager.fileExists(atPath: inboxURL.path) { try fileManager.removeItem(at: inboxURL) }
        }
        try coordinated(digestURL, writing: true, deleting: true) {
            if fileManager.fileExists(atPath: digestURL.path) { try fileManager.removeItem(at: digestURL) }
        }
    }

    // MARK: Inbox (SMS received while locked)

    struct PendingSMS: Codable, Equatable {
        var date: Date
        var message: String
    }

    /// Saves an SMS for the next `update`. Works while the iPhone is locked.
    public func enqueue(_ message: String, at date: Date) throws {
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        let name = String(format: "%015.0f", date.timeIntervalSince1970 * 1000) + "-\(UUID().uuidString).json"
        let data = try JSONEncoder().encode(PendingSMS(date: date, message: message))
        try data.write(to: inboxURL.appendingPathComponent(name), options: Self.inboxWriteOptions)
    }

    /// True if SMS are waiting in the inbox. Works while locked (it only lists the folder).
    public var hasPendingSMS: Bool { !inboxFiles().isEmpty }

    private func inboxFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Readable inbox items, oldest first, and the files to delete once the ledger is saved.
    /// A file that can't be read yet stays. A file that can't be decoded is dropped.
    private func readInbox() -> (items: [PendingSMS], files: [URL]) {
        var items: [PendingSMS] = []
        var files: [URL] = []
        for file in inboxFiles() {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let item = try? JSONDecoder().decode(PendingSMS.self, from: data) { items.append(item) }
            files.append(file)
        }
        return (items.sorted { $0.date < $1.date }, files)
    }

    // MARK: Widget digest

    /// The digest, or nil if it doesn't exist or can't be read (before the first unlock after a restart).
    public func loadDigest() -> WidgetDigest? {
        let read = { () -> WidgetDigest? in
            guard let data = try? Data(contentsOf: digestURL) else { return nil }
            return try? JSONDecoder().decode(WidgetDigest.self, from: data)
        }
        return (try? coordinated(digestURL, writing: false, read)) ?? read()
    }

    /// Changes the digest only: for an SMS received while the ledger can't be read.
    /// Throws `Unavailable` if there is no readable digest.
    public func updateDigest(_ body: (inout WidgetDigest) -> Void) throws {
        try coordinated(digestURL, writing: true) {
            guard let data = try? Data(contentsOf: digestURL),
                  var digest = try? JSONDecoder().decode(WidgetDigest.self, from: data) else {
                throw Unavailable(reason: "no widget digest")
            }
            body(&digest)
            try writeDigest(digest)
        }
    }

    /// Best effort: the widgets fall back to the ledger when the digest is missing.
    private func saveDigest(_ digest: WidgetDigest) {
        try? coordinated(digestURL, writing: true) { try writeDigest(digest) }
    }

    private func writeDigest(_ digest: WidgetDigest) throws {
        try JSONEncoder().encode(digest).write(to: digestURL, options: Self.digestWriteOptions)
    }

    // MARK: Private. Never nest `coordinated` calls on the same file.

    #if canImport(Darwin)
    private static let ledgerWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    private static let inboxWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
    private static let digestWriteOptions: Data.WritingOptions =
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    /// NSFileCoordinator serialises access across the app, the App Intent and the widget processes.
    private func coordinated<T>(_ file: URL, writing: Bool, deleting: Bool = false,
                                _ body: () throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: file, options: deleting ? .forDeleting : .forMerging,
                                   error: &coordinationError) { _ in
                result = Result(catching: { try body() })
            }
        } else {
            coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) { _ in
                result = Result(catching: { try body() })
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    #else
    private static let ledgerWriteOptions: Data.WritingOptions = [.atomic]
    private static let inboxWriteOptions: Data.WritingOptions = [.atomic]
    private static let digestWriteOptions: Data.WritingOptions = [.atomic]

    /// Linux / Windows (tests only): one process, nothing to coordinate.
    private func coordinated<T>(_ file: URL, writing: Bool, deleting: Bool = false,
                                _ body: () throws -> T) throws -> T {
        try body()
    }
    #endif

    private func rawLoad() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Unavailable(reason: error.localizedDescription)
        }
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

    private func rawSave(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: url, options: Self.ledgerWriteOptions)
    }
}
