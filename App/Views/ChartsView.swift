import Charts
import SwiftUI
import UIKit
import BudgetCore

/// Each day's budget (dashed baseline) against what was spent that day (solid line), over a chosen period.
/// The gap is red where spent is above the budget, green where it is below.
/// Tap a point to see its numbers. Tap it again to hide them.
struct ChartsView: View {
    @Environment(LedgerModel.self) private var model
    @State private var scope: Scope = .budget
    @State private var period: Period = .oneMonth
    @State private var selectedDay: Date?

    enum Scope: String, CaseIterable, Identifiable {
        case budget = "Budget"
        case categories = "Categories"
        var id: Self { self }
    }

    enum Period: String, CaseIterable, Identifiable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case all = "All"
        var id: Self { self }

        var months: Int? {
            switch self {
            case .oneMonth: return 1
            case .threeMonths: return 3
            case .sixMonths: return 6
            case .oneYear: return 12
            case .all: return nil
            }
        }
    }

    private var currencyCode: String { model.config?.currencyCode ?? "INR" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if let engine = model.engine {
                    switch scope {
                    case .budget: budgetChart(engine)
                    case .categories: CategoryBreakdownView(engine: engine)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Trends")
            .onChange(of: period) { _, _ in selectedDay = nil }
        }
    }

    /// The period's first day, but never before the cycle of the first entry (no empty months of "saved").
    private func startDate(_ engine: BudgetEngine, now: Date) -> Date {
        let earliest = model.ledger.transactions.map(\.date).min() ?? now
        let firstCycle = engine.cycle(containing: min(earliest, now)).start
        guard let months = period.months,
              let start = engine.calendar.date(byAdding: .month, value: -months, to: now) else { return firstCycle }
        return max(engine.calendar.startOfDay(for: start), firstCycle)
    }

    private func budgetChart(_ engine: BudgetEngine) -> some View {
        let now = Date()
        let start = startDate(engine, now: now)
        let days = engine.dayStatuses(transactions: model.ledger.transactions, from: start, through: now)
        let points = days.map { BudgetPoint(date: $0.date, budget: $0.budget.doubleValue, spent: $0.spent.doubleValue) }
        let span = (days.last?.date ?? now).timeIntervalSince(days.first?.date ?? now)
        return VStack(alignment: .leading, spacing: 10) {
            BudgetLineChart(points: points, selected: selectedDay, axis: axis(spansYears: span > 330 * 86_400),
                            onSelect: { selectedDay = $0 }) { date in
                if let day = days.first(where: { $0.date == date }) {
                    ChartTooltip(title: day.date.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits)),
                                 budget: day.budget, spent: day.spent, currencyCode: currencyCode)
                }
            }
            .frame(height: 300)

            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            BudgetChartLegend()
            Text("Tap the chart to see a day's numbers. The dashed blue line is each day's budget. The solid line is what you spent that day: red above the budget, green below. Every day's budget is recalculated from what is left of its cycle's spend cap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func axis(spansYears: Bool) -> BudgetChartAxis {
        switch period {
        case .oneMonth:
            return BudgetChartAxis(values: .stride(by: .day, count: 7), format: .dateTime.day().month(.abbreviated))
        case .threeMonths, .sixMonths:
            return BudgetChartAxis(values: .stride(by: .month), format: .dateTime.month(.abbreviated))
        case .oneYear:
            return BudgetChartAxis(values: .stride(by: .month, count: 2), format: .dateTime.month(.abbreviated))
        case .all:
            return BudgetChartAxis(values: .automatic(desiredCount: 5),
                             format: spansYears ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated))
        }
    }
}

struct BudgetChartAxis {
    let values: AxisMarkValues
    let format: Date.FormatStyle
}

// MARK: - Line chart

struct BudgetPoint: Identifiable {
    let date: Date
    let budget: Double
    let spent: Double
    var id: Date { date }
}

/// Budget as a dashed blue baseline. Spent as a solid line, red where it is above the budget, green below.
private struct BudgetLineChart<Tooltip: View>: View {
    let points: [BudgetPoint]
    let selected: Date?
    let axis: BudgetChartAxis
    let onSelect: (Date?) -> Void
    @ViewBuilder let tooltip: (Date) -> Tooltip

    /// One point of the spent line. Each run of over (or under) points is its own series, so it gets one colour.
    private struct SpentPoint: Identifiable {
        let id: Int
        let segment: Int
        let date: Date
        let spent: Double
        let isOver: Bool
    }

    /// The spent line cut into runs of one colour. A run ends where the lines cross; the crossing point is
    /// added to both runs, so the colour changes exactly there and the line has no gap.
    private var spentLine: [SpentPoint] {
        var points: [(date: Date, budget: Double, spent: Double)] = []
        for (index, point) in self.points.enumerated() {
            if index > 0 {
                let previous = self.points[index - 1]
                let before = previous.spent - previous.budget
                let after = point.spent - point.budget
                if (before > 0 && after < 0) || (before < 0 && after > 0) {
                    let t = before / (before - after)
                    let date = previous.date.addingTimeInterval(point.date.timeIntervalSince(previous.date) * t)
                    let value = previous.budget + (point.budget - previous.budget) * t
                    points.append((date, value, value))
                }
            }
            points.append((point.date, point.budget, point.spent))
        }

        var result: [SpentPoint] = []
        var segment = 0
        var segmentIsOver: Bool?
        for index in points.indices {
            let point = points[index]
            // The colour of the stretch from this point to the next (both sides are on the same side of the budget).
            let next = index + 1 < points.count ? points[index + 1] : point
            let isOver = (point.spent - point.budget) + (next.spent - next.budget) > 0
            if let current = segmentIsOver, current != isOver {
                // Close the run at this point and start the next run from the same point.
                result.append(SpentPoint(id: result.count, segment: segment, date: point.date, spent: point.spent, isOver: current))
                segment += 1
            }
            segmentIsOver = isOver
            result.append(SpentPoint(id: result.count, segment: segment, date: point.date, spent: point.spent, isOver: isOver))
        }
        return result
    }

    private var selectedPoint: BudgetPoint? { points.first { $0.date == selected } }

    var body: some View {
        Chart {
            ForEach(spentLine) { point in
                LineMark(x: .value("Date", point.date), y: .value("Amount", point.spent),
                         series: .value("Series", "Spent \(point.segment)"))
                    .foregroundStyle(point.isOver ? BudgetChartColors.over : BudgetChartColors.under)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            // The budget line goes on top of a solid line in the background colour. The dash gaps then show
            // the background instead of the spent line, so it stays readable over a year of busy data.
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Amount", point.budget),
                         series: .value("Series", "Budget backing"))
                    .foregroundStyle(BudgetChartColors.background)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Amount", point.budget),
                         series: .value("Series", "Budget"))
                    .foregroundStyle(BudgetChartColors.budget)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
            if points.count == 1, let point = points.first {
                PointMark(x: .value("Date", point.date), y: .value("Amount", point.spent))
                    .foregroundStyle(point.spent > point.budget ? BudgetChartColors.over : BudgetChartColors.under)
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Date", point.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(point.date)
                    }
                PointMark(x: .value("Date", point.date), y: .value("Amount", point.budget))
                    .foregroundStyle(BudgetChartColors.budget)
                    .symbolSize(50)
                PointMark(x: .value("Date", point.date), y: .value("Amount", point.spent))
                    .foregroundStyle(point.spent > point.budget ? BudgetChartColors.over : BudgetChartColors.under)
                    .symbolSize(70)
            }
        }
        .chartXAxis {
            AxisMarks(values: axis.values) { _ in
                AxisGridLine()
                AxisValueLabel(format: axis.format)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geo[plotFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        let nearest = points.min {
                            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                        }?.date
                        onSelect(nearest == selected ? nil : nearest)
                    }
            }
        }
    }
}

/// Brighter than the system red and green, so a thin line still stands out. Blue stays apart from both.
private enum BudgetChartColors {
    static let over = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let under = Color(red: 0.13, green: 0.86, blue: 0.40)
    static let budget = Color.blue
    static let background = Color(uiColor: .systemBackground)
}

private struct BudgetChartLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(DashedLine().stroke(style: StrokeStyle(lineWidth: 2, dash: [4, 2])).frame(width: 16, height: 2),
                 "Budget", BudgetChartColors.budget)
            item(DashedLine().stroke(lineWidth: 2).frame(width: 16, height: 2), "Spent over", BudgetChartColors.over)
            item(DashedLine().stroke(lineWidth: 2).frame(width: 16, height: 2), "Spent under", BudgetChartColors.under)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func item(_ symbol: some View, _ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            symbol.foregroundStyle(color)
            Text(name)
        }
    }
}

/// A horizontal line through the middle, for the legend.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Card shown above the tapped point: the result, then budget and spent.
/// A solid card (not a material), so it looks the same whatever part of the chart is behind it.
private struct ChartTooltip: View {
    let title: String
    let budget: Decimal
    let spent: Decimal
    let currencyCode: String

    private var difference: Decimal { budget - spent }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(difference >= 0 ? "Saved" : "Exceeded") \(Format.money(abs(difference), currencyCode))")
                .font(.subheadline.bold())
                .foregroundStyle(difference >= 0 ? BudgetChartColors.under : BudgetChartColors.over)
            Divider()
            row("Budget", budget)
            row("Spent", spent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        )
        .environment(\.colorScheme, .light)
        .fixedSize()
    }

    private func row(_ name: String, _ value: Decimal) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(Format.money(value, currencyCode))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.caption)
    }
}
