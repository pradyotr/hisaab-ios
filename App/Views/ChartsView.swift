import Charts
import SwiftUI
import BudgetCore

/// Saved (green, above zero) or exceeded (red, below zero), per day or per cycle.
struct ChartsView: View {
    @Environment(LedgerModel.self) private var model
    @State private var scope: Scope = .daily

    enum Scope: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case monthly = "Monthly"
        var id: Self { self }
    }

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
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Trends")
        }
    }

    private func dailyChart(_ engine: BudgetEngine) -> some View {
        let now = Date()
        let days = engine.dayStatuses(for: engine.cycle(containing: now),
                                      transactions: model.ledger.transactions, through: now)
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Saved", day.difference.doubleValue))
                        .foregroundStyle(Format.color(forDifference: day.difference))
                }
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day())
                }
            }
            .frame(height: 280)

            Text("Each bar is that day's budget minus that day's spend. Daily bars do not add up to the monthly total, because every day's budget is recalculated from what is left.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func monthlyChart(_ engine: BudgetEngine) -> some View {
        let cycles = engine.cycleSummaries(transactions: model.ledger.transactions, upTo: Date())
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(cycles) { cycle in
                    BarMark(x: .value("Cycle", cycle.cycle.start, unit: .month),
                            y: .value("Saved", cycle.difference.doubleValue))
                        .foregroundStyle(Format.color(forDifference: cycle.difference))
                }
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .frame(height: 280)

            Text("Spend cap minus total spent, per budget cycle. The current cycle is still running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
