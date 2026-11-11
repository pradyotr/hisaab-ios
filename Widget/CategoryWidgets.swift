import AppIntents
import SwiftUI
import WidgetKit
import BudgetCore

// MARK: - Category chart

struct CategoryChartEntry: TimelineEntry {
    let date: Date
    let slices: [CategorySlice]
    let spent: Decimal
    let currencyCode: String
    let hideValues: Bool
    let isSetUp: Bool
}

struct CategoryChartProvider: TimelineProvider {
    func placeholder(in context: Context) -> CategoryChartEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (CategoryChartEntry) -> Void) {
        completion(context.isPreview ? Self.sample : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CategoryChartEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let midnight = calendar.startOfDay(for: tomorrow)
        completion(Timeline(entries: [entry(at: now), entry(at: midnight)], policy: .after(midnight)))
    }

    private func entry(at date: Date) -> CategoryChartEntry {
        let ledger = AppGroup.store.load()
        guard let config = ledger.config else {
            return CategoryChartEntry(date: date, slices: [], spent: 0, currencyCode: "INR", hideValues: true, isSetUp: false)
        }
        let engine = BudgetEngine(config: config)
        let totals = engine.categoryTotals(for: engine.cycle(containing: date), transactions: ledger.transactions)
        return CategoryChartEntry(date: date, slices: CategoryPie.slices(totals: totals, categories: ledger.categories),
                                  spent: totals.reduce(Decimal(0)) { $0 + $1.amount }, currencyCode: config.currencyCode,
                                  hideValues: ledger.settings.hideValues, isSetUp: true)
    }

    private static var sample: CategoryChartEntry {
        let slices = zip(["Food", "Travel", "Bills"], [5000.0, 3000.0, 2000.0]).enumerated().map { index, item in
            CategorySlice(name: item.0, amount: item.1, color: CategoryPie.palette[index])
        }
        return CategoryChartEntry(date: Date(), slices: slices, spent: 10_000, currencyCode: "INR", hideValues: false, isSetUp: true)
    }
}

struct CategoryChartWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CategoryChartEntry

    private var total: Double { entry.slices.reduce(0) { $0 + $1.amount } }

    private func share(_ slice: CategorySlice) -> String {
        guard total > 0 else { return "" }
        return "\(Int((slice.amount / total * 100).rounded()))%"
    }

    private var center: String {
        if entry.hideValues { return entry.slices.first.map(share) ?? "" }
        return Format.money(entry.spent, entry.currencyCode)
    }

    var body: some View {
        Group {
            if !entry.isSetUp {
                Text("Set up Hisaab")
            } else if entry.slices.isEmpty {
                Text("No spending this cycle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if family == .systemSmall {
                donut
            } else {
                HStack(spacing: 16) {
                    donut
                    legend
                }
            }
        }
        .widgetBackground(family)
    }

    private var donut: some View {
        ZStack {
            CategoryDonut(slices: entry.slices)
            Text(center)
                .font(.caption.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 24)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(entry.slices.prefix(6))) { slice in
                HStack(spacing: 6) {
                    Circle()
                        .fill(slice.color)
                        .frame(width: 8, height: 8)
                    Text(slice.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.hideValues ? share(slice) : Format.money(Decimal(slice.amount), entry.currencyCode))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct HisaabCategoryChartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HisaabCategoryChartWidget", provider: CategoryChartProvider()) { entry in
            CategoryChartWidgetView(entry: entry)
        }
        .configurationDisplayName("Hisaab (Categories)")
        .description("This cycle's spending by category.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Categorize

/// Entries skipped on the widget. Only a view preference, so it is not part of the ledger.
/// A small file next to the ledger, because that container is known to work after AltStore re-signs the app.
enum WidgetSkips {
    private static var url: URL {
        AppGroup.ledgerURL.deletingLastPathComponent().appendingPathComponent("widget-skips.json")
    }

    static var ids: Set<String> {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    static func save(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(ids).sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Runs in the widget process when a category button is tapped. Tapping the category that was assigned
/// automatically confirms it: it becomes the user's choice and trains predictions.
struct CategorizeSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Categorize Spend"
    static let isDiscoverable = false

    @Parameter(title: "Spend")
    var spendID: String
    @Parameter(title: "Category")
    var categoryID: String

    init() {}

    init(spendID: UUID, categoryID: UUID) {
        self.spendID = spendID.uuidString
        self.categoryID = categoryID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let spend = UUID(uuidString: spendID), let category = UUID(uuidString: categoryID) {
            try AppGroup.store.update { $0.setCategory(category, for: [spend]) }
        }
        // The category can change how an entry counts (a card bill), so every widget reloads.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct SkipSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Spend"
    static let isDiscoverable = false

    @Parameter(title: "Spend")
    var spendID: String

    init() {}

    init(spendID: UUID) {
        self.spendID = spendID.uuidString
    }

    func perform() async throws -> some IntentResult {
        // Only ids still waiting for review, so the list doesn't grow forever.
        let queue = Set(AppGroup.store.load().reviewQueue.map(\.id.uuidString))
        var skipped = WidgetSkips.ids.intersection(queue)
        skipped.insert(spendID)
        WidgetSkips.save(skipped)
        WidgetCenter.shared.reloadTimelines(ofKind: "HisaabCategorizeWidget")
        return .result()
    }
}

/// Shows the skipped entries again.
struct ResetSkipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Skipped Spends"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        WidgetSkips.save([])
        WidgetCenter.shared.reloadTimelines(ofKind: "HisaabCategorizeWidget")
        return .result()
    }
}

struct CategorizeEntry: TimelineEntry {
    let date: Date
    let spend: Spend?
    /// The category assigned automatically (learned or by a rule), shown highlighted. Nil = uncategorized.
    let assignedID: UUID?
    /// Entries in the review queue that are not skipped, including this one.
    let remaining: Int
    let skipped: Int
    /// The assigned category first, then suggestions, then the most used.
    let options: [SpendCategory]
    let currencyCode: String
    let hideValues: Bool
}

struct CategorizeProvider: TimelineProvider {
    private static let maxOptions = 10

    func placeholder(in context: Context) -> CategorizeEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (CategorizeEntry) -> Void) {
        completion(context.isPreview ? Self.sample : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CategorizeEntry>) -> Void) {
        // Reloaded whenever a spend is logged, categorized or skipped.
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> CategorizeEntry {
        let ledger = AppGroup.store.load()
        let queue = ledger.reviewQueue
        let skippedIDs = WidgetSkips.ids
        let waiting = queue.filter { !skippedIDs.contains($0.id.uuidString) }
        let spend = waiting.first
        let assignedID = spend?.categoryID

        let all = ledger.categoriesByUse
        var firstIDs: [UUID] = assignedID.map { [$0] } ?? []
        if let spend, let prediction = spend.prediction ?? ledger.categoryPrediction(for: spend) {
            let assigned = firstIDs
            firstIDs.append(contentsOf: prediction.candidates.map(\.categoryID).filter { !assigned.contains($0) })
        }
        let first = firstIDs.compactMap { id in all.first { $0.id == id } }
        let options = first + all.filter { !firstIDs.contains($0.id) }

        return CategorizeEntry(date: Date(), spend: spend, assignedID: assignedID, remaining: waiting.count,
                               skipped: queue.count - waiting.count, options: Array(options.prefix(Self.maxOptions)),
                               currencyCode: ledger.config?.currencyCode ?? "INR", hideValues: ledger.settings.hideValues)
    }

    private static var sample: CategorizeEntry {
        let options = ["Food", "Travel", "Bills", "Home"].map { SpendCategory(name: $0) }
        return CategorizeEntry(date: Date(), spend: Spend(amount: 350, merchant: "Merchant"), assignedID: options[0].id,
                               remaining: 3, skipped: 0, options: options, currencyCode: "INR", hideValues: false)
    }
}

struct CategorizeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CategorizeEntry

    var body: some View {
        Group {
            if let spend = entry.spend, !entry.options.isEmpty {
                if family == .systemLarge {
                    VStack(alignment: .leading, spacing: 12) {
                        details(spend)
                        buttons(spend, limit: 10)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 12) {
                        details(spend)
                        buttons(spend, limit: 4)
                    }
                }
            } else if entry.spend != nil {
                message("Create a category in Hisaab first", systemImage: "tag")
            } else if entry.skipped > 0 {
                VStack(spacing: 8) {
                    message("\(entry.skipped) skipped", systemImage: "forward")
                    Button(intent: ResetSkipsIntent()) {
                        Text("Show again")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                message("All caught up", systemImage: "checkmark.circle")
            }
        }
        .widgetBackground(family)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }

    private func details(_ spend: Spend) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.assignedID == nil ? "\(entry.remaining) to review" : "\(entry.remaining) to review · tap to confirm")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if !entry.hideValues {
                Text(Format.money(spend.amount, entry.currencyCode))
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(spend.merchant ?? spend.note ?? "Spend")
                .font(.subheadline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(spend.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(intent: SkipSpendIntent(spendID: spend.id)) {
                HStack(spacing: 4) {
                    Image(systemName: "forward")
                    Text("Skip")
                }
                .font(.caption)
                .frame(minHeight: 28)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(_ spend: Spend, limit: Int) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(Array(entry.options.prefix(limit))) { category in
                let isAssigned = category.id == entry.assignedID
                let button = Button(intent: CategorizeSpendIntent(spendID: spend.id, categoryID: category.id)) {
                    HStack(spacing: 3) {
                        if isAssigned {
                            Image(systemName: "checkmark")
                        }
                        Text(category.name)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                if isAssigned {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct HisaabCategorizeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HisaabCategorizeWidget", provider: CategorizeProvider()) { entry in
            CategorizeWidgetView(entry: entry)
        }
        .configurationDisplayName("Hisaab (Categorize)")
        .description("Categorize your latest spends with one tap, and confirm or fix the ones Hisaab assigned.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
