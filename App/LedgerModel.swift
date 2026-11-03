import Foundation
import Observation
import WidgetKit
import BudgetCore

/// UI-facing wrapper around the shared ledger file.
/// Every change re-reads the file first (the App Intent may have written in the background),
/// saves, then asks WidgetKit to refresh.
@MainActor
@Observable
final class LedgerModel {
    private(set) var ledger = Ledger()
    @ObservationIgnored private let store = AppGroup.store

    init() {
        reload()
    }

    var config: BudgetConfig? { ledger.config }
    var engine: BudgetEngine? { ledger.config.map { BudgetEngine(config: $0) } }

    func reload() {
        ledger = store.load()
    }

    func saveConfig(_ config: BudgetConfig) { mutate { $0.config = config } }
    func add(_ transaction: Transaction) { mutate { $0.add(transaction) } }
    func update(_ transaction: Transaction) { mutate { $0.update(transaction) } }
    func delete(ids: Set<UUID>) { mutate { $0.remove(ids: ids) } }
    func setHideValues(_ hide: Bool) { mutate { $0.settings.hideValues = hide } }
    func clearLog() { mutate { $0.log.removeAll() } }

    private func mutate(_ body: (inout Ledger) -> Void) {
        do {
            ledger = try store.update(body)
        } catch {
            var fallback = store.load()
            body(&fallback)
            fallback.appendLog("Save failed: \(error.localizedDescription)")
            ledger = fallback
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
