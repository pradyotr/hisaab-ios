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
    /// While the iPhone is locked the ledger can't be read: the SMS waits in the inbox, and the widgets get an
    /// estimate until the next unlocked write takes it in (see `LedgerStore`).
    @discardableResult
    static func process(message: String, at date: Date) throws -> String {
        let store = AppGroup.store
        var outcome = ""
        do {
            try store.update(now: date) { outcome = $0.logSMS(message, at: date) }
        } catch is LedgerStore.Unavailable {
            var ignored = false
            outcome = "Saved until unlock"
            try? store.updateDigest { digest in
                let result = digest.addPending(message, at: date)
                outcome = result.outcome
                ignored = result.ignored
            }
            // An SMS the parser ignores (OTPs, personal messages) is not kept.
            if !ignored { try store.enqueue(message, at: date) }
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
