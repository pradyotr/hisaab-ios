import Foundation

public enum TransactionSource: String, Codable, Sendable {
    case sms
    case manual
}

/// What a money movement is, and so how it counts towards the budget (see `Counting`).
public enum EntryKind: String, Codable, CaseIterable, Sendable {
    // Money out
    /// Counts in full.
    case spend
    /// Credit card bill paid from a bank account. Counts only the part not covered by tracked card spends.
    case cardBill
    /// Investment (SIP, stocks, mutual funds, ...). Money out, but it is saved, not spent: counts 0.
    case savings
    // Money in
    /// Money back for a purchase. Counts as a negative spend on the day it comes back.
    case refund
    /// A failed or cancelled payment returned. When linked (`reverses`), it cancels the original spend.
    /// Not linked: counts like a refund.
    case reversal
    /// Counts as a negative spend on the day it is credited.
    case cashback
    /// Salary, transfers in, interest, ... Stored so it can be re-typed, but never counted.
    case otherCredit

    public var isCredit: Bool {
        switch self {
        case .spend, .cardBill, .savings: return false
        case .refund, .reversal, .cashback, .otherCredit: return true
        }
    }
}

/// Where the money moved.
public enum PaymentAccount: String, Codable, Sendable {
    /// Bank account, UPI, debit card or cash.
    case bank
    /// A credit card. Matters for card bill matching (see `Counting`).
    case creditCard
}

/// One money movement: a spend, a card bill, an investment, or a credit (refund, reversal, cashback, other).
/// Amounts are always positive; `kind` says the direction. (Named `Spend` for history: `Transaction` clashes with SwiftUI.)
public struct Spend: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var amount: Decimal
    public var date: Date
    public var merchant: String?
    public var note: String?
    public var source: TransactionSource
    /// Original SMS text, kept for debugging the parser and for de-duplication.
    public var rawText: String?
    public var kind: EntryKind
    public var account: PaymentAccount
    /// Last 4 digits of the credit card: the card used, or for `.cardBill` the card being paid. Nil = unknown.
    public var card: String?
    /// Bank / UPI reference number (RRN, UTR, Ref no). Used to skip duplicate SMS and to link reversals.
    public var ref: String?
    /// For `.reversal`: id of the entry it cancels.
    public var reverses: UUID?
    /// Kept in the list, but counts 0 (for example a transfer to your own account).
    /// Still takes part in card bill matching, because the money really moved on the card.
    public var excluded: Bool
    /// The user's category (see `Ledger.categories`). Nil = uncategorized.
    public var categoryID: UUID?
    /// Who decided each field. Only `.user` values will train predictions.
    public var sources: FieldSources

    public init(
        id: UUID = UUID(),
        amount: Decimal,
        date: Date = Date(),
        merchant: String? = nil,
        note: String? = nil,
        source: TransactionSource = .manual,
        rawText: String? = nil,
        kind: EntryKind = .spend,
        account: PaymentAccount = .bank,
        card: String? = nil,
        ref: String? = nil,
        reverses: UUID? = nil,
        excluded: Bool = false,
        categoryID: UUID? = nil,
        sources: FieldSources = FieldSources()
    ) {
        self.id = id
        self.amount = amount
        self.date = date
        self.merchant = merchant
        self.note = note
        self.source = source
        self.rawText = rawText
        self.kind = kind
        self.account = account
        self.card = card
        self.ref = ref
        self.reverses = reverses
        self.excluded = excluded
        self.categoryID = categoryID
        self.sources = sources
    }

    // Amount is stored as a string ("249.99") because JSON numbers can lose Decimal precision.
    private enum CodingKeys: String, CodingKey {
        case id, amount, date, merchant, note, source, rawText, kind, account, card, ref, reverses, excluded, categoryID, sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let text = try? c.decode(String.self, forKey: .amount), let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
            amount = value
        } else {
            amount = try c.decode(Decimal.self, forKey: .amount)
        }
        date = try c.decode(Date.self, forKey: .date)
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        source = try c.decodeIfPresent(TransactionSource.self, forKey: .source) ?? .manual
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        // Unknown values (from a newer build) fall back to safe defaults instead of failing the whole file.
        kind = (try? c.decodeIfPresent(EntryKind.self, forKey: .kind)) ?? .spend
        account = (try? c.decodeIfPresent(PaymentAccount.self, forKey: .account)) ?? .bank
        card = try c.decodeIfPresent(String.self, forKey: .card)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        reverses = try? c.decodeIfPresent(UUID.self, forKey: .reverses)
        excluded = (try? c.decodeIfPresent(Bool.self, forKey: .excluded)) ?? false
        categoryID = try? c.decodeIfPresent(UUID.self, forKey: .categoryID)
        sources = (try? c.decodeIfPresent(FieldSources.self, forKey: .sources)) ?? FieldSources()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(amount.description, forKey: .amount) // Decimal.description is locale-independent
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(merchant, forKey: .merchant)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(rawText, forKey: .rawText)
        try c.encode(kind, forKey: .kind)
        try c.encode(account, forKey: .account)
        try c.encodeIfPresent(card, forKey: .card)
        try c.encodeIfPresent(ref, forKey: .ref)
        try c.encodeIfPresent(reverses, forKey: .reverses)
        if excluded { try c.encode(excluded, forKey: .excluded) }
        try c.encodeIfPresent(categoryID, forKey: .categoryID)
        if sources != FieldSources() { try c.encode(sources, forKey: .sources) }
    }
}
