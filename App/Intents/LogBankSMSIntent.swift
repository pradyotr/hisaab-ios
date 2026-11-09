import AppIntents
import Foundation
import WidgetKit
import BudgetCore

/// Called by a Shortcuts personal automation: Automation > Message > (sender / contains "debited") > Run Immediately
/// > action "Log Bank SMS" with Message = Shortcut Input's content.
/// Runs in the background without opening the app.
struct LogBankSMSIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Bank SMS"
    static let description = IntentDescription("Reads a bank SMS and records the spend in Hisaab.")
    static let openAppWhenRun = false

    @Parameter(title: "Message")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$message) in Hisaab")
    }

    init() {}

    init(message: String) {
        self.message = message
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let outcome = try Self.process(message: message, at: Date())
        return .result(value: outcome)
    }

    /// Shared with the in-app parser playground so both paths behave the same.
    @discardableResult
    static func process(message: String, at date: Date) throws -> String {
        var outcome = ""
        try AppGroup.store.update { ledger in
            let result = SMSParser(settings: ledger.settings).parse(message)
            switch result {
            case .debit(let parsed), .credit(let parsed):
                let entry = Spend(amount: parsed.amount, date: date, merchant: parsed.merchant,
                                  source: .sms, rawText: message, kind: parsed.kind, account: parsed.account,
                                  card: parsed.card, ref: parsed.ref)
                if ledger.add(entry) {
                    var details = [parsed.ruleID, parsed.kind.rawValue]
                    if parsed.account == .creditCard { details.append("credit card") }
                    if let card = parsed.card { details.append("card \(card)") }
                    if let ref = parsed.ref { details.append("ref \(ref)") }
                    if let saved = ledger.transactions.first(where: { $0.id == entry.id }), let guess = saved.prediction {
                        let top = guess.candidates.first.flatMap { candidate in
                            ledger.categories.first { $0.id == candidate.categoryID }?.name
                        } ?? "?"
                        details.append("\(guess.autoAssign ? "auto" : "suggested"): \(top)")
                    }
                    if parsed.kind == .reversal {
                        let linked = ledger.transactions.first { $0.id == entry.id }?.reverses != nil
                        details.append(linked ? "linked to original" : "no original found")
                    }
                    outcome = "Logged \(parsed.amount) \(parsed.merchant ?? "") [\(details.joined(separator: ", "))]"
                } else {
                    outcome = "Duplicate SMS, skipped"
                }
            case .ignored(let reason):
                outcome = "Ignored: \(reason)"
            }
            ledger.appendLog(outcome, rawText: message, at: date)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return outcome
    }
}

struct HisaabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogBankSMSIntent(),
            phrases: ["Log bank SMS in \(.applicationName)"],
            shortTitle: "Log Bank SMS",
            systemImageName: "indianrupeesign.circle"
        )
    }
}
