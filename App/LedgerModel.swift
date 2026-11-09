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
    func add(_ transaction: Spend, linkReversal: Bool = true) {
        mutate { $0.add(transaction, linkReversal: linkReversal) }
    }
    func update(_ transaction: Spend) { mutate { $0.update(transaction) } }
    func delete(ids: Set<UUID>) { mutate { $0.remove(ids: ids) } }
    func setHideValues(_ hide: Bool) { mutate { $0.settings.hideValues = hide } }
    func setCreditCards(_ cards: [String]) { mutate { $0.settings.creditCards = cards } }
    func setSavingsKeywords(_ words: [String]) { mutate { $0.settings.savingsKeywords = words } }
    func clearLog() { mutate { $0.log.removeAll() } }

    // MARK: Categories

    @discardableResult
    func createCategory(named name: String) -> SpendCategory? {
        var created: SpendCategory?
        mutate { created = $0.addCategory(named: name) }
        return created
    }

    @discardableResult
    func renameCategory(_ id: UUID, to name: String) -> Bool {
        var renamed = false
        mutate { renamed = $0.renameCategory(id, to: name) }
        return renamed
    }

    func deleteCategory(_ id: UUID) { mutate { $0.deleteCategory(id) } }
    func setCategory(_ id: UUID?, for ids: Set<UUID>) { mutate { $0.setCategory(id, for: ids) } }

    /// The "apply to similar spends" prompt to show after `spend` got `category`. Nil if there are no similar spends.
    func bulkOffer(after spend: Spend, category: SpendCategory) -> BulkCategoryOffer? {
        let similar = ledger.similarUncategorized(to: spend)
        guard !similar.isEmpty, let merchant = spend.merchant else { return nil }
        return BulkCategoryOffer(categoryID: category.id, categoryName: category.name, merchant: merchant,
                                 ids: Set(similar.map(\.id)))
    }

    /// Fills in predictions for spends with no category. Returns how many got one assigned.
    func predictUncategorized() -> Int {
        var assigned = 0
        mutate { assigned = $0.predictUncategorized() }
        return assigned
    }

    // MARK: Export

    /// Writes all data to a temporary JSON file for the share sheet.
    func exportFile() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hisaab-export-\(formatter.string(from: Date())).json")
        try encoder.encode(store.load()).write(to: url, options: .atomic)
        return url
    }

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
