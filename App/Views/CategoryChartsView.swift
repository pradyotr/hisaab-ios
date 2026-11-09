import Charts
import SwiftUI
import BudgetCore

/// Spending per category in one cycle, largest first. Tap a category for its trend and spends.
struct CategoryBreakdownView: View {
    @Environment(LedgerModel.self) private var model
    let engine: BudgetEngine
    /// Nil = the current cycle.
    @State private var selectedIndex: Int?

    private var currencyCode: String { model.config?.currencyCode ?? "INR" }

    var body: some View {
        let entries = model.ledger.transactions
        let cycles = engine.cycleSummaries(transactions: entries, upTo: Date()).map(\.cycle)
        let index = min(selectedIndex ?? cycles.count - 1, cycles.count - 1)
        let cycle = cycles[index]
        let totals = engine.categoryTotals(for: cycle, transactions: entries)
        let spent = totals.reduce(Decimal(0)) { $0 + $1.amount }
        let largest = totals.map(\.amount).max() ?? 0
        let names = Dictionary(model.ledger.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(cycle: cycle, spent: spent, index: index, last: cycles.count - 1)
                if totals.isEmpty {
                    ContentUnavailableView("No spending in this cycle", systemImage: "chart.bar")
                }
                CategoryPieChart(totals: totals, categories: model.ledger.categories)
                ForEach(totals) { total in
                    NavigationLink {
                        CategoryDetailView(categoryID: total.categoryID, title: title(total, names), cycle: cycle, engine: engine)
                    } label: {
                        CategoryBarRow(title: title(total, names), amount: total.amount, spent: spent, largest: largest,
                                       isUncategorized: total.categoryID == nil, currencyCode: currencyCode)
                    }
                    .buttonStyle(.plain)
                }
                if totals.contains(where: { $0.categoryID == nil }) {
                    NavigationLink("Categorize spends") { CategorizeFlowView() }
                        .font(.subheadline)
                }
            }
        }
        // The scroll bar would otherwise sit on top of the amounts at the right edge.
        .scrollIndicators(.hidden)
    }

    private func title(_ total: CategoryTotal, _ names: [UUID: String]) -> String {
        total.categoryID.flatMap { names[$0] } ?? "Uncategorized"
    }

    private func header(cycle: BudgetCycle, spent: Decimal, index: Int, last: Int) -> some View {
        HStack {
            Button { selectedIndex = index - 1 } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .accessibilityLabel("Previous cycle")
            Spacer()
            VStack(spacing: 2) {
                Text(Format.money(spent, currencyCode))
                    .font(.title2.bold())
                    .monospacedDigit()
                Text(cycleTitle(cycle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { selectedIndex = index + 1 } label: { Image(systemName: "chevron.right") }
                .disabled(index == last)
                .accessibilityLabel("Next cycle")
        }
    }
}

func cycleTitle(_ cycle: BudgetCycle) -> String {
    let first = cycle.start.formatted(.dateTime.day().month(.abbreviated))
    let last = (cycle.days.last ?? cycle.start).formatted(.dateTime.day().month(.abbreviated))
    return "\(first) – \(last)"
}

/// Share of spending per category, with a legend.
private struct CategoryPieChart: View {
    let totals: [CategoryTotal]
    let categories: [SpendCategory]

    var body: some View {
        let slices = CategoryPie.slices(totals: totals, categories: categories)
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                CategoryDonut(slices: slices)
                    .frame(height: 200)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(slices) { slice in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(slice.color)
                                .frame(width: 10, height: 10)
                            Text(slice.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Share of spending by category: " + slices.map(\.name).joined(separator: ", "))
        }
    }
}

private struct CategoryBarRow: View {
    let title: String
    let amount: Decimal
    let spent: Decimal
    let largest: Decimal
    let isUncategorized: Bool
    let currencyCode: String

    private var fraction: CGFloat {
        guard largest > 0, amount > 0 else { return 0 }
        return CGFloat((amount / largest).doubleValue)
    }

    private var share: String? {
        guard spent > 0, amount > 0 else { return nil }
        return "\(Int(((amount / spent).doubleValue * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let share {
                    Text(share)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(Format.money(amount, currencyCode))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                Capsule()
                    .fill(isUncategorized ? Color.secondary.opacity(0.5) : Color.accentColor)
                    .frame(width: fraction > 0 ? max(geo.size.width * fraction, 6) : 0)
            }
            .frame(height: 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(Format.money(amount, currencyCode))")
    }
}

/// One category: its trend over recent cycles and its spends in the chosen cycle.
struct CategoryDetailView: View {
    @Environment(LedgerModel.self) private var model
    let categoryID: UUID?
    let title: String
    let cycle: BudgetCycle
    let engine: BudgetEngine

    @State private var editing: Spend?

    private var currencyCode: String { model.config?.currencyCode ?? "INR" }

    var body: some View {
        let all = model.ledger.transactions
        let counted = Counting.countedAmounts(all)
        let entries = all.filter { $0.categoryID == categoryID && cycle.contains($0.date) && (counted[$0.id] ?? 0) != 0 }
        let trend = engine.categoryTrend(categoryID: categoryID, transactions: all, upTo: Date())
        List {
            Section("Recent cycles") {
                Chart(trend) { point in
                    BarMark(x: .value("Cycle", point.cycle.start, unit: .month),
                            y: .value("Spent", point.amount.doubleValue))
                        .cornerRadius(4)
                        .foregroundStyle(point.cycle.start == cycle.start ? Color.accentColor : Color.accentColor.opacity(0.35))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 160)
                .padding(.vertical, 4)
            }
            Section(cycleTitle(cycle)) {
                ForEach(entries) { spend in
                    TransactionRow(spend: spend, counted: counted[spend.id], original: nil, currencyCode: currencyCode)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = spend }
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { TransactionEditor(spend: $0) }
    }
}
