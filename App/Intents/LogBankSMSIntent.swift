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
            switch SMSParser().parse(message) {
            case .debit(let parsed):
                let transaction = Spend(amount: parsed.amount, date: date, merchant: parsed.merchant,
                                              source: .sms, rawText: message)
                if ledger.add(transaction) {
                    outcome = "Logged \(parsed.amount) \(parsed.merchant ?? "") [\(parsed.ruleID)]"
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
