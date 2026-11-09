import Charts
import SwiftUI
import BudgetCore

/// Saved (green, above zero) or exceeded (red, below zero), per day or per cycle.
/// Tap a bar to see its numbers. Tap it again, or tap an empty area, to hide them.
struct ChartsView: View {
    @Environment(LedgerModel.self) private var model
    @State private var scope: Scope = .daily
    @State private var selectedDay: Date?
    @State private var selectedCycle: Date?

    enum Scope: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case monthly = "Monthly"
        case categories = "Categories"
        var id: Self { self }
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
                    case .daily: dailyChart(engine)
                    case .monthly: monthlyChart(engine)
                    case .categories: CategoryBreakdownView(engine: engine)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Trends")
        }
    }

    // MARK: Daily

    private func dailyChart(_ engine: BudgetEngine) -> some View {
        let now = Date()
        let days = engine.dayStatuses(for: engine.cycle(containing: now),
                                      transactions: model.ledger.transactions, through: now)
        let selected = days.first { $0.date == selectedDay }
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Saved", day.difference.doubleValue))
                        .foregroundStyle(Format.color(forDifference: day.difference))
                        .opacity(selected == nil || selected?.date == day.date ? 1 : 0.35)
                }
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(.secondary)
                if let selected {
                    RuleMark(x: .value("Day", selected.date, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            dayTooltip(selected)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .chartOverlay { proxy in
                tapCatcher(proxy) { date in
                    let hit = days.first { engine.calendar.isDate($0.date, inSameDayAs: date) }?.date
                    selectedDay = (hit == selectedDay) ? nil : hit
                }
            }
            .frame(height: 280)

            Text("Tap a bar to see its numbers. Each bar is that day's budget minus that day's spend. Daily bars do not add up to the monthly total, because every day's budget is recalculated from what is left.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dayTooltip(_ day: DayStatus) -> some View {
        ChartTooltip(
            title: day.date.formatted(.dateTime.day().month(.abbreviated)),
            difference: day.difference,
            detail: "\(Format.money(day.spent, currencyCode)) of \(Format.money(day.budget, currencyCode))",
            percent: Format.percent(day.utilisation),
            currencyCode: currencyCode
        )
    }

    // MARK: Monthly

    private func monthlyChart(_ engine: BudgetEngine) -> some View {
        let cycles = engine.cycleSummaries(transactions: model.ledger.transactions, upTo: Date())
        let selected = cycles.first { $0.cycle.start == selectedCycle }
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(cycles) { cycle in
                    BarMark(x: .value("Cycle", cycle.cycle.start, unit: .month),
                            y: .value("Saved", cycle.difference.doubleValue))
                        .foregroundStyle(Format.color(forDifference: cycle.difference))
                        .opacity(selected == nil || selected?.cycle.start == cycle.cycle.start ? 1 : 0.35)
                }
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(.secondary)
                if let selected {
                    RuleMark(x: .value("Cycle", selected.cycle.start, unit: .month))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            cycleTooltip(selected)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartOverlay { proxy in
                tapCatcher(proxy) { date in
                    let hit = cycles.first {
                        engine.calendar.isDate($0.cycle.start, equalTo: date, toGranularity: .month)
                    }?.cycle.start
                    selectedCycle = (hit == selectedCycle) ? nil : hit
                }
            }
            .frame(height: 280)

            Text("Tap a bar to see its numbers. Spend cap minus total spent, per budget cycle. The current cycle is still running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cycleTooltip(_ summary: CycleSummary) -> some View {
        let first = summary.cycle.start.formatted(.dateTime.day().month(.abbreviated))
        let last = (summary.cycle.days.last ?? summary.cycle.start).formatted(.dateTime.day().month(.abbreviated))
        return ChartTooltip(
            title: "\(first) – \(last)",
            difference: summary.difference,
            detail: "\(Format.money(summary.spent, currencyCode)) of \(Format.money(summary.cap, currencyCode))",
            percent: Format.percent(summary.utilisation),
            currencyCode: currencyCode
        )
    }

    // MARK: Tap handling

    /// Clear layer over the chart that turns a tap into the date under the finger.
    private func tapCatcher(_ proxy: ChartProxy, onTap: @escaping (Date) -> Void) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard let plotFrame = proxy.plotFrame else { return }
                    let x = location.x - geo[plotFrame].origin.x
                    if let date: Date = proxy.value(atX: x) {
                        onTap(date)
                    }
                }
        }
    }
}

/// Small card shown above a tapped bar.
private struct ChartTooltip: View {
    let title: String
    let difference: Decimal
    let detail: String
    let percent: String
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.bold())
            Text("\(difference >= 0 ? "Saved" : "Exceeded") \(Format.money(abs(difference), currencyCode))")
                .font(.caption)
                .foregroundStyle(Format.color(forDifference: difference))
            Text("Spent \(detail)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(percent) used")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}
