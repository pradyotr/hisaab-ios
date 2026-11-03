import Foundation
import BudgetCore

/// Shared storage location for the app, the App Intent and the widget.
/// Compiled into BOTH the app and the widget targets.
enum AppGroup {
    /// Must match `APP_GROUP_ID` in project.yml (entitlements). Change both together.
    static let defaultID = "group.com.pradyot.hisaab"

    /// AltStore/SideStore rewrite App Group IDs when re-signing with a free account and record
    /// the real IDs in Info.plist under `ALTAppGroups`. Prefer those when present.
    static var id: String {
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String],
           let first = groups.first {
            return first
        }
        return defaultID
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// False means the sideload tool dropped the App Group: the app still works, but the widget can't see data.
    static var isShared: Bool { containerURL != nil }

    static var ledgerURL: URL {
        let base = containerURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ledger.json")
    }

    static var store: LedgerStore { LedgerStore(url: ledgerURL) }
}
