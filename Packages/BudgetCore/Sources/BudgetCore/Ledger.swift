import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Lock screen shows percentages only.
    public var hideValues: Bool
    /// Last 4 digits of the user's credit cards. SMS that mention one of these are treated as card spends / bills,
    /// even when the SMS only says "Card XX1234".
    public var creditCards: [String]
    /// Extra words that mark a debit as savings (an investment), on top of the built-in list
    /// in `SMSParser.savingsPatterns`. Matched case-insensitively anywhere in the SMS, e.g. "mybroker".
    public var savingsKeywords: [String]

    public init(hideValues: Bool = false, creditCards: [String] = [], savingsKeywords: [String] = []) {
        self.hideValues = hideValues
        self.creditCards = creditCards
        self.savingsKeywords = savingsKeywords
    }

    private enum CodingKeys: String, CodingKey { case hideValues, creditCards, savingsKeywords }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideValues = try c.decodeIfPresent(Bool.self, forKey: .hideValues) ?? false
        creditCards = try c.decodeIfPresent([String].self, forKey: .creditCards) ?? []
        savingsKeywords = try c.decodeIfPresent([String].self, forKey: .savingsKeywords) ?? []
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
    /// Bump when the stored shape changes, and add the upgrade step in `migrate()`.
    /// 0 = files written before versioning (spends only). 1 = entries with kind / account / ref / reverses / excluded.
    /// 2 = user categories, and per-field sources on entries.
    /// 3 = the category prediction on entries.
    /// 4 = no "cardBill" kind: a card bill is a spend in the built-in "Credit Card Bill" category.
    public static let currentSchemaVersion = 4
    /// A reversal is linked automatically to a matching debit from at most this long before it.
    public static let reversalWindow: TimeInterval = 7 * 86_400
    /// Two different SMS with the same amount and direction this close together are one payment,
    /// unless they name different reference numbers or cards.
    public static let duplicateSMSWindow: TimeInterval = 120

    public var schemaVersion: Int
    public var config: BudgetConfig?
    /// All money movements (spends, card bills, savings, credits). Newest first.
    public var transactions: [Spend]
    public var settings: AppSettings
    /// Newest first. Debug log for the parser and storage, shown in Settings > Debug log.
    public var log: [LogEntry]
    /// Created by the user, plus the built-in ones (`SpendCategory.builtIn`), which are always present.
    public var categories: [SpendCategory]

    public init(config: BudgetConfig? = nil, transactions: [Spend] = [], settings: AppSettings = AppSettings(),
                log: [LogEntry] = [], categories: [SpendCategory] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.config = config
        self.transactions = transactions
        self.settings = settings
        self.log = log
        self.categories = categories
        addBuiltInCategories()
    }

    /// Adds any built-in category that is missing. A user category with the same name becomes the built-in one.
    private mutating func addBuiltInCategories() {
        for builtIn in SpendCategory.builtIn where !categories.contains(where: { $0.id == builtIn.id }) {
            guard let index = categories.firstIndex(where: { $0.name.caseInsensitiveCompare(builtIn.name) == .orderedSame }) else {
                categories.append(builtIn)
                continue
            }
            let oldID = categories[index].id
            categories[index].id = builtIn.id
            for i in transactions.indices {
                if transactions[i].categoryID == oldID { transactions[i].categoryID = builtIn.id }
                if var prediction = transactions[i].prediction {
                    prediction.candidates = prediction.candidates.map { candidate in
                        candidate.categoryID == oldID
                            ? CategoryCandidate(categoryID: builtIn.id, confidence: candidate.confidence) : candidate
                    }
                    transactions[i].prediction = prediction
                }
            }
        }
    }

    // Tolerant decoding: new fields must not make old files unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        config = try c.decodeIfPresent(BudgetConfig.self, forKey: .config)
        transactions = try c.decodeIfPresent([Spend].self, forKey: .transactions) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        log = try c.decodeIfPresent([LogEntry].self, forKey: .log) ?? []
        categories = try c.decodeIfPresent([SpendCategory].self, forKey: .categories) ?? []
        migrate()
    }

    /// Upgrades data decoded from an older file, one version at a time.
    private mutating func migrate() {
        if schemaVersion < 1 {
            // Version 0 stored debits only. `Spend`'s decoder already defaults them to kind .spend, account .bank.
            schemaVersion = 1
        }
        if schemaVersion < 2 {
            // Version 1 had no categories or sources. The decoders already default them to empty.
            schemaVersion = 2
        }
        if schemaVersion < 3 {
            // Version 2 had no predictions. The decoder already defaults them to nil.
            schemaVersion = 3
        }
        if schemaVersion < 4 {
            // Version 3 had a "cardBill" kind. `Spend`'s decoder turns those entries into spends in the
            // built-in "Credit Card Bill" category, which is added below.
            schemaVersion = 4
        }
        // Always, so a built-in category can never go missing.
        addBuiltInCategories()
    }

    /// Adds an entry. Returns false if it is a duplicate SMS:
    /// the same text within `dedupeWindow` seconds, the same reference number, direction and amount
    /// (the bank and the UPI app often both send an SMS for one payment), or another SMS with the same
    /// amount and direction within `duplicateSMSWindow` that names no different reference or card.
    /// A duplicate still fills in details the kept entry is missing (see `mergeDuplicate`).
    /// A reversal with no link is linked to its matching debit, if one is found and `linkReversal` is true.
    @discardableResult
    public mutating func add(_ transaction: Spend, dedupeWindow: TimeInterval = 600, linkReversal: Bool = true,
                             calendar: Calendar = .current) -> Bool {
        if transaction.source == .sms, let index = duplicateIndex(of: transaction, dedupeWindow: dedupeWindow) {
            let merchant = transactions[index].merchant
            mergeDuplicate(transaction, into: index)
            // A better recipient name is better evidence for the category.
            if transactions[index].merchant != merchant { predictCategory(at: index, calendar: calendar) }
            return false
        }
        var entry = transaction
        if linkReversal, entry.kind == .reversal, entry.reverses == nil {
            entry.reverses = reversalTarget(for: entry)
        }
        transactions.append(entry)
        transactions.sort { $0.date > $1.date }
        if entry.categoryID == nil, let index = transactions.firstIndex(where: { $0.id == entry.id }) {
            predictCategory(at: index, calendar: calendar)
        }
        return true
    }

    /// Saves an edit made by the user. Every field that changed is recorded as the user's decision.
    public mutating func update(_ transaction: Spend) {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        let old = transactions[index]
        var entry = transaction
        if old.kind != entry.kind { entry.sources.kind = .user }
        // Changing the type can reset the account (other credit is always "bank"). That is not a user decision.
        if old.account != entry.account, old.kind == entry.kind { entry.sources.account = .user }
        if old.excluded != entry.excluded { entry.sources.excluded = .user }
        if old.merchant != entry.merchant { entry.sources.merchant = .user }
        if old.amount != entry.amount { entry.sources.amount = .user }
        if old.categoryID != entry.categoryID { entry.sources.category = entry.categoryID == nil ? nil : .user }
        transactions[index] = entry
        transactions.sort { $0.date > $1.date }
    }

    /// Removes entries. A reversal linked to a removed entry is kept but excluded:
    /// the original is gone, so the reversal must not count as money back.
    public mutating func remove(ids: Set<UUID>) {
        transactions.removeAll { ids.contains($0.id) }
        for index in transactions.indices {
            if let target = transactions[index].reverses, ids.contains(target) {
                transactions[index].reverses = nil
                transactions[index].excluded = true
            }
        }
    }

    /// The debit a reversal most likely cancels: same reference number if both have one; otherwise the most
    /// recent debit with the same amount (and card, if both name one) within `reversalWindow` before it,
    /// that no other reversal has claimed.
    public func reversalTarget(for reversal: Spend) -> UUID? {
        let claimed = Set(transactions.compactMap { $0.id == reversal.id ? nil : $0.reverses })
        let candidates = transactions.filter {
            ($0.kind == .spend || $0.kind == .savings)
                && !$0.isCardBill
                && !claimed.contains($0.id)
                && $0.date <= reversal.date
                && reversal.date.timeIntervalSince($0.date) <= Self.reversalWindow
        }
        if let ref = reversal.ref, let match = candidates.first(where: { $0.ref == ref }) {
            return match.id
        }
        let card = Counting.normalizedCard(reversal.card)
        return candidates
            .filter { $0.amount == reversal.amount }
            .filter { card == nil || Counting.normalizedCard($0.card) == nil || Counting.normalizedCard($0.card) == card }
            .max { $0.date < $1.date }?
            .id
    }

    /// Payment gateways and banks that an SMS can name instead of the real recipient.
    private static let intermediaryMerchantPattern = #"bank$|\b(razorpay|payu|billdesk|cashfree|ccavenue|bharatpe|npci)\b"#

    /// Keeps the first entry, but takes what the second SMS knows and the first did not.
    /// Never replaces a value the user set.
    private mutating func mergeDuplicate(_ duplicate: Spend, into index: Int) {
        var kept = transactions[index]
        if kept.ref == nil { kept.ref = duplicate.ref }
        // The other SMS saw a card bill (for example the bank's "towards credit card" text).
        if duplicate.isCardBill, !kept.isCardBill, kept.sources.category != .user, kept.kind == .spend {
            kept.categoryID = SpendCategory.creditCardBillID
            kept.sources.category = .rule
            kept.account = .bank
        }
        if kept.card == nil { kept.card = duplicate.card }
        if kept.account == .bank, duplicate.account == .creditCard, kept.sources.account != .user {
            kept.account = .creditCard
        }
        func isIntermediary(_ name: String) -> Bool { RX.matches(Self.intermediaryMerchantPattern, name) }
        if kept.sources.merchant != .user, let incoming = duplicate.merchant, !isIntermediary(incoming),
           kept.merchant.map(isIntermediary) ?? true {
            kept.merchant = incoming
        }
        transactions[index] = kept
    }

    private func duplicateIndex(of entry: Spend, dedupeWindow: TimeInterval) -> Int? {
        transactions.firstIndex { other in
            if let raw = entry.rawText, other.rawText == raw,
               abs(other.date.timeIntervalSince(entry.date)) < dedupeWindow {
                return true
            }
            if let ref = entry.ref, other.ref == ref,
               other.kind.isCredit == entry.kind.isCredit, other.amount == entry.amount {
                return true
            }
            return isSamePaymentFromAnotherSender(entry, other)
        }
    }

    /// Two different SMS for one payment (card issuer + NPCI, bank + UPI app). Often only one has a reference
    /// or card number and the merchant names differ, so only a real conflict in those fields rules it out.
    private func isSamePaymentFromAnotherSender(_ entry: Spend, _ other: Spend) -> Bool {
        guard other.source == .sms, other.amount == entry.amount,
              other.kind.isCredit == entry.kind.isCredit,
              abs(other.date.timeIntervalSince(entry.date)) <= Self.duplicateSMSWindow else { return false }
        if let a = entry.ref, let b = other.ref, a != b { return false }
        if let a = Counting.normalizedCard(entry.card), let b = Counting.normalizedCard(other.card), a != b { return false }
        return true
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
        (try? coordinated(writing: false) { rawLoad() }) ?? rawLoad()
    }

    public func save(_ ledger: Ledger) throws {
        try coordinated(writing: true) { try rawSave(ledger) }
    }

    /// Load, change, save, as one coordinated write. Always re-reads first, because another process
    /// (widget / App Intent) may have written. The file coordinator makes the other process wait.
    @discardableResult
    public func update(_ body: (inout Ledger) -> Void) throws -> Ledger {
        try coordinated(writing: true) {
            var ledger = rawLoad()
            body(&ledger)
            try rawSave(ledger)
            return ledger
        }
    }

    // MARK: Private. Never call `coordinated` from inside another `coordinated` block.

    #if canImport(Darwin)
    /// NSFileCoordinator serialises access across the app, the App Intent and the widget processes.
    private func coordinated<T>(writing: Bool, _ body: () throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { _ in
                result = Result(catching: { try body() })
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in
                result = Result(catching: { try body() })
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    #else
    /// Linux / Windows (tests only): one process, nothing to coordinate.
    private func coordinated<T>(writing: Bool, _ body: () throws -> T) throws -> T {
        try body()
    }
    #endif

    private func rawLoad() -> Ledger {
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

    private func rawSave(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }
}
