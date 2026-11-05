import Foundation

/// One budget cycle (normally a month), as a list of calendar days.
public struct BudgetCycle: Equatable, Sendable {
    /// Start of the first day.
    public let start: Date
    /// Start of the day after the last day (exclusive).
    public let end: Date
    /// Start of each day in the cycle.
    public let days: [Date]

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

public struct DayStatus: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    /// That day's budget, fixed at the start of the day: remaining cycle money / days left (including that day).
    public let budget: Decimal
    public let spent: Decimal
    /// Cycle money left at the start of the day (can be negative after overspending).
    public let remainingBeforeDay: Decimal

    /// Positive = saved vs. the day's budget (green), negative = exceeded (red).
    public var difference: Decimal { budget - spent }

    /// spent / budget. Nil when the budget is zero (cycle money already used up).
    public var utilisation: Double? {
        budget > 0 ? (spent / budget).doubleValue : nil
    }
}

public struct CycleSummary: Equatable, Sendable, Identifiable {
    public var id: Date { cycle.start }
    public let cycle: BudgetCycle
    public let cap: Decimal
    /// Spends minus refunds / cashback (see `Counting`). Can be negative in a cycle with only refunds.
    public let spent: Decimal
    /// Money moved into investments (savings entries). Not part of `spent`.
    public var invested: Decimal = 0
    /// Positive = under the cap (green), negative = over (red).
    public var difference: Decimal { cap - spent }

    /// spent / cap. Can go above 1 when the cap is exceeded. Nil when the cap is zero.
    public var utilisation: Double? {
        cap > 0 ? (spent / cap).doubleValue : nil
    }
}

/// Everything the widget and the Today screen need.
public struct TodaySnapshot: Equatable, Sendable {
    public let day: DayStatus
    public let cycle: CycleSummary
    public let daysLeftIncludingToday: Int
}

/// Budget math. Pure and deterministic: every value is derived from config + transactions, nothing is stored.
///
/// For day d (0-based) of a cycle with N days and spend cap S:
///   B_d = max(S - spentBefore(d), 0) / (N - d)
/// Underspending raises later daily budgets, overspending lowers them.
/// Note: the sum of daily differences is NOT the cycle difference; the monthly chart uses S - totalSpent.
public struct BudgetEngine: Sendable {
    public let config: BudgetConfig
    public let calendar: Calendar

    public init(config: BudgetConfig, calendar: Calendar = .current) {
        self.config = config
        self.calendar = calendar
    }

    public func cycle(containing date: Date) -> BudgetCycle {
        let startDay = BudgetConfig.clampStartDay(config.cycleStartDay)
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        let dayOfMonth = components.day ?? 1
        components.day = startDay
        var start = calendar.date(from: components) ?? calendar.startOfDay(for: date)
        if dayOfMonth < startDay {
            start = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        }
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        var days: [Date] = []
        var day = start
        while day < end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return BudgetCycle(start: start, end: end, days: days)
    }

    /// Status for each day of `cycle`, stopping after the day that contains `through` (if given).
    /// Pass ALL entries: they are counted first (card bills, refunds, reversals, savings; see `Counting`).
    public func dayStatuses(for cycle: BudgetCycle, transactions: [Spend], through last: Date? = nil) -> [DayStatus] {
        dayStatuses(for: cycle, counted: Counting.countedEntries(transactions), through: last)
    }

    /// Pass ALL entries: they are counted first (see `Counting`).
    public func summary(for cycle: BudgetCycle, transactions: [Spend]) -> CycleSummary {
        summary(for: cycle, Counted(transactions))
    }

    /// Summaries from the cycle of the earliest entry up to the cycle containing `date`.
    /// POC limitation: uses the *current* config for past cycles.
    public func cycleSummaries(transactions: [Spend], upTo date: Date) -> [CycleSummary] {
        let counted = Counted(transactions)
        let current = cycle(containing: date)
        var cycles: [BudgetCycle] = []
        let dates = counted.spent.map(\.date) + counted.invested.map(\.date)
        if let earliest = dates.min(), earliest < current.start {
            var c = cycle(containing: earliest)
            while c.start < current.start {
                cycles.append(c)
                c = cycle(containing: c.end)
            }
        }
        cycles.append(current)
        return cycles.map { summary(for: $0, counted) }
    }

    public func snapshot(at date: Date, transactions: [Spend]) -> TodaySnapshot {
        let counted = Counted(transactions)
        let c = cycle(containing: date)
        let statuses = dayStatuses(for: c, counted: counted.spent, through: date)
        let today = statuses.last
            ?? DayStatus(date: calendar.startOfDay(for: date), budget: 0, spent: 0, remainingBeforeDay: 0)
        return TodaySnapshot(
            day: today,
            cycle: summary(for: c, counted),
            daysLeftIncludingToday: max(c.days.count - max(statuses.count - 1, 0), 0)
        )
    }

    // MARK: On counted entries. Never count twice.

    /// Entries with amounts replaced by what they add to "spent" (signed) and to "invested".
    private struct Counted {
        let spent: [Spend]
        let invested: [Spend]

        init(_ entries: [Spend]) {
            spent = Counting.countedEntries(entries)
            invested = Counting.investedEntries(entries)
        }
    }

    private func dayStatuses(for cycle: BudgetCycle, counted: [Spend], through last: Date?) -> [DayStatus] {
        let inCycle = counted.filter { cycle.contains($0.date) }
        let grouped = Dictionary(grouping: inCycle) { calendar.startOfDay(for: $0.date) }
        let spentByDay = grouped.mapValues { $0.reduce(Decimal(0)) { $0 + $1.amount } }

        let lastDay = last.map { calendar.startOfDay(for: $0) }
        let cap = config.spendCap
        let count = cycle.days.count
        var spentBefore: Decimal = 0
        var result: [DayStatus] = []

        for (index, day) in cycle.days.enumerated() {
            if let lastDay, day > lastDay { break }
            let remaining = cap - spentBefore
            let budget = max(remaining, 0) / Decimal(count - index)
            let spent = spentByDay[day] ?? 0
            result.append(DayStatus(date: day, budget: budget, spent: spent, remainingBeforeDay: remaining))
            spentBefore += spent
        }
        return result
    }

    private func summary(for cycle: BudgetCycle, _ counted: Counted) -> CycleSummary {
        func total(_ entries: [Spend]) -> Decimal {
            entries.filter { cycle.contains($0.date) }.reduce(Decimal(0)) { $0 + $1.amount }
        }
        return CycleSummary(cycle: cycle, cap: config.spendCap, spent: total(counted.spent), invested: total(counted.invested))
    }
}
