import Foundation

extension Ledger {
    /// Parses a bank SMS and records it: the path for the Shortcuts automation, the in-app parser test and SMS
    /// that waited in the inbox while the iPhone was locked. Returns a one-line outcome for the debug log.
    @discardableResult
    public mutating func logSMS(_ message: String, at date: Date) -> String {
        let outcome: String
        var logged = true
        switch SMSParser(settings: settings).parse(message) {
        case .debit(let parsed), .credit(let parsed):
            let entry = parsed.makeEntry(date: date, rawText: message)
            if add(entry) {
                var details = [parsed.ruleID, parsed.isCardBill ? "card bill" : parsed.kind.rawValue]
                if parsed.account == .creditCard { details.append("credit card") }
                if let card = parsed.card { details.append("card \(card)") }
                if let ref = parsed.ref { details.append("ref \(ref)") }
                if let saved = transactions.first(where: { $0.id == entry.id }), let guess = saved.prediction {
                    let top = guess.candidates.first.flatMap { candidate in
                        categories.first { $0.id == candidate.categoryID }?.name
                    } ?? "?"
                    details.append("\(guess.autoAssign ? "auto" : "suggested"): \(top)")
                }
                if parsed.kind == .reversal {
                    let linked = transactions.first { $0.id == entry.id }?.reverses != nil
                    details.append(linked ? "linked to original" : "no original found")
                }
                outcome = "Logged \(parsed.amount) \(parsed.merchant ?? "") [\(details.joined(separator: ", "))]"
            } else {
                outcome = "Duplicate SMS, skipped"
            }
        case .ignored(let reason):
            outcome = "Ignored: \(reason)"
            logged = false
        }
        // An ignored SMS may be a personal message: its text is not kept (see `appendSMSLog`).
        appendSMSLog(outcome, sms: message, logged: logged, at: date)
        applyRetention(now: date)
        return outcome
    }
}
