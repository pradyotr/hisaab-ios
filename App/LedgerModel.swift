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
        ExportFiles.removeAll()
    }

    var config: BudgetConfig? { ledger.config }
    var engine: BudgetEngine? { ledger.config.map { BudgetEngine(config: $0) } }

    /// Re-reads the file (the App Intent may have written), takes in SMS that arrived while the iPhone was locked
    /// (any `update` does that) and applies the SMS text retention rules.
    func reload() {
        ledger = store.load()
        var copy = ledger
        if copy.applyRetention() || store.hasPendingSMS { mutate { _ = $0.applyRetention() } }
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
    func setHideWidgetsWhenLocked(_ hide: Bool) { mutate { $0.settings.hideWidgetsWhenLocked = hide } }
    func setKeepFullSMSText(_ keep: Bool) {
        mutate {
            $0.settings.keepFullSMSText = keep
            $0.applyRetention()
        }
    }
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

    // MARK: Export and erasure

    /// Writes all data to a temporary JSON file for the share sheet. The file is encrypted while the iPhone is
    /// locked and is deleted when the share sheet closes (`ExportFiles.removeAll`).
    func exportFile() throws -> URL {
        ExportFiles.removeAll()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(ExportFiles.prefix)\(formatter.string(from: Date())).json")
        try encoder.encode(store.load()).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Erases everything Hisaab stores: the ledger (spends, budget, categories, settings, log), unreadable copies,
    /// the widget's skip list and export files. UI preferences (appearance, app lock) are kept.
    func deleteAllData() throws {
        try store.deleteAll()
        let skips = AppGroup.ledgerURL.deletingLastPathComponent().appendingPathComponent("widget-skips.json")
        try? FileManager.default.removeItem(at: skips)
        ExportFiles.removeAll()
        ledger = store.load()
        WidgetCenter.shared.reloadAllTimelines()
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

/// Export files in the temporary folder.
enum ExportFiles {
    static let prefix = "Hisaab-export-"

    /// Deletes export files left in the temporary folder. Called when the share sheet closes and at launch,
    /// in case the app was closed while sharing.
    static func removeAll() {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: fileManager.temporaryDirectory,
                                                          includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: file)
        }
    }
}
