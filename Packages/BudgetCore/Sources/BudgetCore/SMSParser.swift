import Foundation

public struct ParsedSMS: Equatable, Sendable {
    public let amount: Decimal
    public let merchant: String?
    /// Which rule produced this result (shown in the debug log).
    public let ruleID: String
}

public enum ParseResult: Equatable, Sendable {
    case debit(ParsedSMS)
    case ignored(reason: String)
}

/// A parsing rule. All patterns are case-insensitive NSRegularExpression patterns.
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
    ]

    /// Fallback that handles most Indian bank / UPI debit SMS formats.
    public static let generic = SMSRule(
        id: "generic",
        mustMatch: #"\b(debited|spent|paid|sent|withdrawn|purchased?)\b|\bdebit of\b|\btxn of\b"#,
        amount: SMSParser.currencyAmountPattern,
        merchant: #"\b(?:at|to|towards|info:?)\s+([a-z0-9][a-z0-9 &._@*'\-/]{1,40}?)(?=\s+(?:on|via|ref|upi|avl|from|txn|dated|using)\b|[,;\n]|\.(?:\s|$)|$)"#
    )
}

/// Turns a bank SMS into a debit amount (+ merchant), or explains why it was ignored.
public struct SMSParser: Sendable {
    public static let currencyAmountPattern = #"(?:\brs\.?|\binr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#

    /// Checked first. Any match means the message is not a completed spend.
    static let ignoreRules: [(pattern: String, reason: String)] = [
        (#"\botp\b|one[- ]time password|verification code"#, "OTP / verification"),
        (#"\b(refund(ed)?|revers(ed|al))\b"#, "refund / reversal"),
        (#"\bwill be (debited|deducted|charged)\b|\bis due\b|\bdue (on|by|date)\b"#, "upcoming payment / reminder"),
        (#"\brequested money\b|\bcollect request\b|\bhas requested\b"#, "UPI request (not paid)"),
        (#"\b(declined|failed|unsuccessful)\b"#, "failed transaction"),
    ]

    public var rules: [SMSRule]

    public init(rules: [SMSRule] = SMSRule.bankRules + [SMSRule.generic]) {
        self.rules = rules
    }

    public func parse(_ message: String) -> ParseResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignored(reason: "empty message") }

        for rule in Self.ignoreRules where RX.matches(rule.pattern, text) {
            return .ignored(reason: rule.reason)
        }

        for rule in rules where RX.matches(rule.mustMatch, text) {
            guard let amount = Self.firstAmount(pattern: rule.amount, in: text), amount > 0 else { continue }
            let merchant = rule.merchant.flatMap { RX.firstCapture($0, in: text) }.flatMap(Self.cleanMerchant)
            return .debit(ParsedSMS(amount: amount, merchant: merchant, ruleID: rule.id))
        }

        if RX.matches(#"\bcredited\b"#, text) { return .ignored(reason: "credit") }
        return .ignored(reason: "no rule matched")
    }

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
        guard let rx = compile(pattern) else { return false }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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
