import Foundation

/// What the budget widgets need, without the spend history. Stored next to the ledger with weaker file protection
/// (see `LedgerStore`), so the lock screen widgets work while `ledger.json` is unreadable.
///
/// It holds amounts already counted (`Counting` applied to ALL entries when the ledger was saved), dated from the
/// start of the current cycle. No merchants, notes or SMS text.
///
/// While the iPhone is locked, `addPending` adds an estimate for each new SMS: the entry counted on its own, except
/// that a card bill counts 0. A reversal counts as a refund. The next write while unlocked moves the SMS from the inbox
/// into the ledger and rebuilds the digest from it, which replaces the estimates.
public struct WidgetDigest: Codable, Equatable, Sendable {
    public var config: BudgetConfig?
    /// For the widgets' hide options, and for parsing SMS while locked.
    public var settings: AppSettings
    public var categories: [SpendCategory]
    /// Signed counted amounts with date and category only, dated in the cycle of `updated` or later.
    public var counted: [Spend]
    /// Invested amounts, the same way.
    public var invested: [Spend]
    /// SMS entries from the last `Ledger.duplicateWindow`, without merchant or text,
    /// so a second SMS for the same payment that arrives while locked is not counted twice.
    public var recentSMS: [Spend]
    /// SMS saved in the inbox since `updated`, counted above as estimates.
    public var pendingCount: Int
    public var updated: Date

    public init(ledger: Ledger, now: Date = Date(), calendar: Calendar = .current) {
        config = ledger.config
        settings = ledger.settings
        categories = ledger.categories
        pendingCount = 0
        updated = now
        let from = ledger.config.map { BudgetEngine(config: $0, calendar: calendar).cycle(containing: now).start }
            ?? .distantFuture
        counted = Counting.countedEntries(ledger.transactions)
            .filter { $0.date >= from }
            .map { Self.stripped($0, keepCategory: true) }
        invested = Counting.investedEntries(ledger.transactions)
            .filter { $0.date >= from }
            .map { Self.stripped($0, keepCategory: false) }
        let recent = now.addingTimeInterval(-Ledger.duplicateWindow)
        recentSMS = ledger.transactions
            .filter { $0.source == .sms && $0.date >= recent }
            .map(Self.strippedSMS)
    }

    public struct PendingResult: Equatable, Sendable {
        public let outcome: String
        /// Not a bank SMS: nothing needs to be kept for later.
        public let ignored: Bool
    }

    /// Adds the estimate for an SMS received while the ledger can't be read.
    @discardableResult
    public mutating func addPending(_ message: String, at date: Date) -> PendingResult {
        let entry: Spend
        switch SMSParser(settings: settings).parse(message) {
        case .debit(let parsed), .credit(let parsed):
            entry = parsed.makeEntry(date: date, rawText: nil)
        case .ignored(let reason):
            return PendingResult(outcome: "Ignored: \(reason)", ignored: true)
        }
        pendingCount += 1
        recentSMS.removeAll { date.timeIntervalSince($0.date) > Ledger.duplicateWindow }
        // The ledger's duplicate rules, against the recent SMS only.
        var recent = Ledger(transactions: recentSMS, settings: settings)
        guard recent.add(entry, dedupeWindow: Ledger.duplicateWindow, linkReversal: false) else {
            return PendingResult(outcome: "Saved until unlock (duplicate SMS)", ignored: false)
        }
        recentSMS.append(Self.strippedSMS(entry))
        // A card bill normally pays for card spends that are already counted, so its estimate is 0.
        let amounts = entry.isCardBill
            ? Counting.Amounts(counted: 0, invested: 0)
            : Counting.evaluate([entry])[entry.id] ?? Counting.Amounts(counted: 0, invested: 0)
        if amounts.counted != 0 {
            counted.append(Spend(id: entry.id, amount: amounts.counted, date: date))
        }
        if amounts.invested != 0 {
            invested.append(Spend(id: entry.id, amount: amounts.invested, date: date))
        }
        return PendingResult(outcome: "Saved until unlock: \(entry.kind.rawValue) \(entry.amount)", ignored: false)
    }

    /// Today's budget, as `BudgetEngine.snapshot(at:transactions:)` gives for the full ledger. Nil before setup.
    public func snapshot(at date: Date, calendar: Calendar = .current) -> TodaySnapshot? {
        guard let config else { return nil }
        return BudgetEngine(config: config, calendar: calendar)
            .snapshot(at: date, counted: .init(spent: counted, invested: invested))
    }

    /// This cycle's spending by category, as `BudgetEngine.categoryTotals(for:transactions:)` gives.
    public func categoryTotals(at date: Date, calendar: Calendar = .current) -> [CategoryTotal] {
        guard let config else { return [] }
        let cycle = BudgetEngine(config: config, calendar: calendar).cycle(containing: date)
        return Dictionary(grouping: counted.filter { cycle.contains($0.date) }, by: \.categoryID)
            .map { id, entries in
                CategoryTotal(categoryID: id, amount: entries.reduce(Decimal(0)) { $0 + $1.amount }, count: entries.count)
            }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return ($0.categoryID?.uuidString ?? "") < ($1.categoryID?.uuidString ?? "")
            }
    }

    private static func stripped(_ entry: Spend, keepCategory: Bool) -> Spend {
        Spend(id: entry.id, amount: entry.amount, date: entry.date, categoryID: keepCategory ? entry.categoryID : nil)
    }

    /// Only what the duplicate rules compare.
    private static func strippedSMS(_ entry: Spend) -> Spend {
        Spend(id: entry.id, amount: entry.amount, date: entry.date, source: .sms, kind: entry.kind,
              account: entry.account, card: entry.card, ref: entry.ref)
    }
}
