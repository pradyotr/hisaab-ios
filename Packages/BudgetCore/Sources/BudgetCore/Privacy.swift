import Foundation

/// Data minimisation for stored SMS text. The benchmark is GDPR Art. 5(1)(c) "data minimisation" and
/// 5(1)(e) "storage limitation", even though the data never leaves the iPhone.
///
/// - The full SMS is kept for `Ledger.fullSMSRetention`. That is long enough to check how it was parsed and
///   to catch duplicates (they arrive within minutes).
/// - After that, every run of digits is replaced with "*". This removes balances, amounts, account, card,
///   phone and reference numbers. The words stay, because category learning (`FeatureGroup.smsWord`) and
///   `Spend.method` read them, and neither uses digits.
/// - The parsed fields (amount, merchant, card, ref) are kept. The budget and the reversal / card bill
///   matching need them.
/// - SMS that were not logged as an entry (OTPs, personal messages, promotions) are never stored.
public enum SMSRedaction {
    private static let digits = try? NSRegularExpression(pattern: #"\p{Nd}+"#)

    public static func redact(_ text: String) -> String {
        guard let digits else { return text }
        return digits.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "*")
    }
}

extension Ledger {
    /// How long the full text of a logged SMS is kept before its digits are removed.
    public static let fullSMSRetention: TimeInterval = 7 * 86_400
    /// Debug log entries older than this are deleted.
    public static let logRetention: TimeInterval = 30 * 86_400

    /// Applies the retention rules in `SMSRedaction`. Returns true if anything changed, so callers can skip a save.
    /// Does nothing while `settings.keepFullSMSText` is on (a debugging option).
    @discardableResult
    public mutating func applyRetention(now: Date = Date()) -> Bool {
        guard !settings.keepFullSMSText else { return false }
        var changed = false
        let smsCutoff = now.addingTimeInterval(-Self.fullSMSRetention)
        for index in transactions.indices where transactions[index].date < smsCutoff {
            guard let raw = transactions[index].rawText else { continue }
            let redacted = SMSRedaction.redact(raw)
            if redacted != raw {
                transactions[index].rawText = redacted
                changed = true
            }
        }
        let logCutoff = now.addingTimeInterval(-Self.logRetention)
        let logCount = log.count
        log.removeAll { $0.date < logCutoff }
        if log.count != logCount { changed = true }
        for index in log.indices where log[index].date < smsCutoff && log[index].rawText != nil {
            log[index].rawText = nil
            changed = true
        }
        return changed
    }

    /// Debug log line for an SMS from the Shortcuts automation. The SMS text is kept only if it became an entry
    /// (or a duplicate of one). An ignored SMS can be a personal message, so its text is dropped unless
    /// `settings.keepFullSMSText` is on.
    public mutating func appendSMSLog(_ outcome: String, sms: String, logged: Bool, at date: Date = Date()) {
        appendLog(outcome, rawText: logged || settings.keepFullSMSText ? sms : nil, at: date)
    }
}
