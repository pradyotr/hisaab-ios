import Foundation

/// A category the user created. (Not named `Category`: that clashes with an Objective-C type on Apple platforms.)
public struct SpendCategory: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Who decided the value of a field.
public enum FieldSource: String, Codable, Sendable {
    /// The user set or corrected it. Only these values will train predictions.
    case user
    /// Predicted from the user's history.
    case learned
    /// Set by the hard-coded parser rules.
    case rule
}

/// Sources of the fields a user can correct. Nil = not recorded (the entry was parsed and never changed).
public struct FieldSources: Codable, Equatable, Sendable {
    public var kind: FieldSource?
    public var account: FieldSource?
    public var excluded: FieldSource?
    public var merchant: FieldSource?
    public var amount: FieldSource?
    public var category: FieldSource?

    public init(kind: FieldSource? = nil, account: FieldSource? = nil, excluded: FieldSource? = nil,
                merchant: FieldSource? = nil, amount: FieldSource? = nil, category: FieldSource? = nil) {
        self.kind = kind
        self.account = account
        self.excluded = excluded
        self.merchant = merchant
        self.amount = amount
        self.category = category
    }
}

/// How the money moved. Derived from the entry, so better detection also applies to old entries.
public enum PaymentMethod: String, Codable, CaseIterable, Sendable {
    case creditCard, debitCard, upi, bankTransfer, atm, unknown
}

extension Spend {
    public var method: PaymentMethod {
        if account == .creditCard { return .creditCard }
        guard let text = rawText else { return .unknown }
        if RX.matches(#"\batm\b|\bwithdrawn\b"#, text) { return .atm }
        if RX.matches(#"\bdebit\s*card\b"#, text) { return .debitCard }
        if RX.matches(#"\bupi\b|\bbhim\b|\bvpa\b|[a-z0-9._-]+@[a-z]+"#, text) { return .upi }
        if RX.matches(#"\b(neft|imps|rtgs|net\s*banking)\b"#, text) { return .bankTransfer }
        if RX.matches(#"\bcard\b"#, text) { return .debitCard }
        return .unknown
    }

    /// The merchant in a form that is the same across SMS: "Swiggy", "SWIGGY" and "swiggy@ybl" give "swiggy".
    public var merchantKey: String? {
        guard let merchant else { return nil }
        let name = merchant.lowercased().split(separator: "@").first.map(String.init) ?? ""
        let words = name.split { !($0.isLetter || $0.isNumber) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}

extension Ledger {
    /// Creates a category. A name that already exists (ignoring case) returns that category.
    /// Returns nil for an empty name.
    @discardableResult
    public mutating func addCategory(named name: String) -> SpendCategory? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let existing = category(named: clean) { return existing }
        let category = SpendCategory(name: clean)
        categories.append(category)
        return category
    }

    /// Returns false if the name is empty or another category already uses it.
    @discardableResult
    public mutating func renameCategory(_ id: UUID, to name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = categories.firstIndex(where: { $0.id == id }) else { return false }
        if let other = category(named: clean), other.id != id { return false }
        categories[index].name = clean
        return true
    }

    /// Deletes a category. Its entries become uncategorized.
    public mutating func deleteCategory(_ id: UUID) {
        categories.removeAll { $0.id == id }
        for index in transactions.indices where transactions[index].categoryID == id {
            transactions[index].categoryID = nil
            transactions[index].sources.category = nil
        }
    }

    /// Sets the user's category on these entries. Nil clears it.
    public mutating func setCategory(_ categoryID: UUID?, for ids: Set<UUID>) {
        if let categoryID, !categories.contains(where: { $0.id == categoryID }) { return }
        for index in transactions.indices where ids.contains(transactions[index].id) {
            transactions[index].categoryID = categoryID
            transactions[index].sources.category = categoryID == nil ? nil : .user
        }
    }

    /// Most used first, then by name.
    public var categoriesByUse: [SpendCategory] {
        var uses: [UUID: Int] = [:]
        for entry in transactions {
            if let id = entry.categoryID { uses[id, default: 0] += 1 }
        }
        return categories.sorted {
            let (a, b) = (uses[$0.id, default: 0], uses[$1.id, default: 0])
            if a != b { return a > b }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Uncategorized entries that affect spending. Savings, ignored money in and fully covered card bills count 0,
    /// so they don't need a category.
    public var entriesNeedingCategory: [Spend] {
        let counted = Counting.countedAmounts(transactions)
        return transactions.filter { $0.categoryID == nil && (counted[$0.id] ?? 0) != 0 }
    }

    /// `entriesNeedingCategory`, biggest merchant groups first, so "apply to similar" clears the most entries early.
    /// Entries without a merchant come last. Newest first inside a group.
    public var categorizationQueue: [Spend] {
        let entries = entriesNeedingCategory
        let sizes = Dictionary(grouping: entries.compactMap(\.merchantKey)) { $0 }.mapValues(\.count)
        return entries.sorted { a, b in
            let (keyA, keyB) = (a.merchantKey ?? "", b.merchantKey ?? "")
            let (sizeA, sizeB) = (sizes[keyA, default: 0], sizes[keyB, default: 0])
            if sizeA != sizeB { return sizeA > sizeB }
            if keyA != keyB { return keyA < keyB }
            return a.date > b.date
        }
    }

    /// Other entries from the same merchant that still need a category.
    public func similarUncategorized(to entry: Spend) -> [Spend] {
        guard let key = entry.merchantKey else { return [] }
        return entriesNeedingCategory.filter { $0.id != entry.id && $0.merchantKey == key }
    }

    private func category(named name: String) -> SpendCategory? {
        categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Spending in one category (nil = uncategorized) during one cycle.
public struct CategoryTotal: Equatable, Identifiable, Sendable {
    public var id: UUID? { categoryID }
    public let categoryID: UUID?
    /// Signed counted amount (see `Counting`). Negative when refunds are larger than spends.
    public let amount: Decimal
    public let count: Int
}

public struct CategoryCycleAmount: Equatable, Identifiable, Sendable {
    public var id: Date { cycle.start }
    public let cycle: BudgetCycle
    public let amount: Decimal
}

extension BudgetEngine {
    /// Largest first. The totals add up to `summary(for:transactions:).spent`.
    /// Pass ALL entries: they are counted first (see `Counting`).
    public func categoryTotals(for cycle: BudgetCycle, transactions: [Spend]) -> [CategoryTotal] {
        let inCycle = Counting.countedEntries(transactions).filter { cycle.contains($0.date) }
        return Dictionary(grouping: inCycle, by: \.categoryID)
            .map { id, entries in
                CategoryTotal(categoryID: id, amount: entries.reduce(Decimal(0)) { $0 + $1.amount }, count: entries.count)
            }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return ($0.categoryID?.uuidString ?? "") < ($1.categoryID?.uuidString ?? "")
            }
    }

    /// One category's spending over the last `limit` cycles, oldest first, including cycles with no spending.
    /// Pass ALL entries: they are counted first (see `Counting`).
    public func categoryTrend(categoryID: UUID?, transactions: [Spend], upTo date: Date, limit: Int = 6) -> [CategoryCycleAmount] {
        let counted = Counting.countedEntries(transactions).filter { $0.categoryID == categoryID }
        return cycleSummaries(transactions: transactions, upTo: date).suffix(limit).map { summary in
            let amount = counted.filter { summary.cycle.contains($0.date) }.reduce(Decimal(0)) { $0 + $1.amount }
            return CategoryCycleAmount(cycle: summary.cycle, amount: amount)
        }
    }
}
