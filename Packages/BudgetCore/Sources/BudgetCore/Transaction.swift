import Foundation

public enum TransactionSource: String, Codable, Sendable {
    case sms
    case manual
}

/// A single spend. Amounts are always positive; credits are never stored.
public struct Transaction: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var amount: Decimal
    public var date: Date
    public var merchant: String?
    public var note: String?
    public var source: TransactionSource
    /// Original SMS text, kept for debugging the parser and for de-duplication.
    public var rawText: String?

    public init(
        id: UUID = UUID(),
        amount: Decimal,
        date: Date = Date(),
        merchant: String? = nil,
        note: String? = nil,
        source: TransactionSource = .manual,
        rawText: String? = nil
    ) {
        self.id = id
        self.amount = amount
        self.date = date
        self.merchant = merchant
        self.note = note
        self.source = source
        self.rawText = rawText
    }

    // Amount is stored as a string ("249.99") because JSON numbers can lose Decimal precision.
    private enum CodingKeys: String, CodingKey { case id, amount, date, merchant, note, source, rawText }

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
    }
}
