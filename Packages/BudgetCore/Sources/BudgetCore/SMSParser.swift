import Foundation

public struct ParsedSMS: Equatable, Sendable {
    public let amount: Decimal
    public let merchant: String?
    /// Which rule produced this result (shown in the debug log).
    public let ruleID: String
    public let kind: EntryKind
    /// Credit card or bank account.
    public let account: PaymentAccount
    /// Last 4 digits of the credit card (the card used, or for a card bill the card being paid), if named.
    public let card: String?
    /// Bank / UPI reference number (6+ digits), if the SMS has one.
    public let ref: String?
    /// The rules saw a credit card bill payment. The entry gets the built-in "Credit Card Bill" category.
    public var isCardBill: Bool = false

    /// The entry to log for this SMS. A card bill gets the built-in category, recorded as decided by a rule.
    public func makeEntry(date: Date, rawText: String?) -> Spend {
        var entry = Spend(amount: amount, date: date, merchant: merchant, source: .sms, rawText: rawText,
                          kind: kind, account: account, card: card, ref: ref)
        if isCardBill {
            entry.categoryID = SpendCategory.creditCardBillID
            entry.sources.category = .rule
        }
        return entry
    }
}

public enum ParseResult: Equatable, Sendable {
    /// Money out: spend, card bill or savings.
    case debit(ParsedSMS)
    /// Money in: refund, reversal, cashback or other credit.
    case credit(ParsedSMS)
    case ignored(reason: String)

    public var parsed: ParsedSMS? {
        switch self {
        case .debit(let parsed), .credit(let parsed): return parsed
        case .ignored: return nil
        }
    }
}

/// A parsing rule for debits. All patterns are case-insensitive NSRegularExpression patterns.
public struct SMSRule: Sendable {
    public let id: String
    /// The rule only applies if this pattern matches the message.
    public let mustMatch: String
    /// Capture group 1 = the amount (commas allowed).
    public let amount: String
    /// Optional. Capture group 1 = the merchant / payee.
    public let merchant: String?

    public init(id: String, mustMatch: String, amount: String, merchant: String? = nil) {
        self.id = id
        self.mustMatch = mustMatch
        self.amount = amount
        self.merchant = merchant
    }
}

extension SMSRule {
    /// Bank-specific rules. They are tried in order, before `generic`.
    /// Add one per real SMS format that `generic` gets wrong (see the add-sms-format skill).
    /// Always add a test with an anonymised sample in SMSParserTests.
    public static let bankRules: [SMSRule] = [
        // Example:
        // SMSRule(
        //     id: "examplebank-card",
        //     mustMatch: #"examplebank.*\bspent\b"#,
        //     amount: #"spent\s+(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#,
        //     merchant: #"\bat\s+(.+?)\s+on\b"#
        // ),
        // UPI bill payment: the biller is the first words of the message, with no "at" or "to".
        SMSRule(
            id: "upi-bill-paid",
            mustMatch: #"\bbill of (?:rs\.?|inr|₹)\s*[0-9].*\bpaid for\b"#,
            amount: SMSParser.currencyAmountPattern,
            merchant: #"^(.{2,40}?)\s+bill of\b"#
        ),
    ]

    /// Fallback that handles most Indian bank / UPI debit SMS formats.
    public static let generic = SMSRule(
        id: "generic",
        mustMatch: #"\b(debited|spent|paid|sent|withdrawn|purchased?)\b|\bdebit of\b|\btxn of\b"#,
        amount: SMSParser.currencyAmountPattern,
        merchant: #"\b(?:at|to|towards|info:?)\s+([a-z0-9][a-z0-9 &._@*'\-/]{1,40}?)(?=\s+(?:on|via|ref|upi|avl|from|txn|dated|using)\b|[,;\n]|\.(?:\s|$)|$)"#
    )
}

/// Turns a bank SMS into a debit or a credit (amount, merchant, kind, card, reference), or explains why it was ignored.
///
/// Order: ignore rules → card issuer's "payment received" → credit? → failed → debit rules.
public struct SMSParser: Sendable {
    public static let currencyAmountPattern = #"(?:\brs\.?|\binr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#

    /// Checked first. Any match means the message is not a completed money movement.
    static let ignoreRules: [(pattern: String, reason: String)] = [
        (#"\botp\b|one[- ]time password|verification code"#, "OTP / verification"),
        (#"\bwill be (debited|deducted|charged|credited|refunded|reversed)\b|\bis due\b|\bdue (on|by|date)\b"#,
         "upcoming payment / reminder"),
        (#"\brefund\b.{0,40}\binitiated\b|\binitiated\b.{0,40}\brefund\b"#, "refund initiated (not received yet)"),
        (#"\brequested money\b|\bcollect request\b|\bhas requested\b"#, "UPI request (not paid)"),
    ]
    /// Offer wording: "Get 5% Extra Cashback", "Min. Trxn.: Rs. 6000", "Max. Cashback: Rs. 750".
    static let promoPattern = #"\bmin\.?\s*(trxn|txn|transaction|spends?|purchase)\b|\bmax\.?\s*cash\s?back\b|\bget\b.{0,30}\d\s*%.{0,30}\bcash\s?back\b"#
    /// A message with one of these words reports real money, even if an ad follows it.
    static let completedMovementPattern = #"\b(debited|spent|sent|paid|withdrawn|credited)\b"#
    /// Checked after credits, so "txn failed, amount reversed" is still read as a reversal.
    static let failedPattern = #"\b(declined|failed|unsuccessful)\b"#

    // MARK: Credits

    /// Always a credit, wherever it appears.
    static let strongCreditPattern = #"\b(refund(ed)?|revers(ed|al))\b"#
    /// A credit only if it comes before any debit word ("Rs 500 debited and credited to shop@upi" is a debit).
    static let weakCreditPattern = #"\b(credited|received|cash\s?back)\b"#
    static let creditMerchantPattern = #"\b(?:from|by|at)\s+([a-z0-9][a-z0-9 &._@*'\-/]{1,40}?)(?=\s+(?:on|via|ref|upi|avl|to|into|in|txn|dated|using|towards|for|credited|has|is|was)\b|[,;\n]|\.(?:\s|$)|$)"#
    /// The card issuer's "payment received" SMS. The bank's debit SMS for the same payment is the one that counts.
    static let cardPaymentReceivedPattern = #"\bpayment\b.{0,80}\b(received|credited)\b|\b(received|credited)\b.{0,40}\bpayment\b"#
    static let debitWordsPattern = #"\b(debited|spent|sent|withdrawn)\b"#

    // MARK: Debit kinds

    /// A debit that is paying a credit card bill (from a bank account, or through an app like CRED).
    static let cardBillPatterns: [String] = [
        #"\bcredit\s*card\s*(bill|payment|dues?|repayment)\b"#,
        #"\bcc\s*(bill|payment)\b"#,
        #"\bcard\s*bill\b"#,
        #"\b(towards|for)\s+(your\s+)?([a-z]+\s+){0,3}credit\s*card\b"#,
        #"\bcred\.club\b|\bcred\s+club\b|\b(to|vpa|info:?)\s+cred\b"#,
    ]
    static let knownCardBillWordsPattern = #"\b(bill|towards|repay(ment)?)\b"#
    /// A debit to an investment platform or fund: savings, not a spend. Users add more in Settings.
    public static let savingsPatterns: [String] = [
        #"\bgroww\b"#, #"\bzerodha\b"#, #"\bupstox\b"#, #"\bkuvera\b"#, #"\bpaytm\s*money\b"#,
        #"\bangel\s*(one|broking)\b"#, #"\bindmoney\b"#, #"\bet\s*money\b"#, #"\bsmallcase\b"#,
        #"\biccl\b|\bindian\s+clearing\b"#, #"\bnse\s*clearing\b|\bnsccl\b"#, #"\bbse\b"#,
        #"\bmutual\s*funds?\b"#, #"\bsip\b"#, #"\bcams\b|\bcamsonline\b"#, #"\bkfin(tech)?\b"#, #"\bnps\b"#,
    ]

    // MARK: Cards and references

    static let creditCardPattern = #"\bcredit\s*card\b"#
    /// Capture group 1 = last 4 digits of a card ("Card XX1234", "card ending 1234", "CC x1234").
    static let cardNumberPattern = #"\b(?:card|cc)\b[^0-9]{0,20}?(\d{4})\b"#
    /// Capture group 1 = reference number ("UPI Ref No 612345678901", "RRN: 123456", "UTR 98765432").
    static let refPattern = #"\b(?:ref(?:erence)?|rrn|utr|txn\s*id|transaction\s*id)(?:\s*(?:no|num(?:ber)?|id))?[\s.:#-]*([0-9]{6,})\b"#

    public var rules: [SMSRule]
    /// Last 4 digits of the user's credit cards (Settings). An SMS that names one of these cards is a card
    /// spend (or a card bill / card refund), even when it does not say "credit card".
    public var creditCards: Set<String>
    /// Extra savings words from Settings, matched literally and case-insensitively.
    public var savingsKeywords: [String]

    public init(rules: [SMSRule] = SMSRule.bankRules + [SMSRule.generic],
                creditCards: [String] = [], savingsKeywords: [String] = []) {
        self.rules = rules
        self.creditCards = Set(creditCards.compactMap(Counting.normalizedCard))
        self.savingsKeywords = savingsKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Uses the cards and savings words from the user's settings.
    public init(settings: AppSettings) {
        self.init(creditCards: settings.creditCards, savingsKeywords: settings.savingsKeywords)
    }

    public func parse(_ message: String) -> ParseResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignored(reason: "empty message") }

        for rule in Self.ignoreRules where RX.matches(rule.pattern, text) {
            return .ignored(reason: rule.reason)
        }
        if RX.matches(Self.promoPattern, text), !RX.matches(Self.completedMovementPattern, text) {
            return .ignored(reason: "promotional offer")
        }
        if RX.matches(Self.cardPaymentReceivedPattern, text), !RX.matches(Self.debitWordsPattern, text) {
            return .ignored(reason: "card payment received (the bank debit SMS is counted)")
        }

        if isCredit(text) {
            return parseCredit(text)
        }

        if RX.matches(Self.failedPattern, text) {
            return .ignored(reason: "failed transaction")
        }

        for rule in rules where RX.matches(rule.mustMatch, text) {
            guard let amount = Self.firstAmount(pattern: rule.amount, in: text), amount > 0 else { continue }
            var merchant = rule.merchant.flatMap { RX.firstCapture($0, in: text) }.flatMap(Self.cleanMerchant)
            let debit = classifyDebit(text)
            if debit.isCardBill, merchant == nil { merchant = "Credit card bill" }
            return .debit(ParsedSMS(amount: amount, merchant: merchant, ruleID: rule.id, kind: debit.kind,
                                    account: debit.account, card: debit.card, ref: Self.reference(in: text),
                                    isCardBill: debit.isCardBill))
        }
        return .ignored(reason: "no rule matched")
    }

    // MARK: Credits

    func isCredit(_ text: String) -> Bool {
        if RX.matches(Self.strongCreditPattern, text) { return true }
        guard let credit = RX.firstMatchLocation(Self.weakCreditPattern, in: text) else { return false }
        let debitPatterns = rules.map(\.mustMatch) + [Self.debitWordsPattern]
        let debit = debitPatterns.compactMap { RX.firstMatchLocation($0, in: text) }.min()
        return debit.map { credit < $0 } ?? true
    }

    func parseCredit(_ text: String) -> ParseResult {
        guard let amount = Self.firstAmount(pattern: Self.currencyAmountPattern, in: text), amount > 0 else {
            return .ignored(reason: "credit without an amount")
        }
        let kind: EntryKind
        if RX.matches(#"\brevers(ed|al)\b"#, text) || (RX.matches(#"\brefund(ed)?\b"#, text) && RX.matches(Self.failedPattern, text)) {
            kind = .reversal
        } else if RX.matches(#"\brefund(ed)?\b"#, text) {
            kind = .refund
        } else if RX.matches(#"\bcash\s?back\b"#, text) {
            kind = .cashback
        } else {
            kind = .otherCredit
        }
        let (onCard, card) = creditCardMention(text)
        let merchant = RX.firstCapture(Self.creditMerchantPattern, in: text).flatMap(Self.cleanMerchant)
        return .credit(ParsedSMS(amount: amount, merchant: merchant, ruleID: "credit", kind: kind,
                                 account: onCard ? .creditCard : .bank, card: onCard ? card : nil,
                                 ref: Self.reference(in: text)))
    }

    // MARK: Debits

    struct Debit {
        let kind: EntryKind
        let account: PaymentAccount
        let card: String?
        var isCardBill = false
    }

    /// Card bill, savings, or spend (+ which account, + card digits).
    func classifyDebit(_ text: String) -> Debit {
        let (onCard, card) = creditCardMention(text)
        let isKnownCard = card.map { creditCards.contains($0) } ?? false
        if Self.cardBillPatterns.contains(where: { RX.matches($0, text) })
            || (isKnownCard && RX.matches(Self.knownCardBillWordsPattern, text)) {
            // A bill is paid from a bank account. The card digits name the card being paid.
            return Debit(kind: .spend, account: .bank, card: card, isCardBill: true)
        }
        let account: PaymentAccount = onCard ? .creditCard : .bank
        if isSavings(text) {
            return Debit(kind: .savings, account: account, card: onCard ? card : nil)
        }
        return Debit(kind: .spend, account: account, card: onCard ? card : nil)
    }

    func isSavings(_ text: String) -> Bool {
        Self.savingsPatterns.contains { RX.matches($0, text) }
            || savingsKeywords.contains { RX.matches(NSRegularExpression.escapedPattern(for: $0), text) }
    }

    /// (is it a credit card?, last 4 digits of the card named in the SMS).
    func creditCardMention(_ text: String) -> (Bool, String?) {
        let card = RX.firstCapture(Self.cardNumberPattern, in: text)
        let isKnownCard = card.map { creditCards.contains($0) } ?? false
        return (isKnownCard || RX.matches(Self.creditCardPattern, text), card)
    }

    static func reference(in text: String) -> String? {
        RX.firstCapture(refPattern, in: text)
    }

    // MARK: Helpers

    /// First amount match that is not a balance or a limit ("Avl Bal Rs 10,000").
    static func firstAmount(pattern: String, in text: String) -> Decimal? {
        for (capture, range) in RX.captures(pattern, in: text) {
            // Look at the words just before the currency, but only after the last digit,
            // so "Avl Bal Rs 9,000. Rs 250 debited" skips 9,000 but keeps 250.
            let prefixStart = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
            var window = Substring(text[prefixStart..<range.lowerBound])
            if let lastDigit = window.lastIndex(where: { $0.isNumber }) {
                window = window[window.index(after: lastDigit)...]
            }
            let prefix = window.lowercased()
            if prefix.contains("bal") || prefix.contains("limit") || prefix.contains("lmt") || prefix.contains("avl") {
                continue
            }
            if let value = Amount.parse(capture) { return value }
        }
        return nil
    }

    static func cleanMerchant(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if name.lowercased().hasPrefix("vpa ") { name = String(name.dropFirst(4)) }
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lower = name.lowercased()
        if name.count < 2 || name.allSatisfy({ $0.isNumber }) { return nil }
        if lower.hasPrefix("your ") || lower.hasPrefix("a/c") || lower.hasPrefix("ac ") { return nil }
        return name
    }
}

/// Small NSRegularExpression wrapper (works on Apple platforms, Windows and Linux).
enum RX {
    static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        firstMatchLocation(pattern, in: text) != nil
    }

    /// UTF-16 offset of the first match, or nil.
    static func firstMatchLocation(_ pattern: String, in text: String) -> Int? {
        guard let rx = compile(pattern),
              let match = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return match.range.location
    }

    /// (capture group 1, its range) for every match.
    static func captures(_ pattern: String, in text: String) -> [(String, Range<String.Index>)] {
        guard let rx = compile(pattern) else { return [] }
        return rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return (String(text[range]), range)
        }
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first?.0
    }
}
