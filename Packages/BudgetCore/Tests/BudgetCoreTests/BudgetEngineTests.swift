import XCTest
@testable import BudgetCore

final class BudgetEngineTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func engine(income: Decimal = 50_000, goal: BudgetGoal = .save(20_000), startDay: Int = 1) -> BudgetEngine {
        BudgetEngine(config: BudgetConfig(monthlyIncome: income, goal: goal, cycleStartDay: startDay), calendar: calendar)
    }

    // MARK: Config

    func testGoalConversions() {
        let save = BudgetConfig(monthlyIncome: 50_000, goal: .save(20_000))
        XCTAssertEqual(save.spendCap, 30_000)
        XCTAssertEqual(save.savingsTarget, 20_000)

        let cap = BudgetConfig(monthlyIncome: 50_000, goal: .spendCap(35_000))
        XCTAssertEqual(cap.spendCap, 35_000)
        XCTAssertEqual(cap.savingsTarget, 15_000)

        let tooMuch = BudgetConfig(monthlyIncome: 10_000, goal: .save(20_000))
        XCTAssertEqual(tooMuch.spendCap, 0)
    }

    func testStartDayIsClamped() {
        XCTAssertEqual(BudgetConfig(monthlyIncome: 1, goal: .save(0), cycleStartDay: 31).cycleStartDay, 28)
        XCTAssertEqual(BudgetConfig(monthlyIncome: 1, goal: .save(0), cycleStartDay: 0).cycleStartDay, 1)
    }

    // MARK: Cycles

    func testCalendarMonthCycle() {
        let cycle = engine().cycle(containing: date(2026, 11, 3))
        XCTAssertEqual(cycle.start, date(2026, 11, 1, 0))
        XCTAssertEqual(cycle.end, date(2026, 12, 1, 0))
        XCTAssertEqual(cycle.days.count, 30)
    }

    func testMidMonthCycleBeforeStartDay() {
        let cycle = engine(startDay: 25).cycle(containing: date(2026, 11, 3))
        XCTAssertEqual(cycle.start, date(2026, 10, 25, 0))
        XCTAssertEqual(cycle.end, date(2026, 11, 25, 0))
        XCTAssertEqual(cycle.days.count, 31)
    }

    func testMidMonthCycleOnStartDay() {
        let cycle = engine(startDay: 25).cycle(containing: date(2026, 11, 25, 0))
        XCTAssertEqual(cycle.start, date(2026, 11, 25, 0))
    }

    // MARK: Daily budget rollover

    func testFirstDayBudgetIsCapDividedByDays() {
        let e = engine()
        let status = e.snapshot(at: date(2026, 11, 1), transactions: []).day
        XCTAssertEqual(status.budget, 1_000)
        XCTAssertEqual(status.spent, 0)
        XCTAssertEqual(status.utilisation, 0)
    }

    func testUnderAndOverspendingRollForward() {
        let e = engine()
        let txs = [
            Spend(amount: 400, date: date(2026, 11, 1)),
            Spend(amount: 5_000, date: date(2026, 11, 2)),
        ]
        let days = e.dayStatuses(for: e.cycle(containing: date(2026, 11, 3)), transactions: txs, through: date(2026, 11, 3))
        XCTAssertEqual(days.count, 3)

        XCTAssertEqual(days[0].budget, 1_000)
        XCTAssertEqual(days[0].difference, 600)

        // (30000 - 400) / 29
        XCTAssertEqual(days[1].budget.rounded(scale: 2), Decimal(string: "1020.69"))
        XCTAssertLessThan(days[1].difference, 0)

        // (30000 - 5400) / 28
        XCTAssertEqual(days[2].budget.rounded(scale: 2), Decimal(string: "878.57"))
    }

    func testBudgetNeverNegativeAfterOverspending() {
        let e = engine(income: 1_000, goal: .spendCap(900))
        let txs = [Spend(amount: 2_000, date: date(2026, 11, 1))]
        let day2 = e.snapshot(at: date(2026, 11, 2), transactions: txs).day
        XCTAssertEqual(day2.budget, 0)
        XCTAssertNil(day2.utilisation)
        XCTAssertEqual(day2.remainingBeforeDay, -1_100)
    }

    func testSnapshotDaysLeftAndCycleTotals() {
        let e = engine()
        let txs = [
            Spend(amount: 400, date: date(2026, 11, 1)),
            Spend(amount: 100, date: date(2026, 11, 3)),
            Spend(amount: 999, date: date(2026, 10, 31)), // previous cycle, ignored
        ]
        let snap = e.snapshot(at: date(2026, 11, 3), transactions: txs)
        XCTAssertEqual(snap.daysLeftIncludingToday, 28)
        XCTAssertEqual(snap.day.spent, 100)
        XCTAssertEqual(snap.cycle.spent, 500)
        XCTAssertEqual(snap.cycle.difference, 29_500)
    }

    func testCycleSummariesSpanFromEarliestTransaction() {
        let e = engine()
        let txs = [
            Spend(amount: 31_000, date: date(2026, 9, 15)),
            Spend(amount: 10_000, date: date(2026, 10, 2)),
        ]
        let summaries = e.cycleSummaries(transactions: txs, upTo: date(2026, 11, 3))
        XCTAssertEqual(summaries.map(\.cycle.start), [date(2026, 9, 1, 0), date(2026, 10, 1, 0), date(2026, 11, 1, 0)])
        XCTAssertEqual(summaries.map(\.difference), [-1_000, 20_000, 30_000])
    }

    func testCycleSummariesWithNoTransactions() {
        XCTAssertEqual(engine().cycleSummaries(transactions: [], upTo: date(2026, 11, 3)).count, 1)
    }
}
