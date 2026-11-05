import XCTest
@testable import BudgetCore

final class CountingTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func engine() -> BudgetEngine {
        BudgetEngine(config: BudgetConfig(monthlyIncome: 50_000, goal: .save(20_000)), calendar: calendar)
    }

    private func cardSpend(_ amount: Decimal, _ d: Date, card: String? = nil) -> Spend {
        Spend(amount: amount, date: d, kind: .spend, account: .creditCard, card: card)
    }

    private func bill(_ amount: Decimal, _ d: Date, card: String? = nil) -> Spend {
        Spend(amount: amount, date: d, kind: .cardBill, card: card)
    }

    // MARK: Basic kinds

    func testSpendCountsInFull() {
        let a = Spend(amount: 100, date: date(2026, 11, 1))
        XCTAssertEqual(Counting.countedAmounts([a]), [a.id: 100])
        XCTAssertEqual(Counting.countedEntries([a]), [a])
    }

    func testSavingsCountsZeroButIsInvested() {
        let sip = Spend(amount: 5_000, date: date(2026, 11, 5), kind: .savings)
        XCTAssertEqual(Counting.countedAmounts([sip])[sip.id], 0)
        XCTAssertTrue(Counting.countedEntries([sip]).isEmpty)
        XCTAssertEqual(Counting.investedEntries([sip]).map(\.amount), [5_000])
    }

    func testRefundAndCashbackCountNegative() {
        let refund = Spend(amount: 300, date: date(2026, 11, 4), kind: .refund)
        let cashback = Spend(amount: 25, date: date(2026, 11, 4), kind: .cashback)
        let counted = Counting.countedAmounts([refund, cashback])
        XCTAssertEqual(counted[refund.id], -300)
        XCTAssertEqual(counted[cashback.id], -25)
    }

    func testOtherCreditAndExcludedCountZero() {
        let salary = Spend(amount: 50_000, date: date(2026, 11, 1), kind: .otherCredit)
        let selfTransfer = Spend(amount: 10_000, date: date(2026, 11, 2), excluded: true)
        XCTAssertTrue(Counting.countedEntries([salary, selfTransfer]).isEmpty)
    }

    // MARK: Reversals

    func testLinkedReversalCancelsOriginal() {
        let failed = Spend(amount: 500, date: date(2026, 11, 3))
        let reversal = Spend(amount: 500, date: date(2026, 11, 4), kind: .reversal, reverses: failed.id)
        let counted = Counting.countedAmounts([failed, reversal])
        XCTAssertEqual(counted[failed.id], 0)
        XCTAssertEqual(counted[reversal.id], 0)
    }

    func testPartialReversalLeavesTheRest() {
        let original = Spend(amount: 800, date: date(2026, 11, 3))
        let reversal = Spend(amount: 300, date: date(2026, 11, 4), kind: .reversal, reverses: original.id)
        XCTAssertEqual(Counting.countedAmounts([original, reversal])[original.id], 500)
    }

    func testUnlinkedReversalCountsLikeARefund() {
        let reversal = Spend(amount: 500, date: date(2026, 11, 4), kind: .reversal)
        XCTAssertEqual(Counting.countedAmounts([reversal])[reversal.id], -500)
    }

    func testReversalOfSavingsReducesInvested() {
        let sip = Spend(amount: 2_000, date: date(2026, 11, 5), kind: .savings)
        let reversal = Spend(amount: 2_000, date: date(2026, 11, 6), kind: .reversal, reverses: sip.id)
        XCTAssertTrue(Counting.investedEntries([sip, reversal]).isEmpty)
    }

    // MARK: Credit card matching

    func testBillCoveredByCardSpendsCountsOnlyTheRemainder() {
        let s1 = cardSpend(1_000, date(2026, 10, 5), card: "5678")
        let s2 = cardSpend(2_000, date(2026, 10, 20), card: "5678")
        let b = bill(3_500, date(2026, 11, 2), card: "5678")
        let counted = Counting.countedAmounts([b, s1, s2])
        XCTAssertEqual(counted[s1.id], 1_000)
        XCTAssertEqual(counted[s2.id], 2_000)
        XCTAssertEqual(counted[b.id], 500) // interest / untracked purchase
    }

    func testBankSpendsAreNotCoveredByABill() {
        let bankSpend = Spend(amount: 1_000, date: date(2026, 10, 5))
        let b = bill(1_000, date(2026, 11, 2))
        XCTAssertEqual(Counting.countedAmounts([bankSpend, b])[b.id], 1_000)
    }

    func testPartialPaymentLeavesRestForNextBill() {
        let s1 = cardSpend(5_000, date(2026, 10, 5))
        let b1 = bill(2_000, date(2026, 11, 2))
        let b2 = bill(4_000, date(2026, 12, 2))
        let counted = Counting.countedAmounts([s1, b1, b2])
        XCTAssertEqual(counted[b1.id], 0)
        XCTAssertEqual(counted[b2.id], 1_000) // 3,000 of s1 was still open
    }

    func testBillDoesNotCoverLaterSpends() {
        let b = bill(1_000, date(2026, 11, 2))
        let later = cardSpend(1_000, date(2026, 11, 3))
        let counted = Counting.countedAmounts([b, later])
        XCTAssertEqual(counted[b.id], 1_000)
        XCTAssertEqual(counted[later.id], 1_000)
    }

    func testSpendAndBillAtSameTimeIsCovered() {
        let now = date(2026, 11, 2)
        let s = cardSpend(700, now)
        let b = bill(700, now)
        XCTAssertEqual(Counting.countedAmounts([b, s])[b.id], 0)
    }

    func testBillOnlyCoversItsOwnCard() {
        let cardA = cardSpend(1_000, date(2026, 10, 5), card: "1111")
        let cardB = cardSpend(2_000, date(2026, 10, 6), card: "2222")
        let unknown = cardSpend(300, date(2026, 10, 7))
        let billA = bill(1_500, date(2026, 11, 2), card: "XX1111")
        let billAny = bill(2_000, date(2026, 11, 3))
        let counted = Counting.countedAmounts([cardA, cardB, unknown, billA, billAny])
        XCTAssertEqual(counted[billA.id], 200)  // covers card A (1,000) + the unknown-card spend (300)
        XCTAssertEqual(counted[billAny.id], 0)  // no card named: covers card B
    }

    func testCardRefundBeforeBillIsNotCountedTwice() {
        // Spend 1,000 on the card, full refund to the card, bill is 0 (no SMS): net 0.
        let s = cardSpend(1_000, date(2026, 10, 5))
        let refund = Spend(amount: 1_000, date: date(2026, 10, 9), kind: .refund, account: .creditCard)
        let later = cardSpend(3_000, date(2026, 10, 20))
        let b = bill(3_000, date(2026, 11, 2))
        let counted = Counting.countedAmounts([s, refund, later, b])
        XCTAssertEqual(counted[refund.id], -1_000)
        XCTAssertEqual(counted[b.id], 0) // the refunded 1,000 is not still "open" and does not hide bill money
        XCTAssertEqual(Counting.countedEntries([s, refund, later, b]).reduce(Decimal(0)) { $0 + $1.amount }, 3_000)
    }

    func testCardRefundAfterBillReducesNextCharges() {
        // Bill paid, then a refund lands on the card: the next bill is smaller by the refund.
        let s1 = cardSpend(1_000, date(2026, 10, 5))
        let b1 = bill(1_000, date(2026, 11, 2))
        let refund = Spend(amount: 400, date: date(2026, 11, 5), kind: .refund, account: .creditCard)
        let s2 = cardSpend(2_000, date(2026, 11, 10))
        let b2 = bill(1_600, date(2026, 12, 2))
        let counted = Counting.countedAmounts([s1, b1, refund, s2, b2])
        XCTAssertEqual(counted[b1.id], 0)
        XCTAssertEqual(counted[refund.id], -400)
        XCTAssertEqual(counted[b2.id], 0) // 2,000 − 400 credit = 1,600 open, fully covered
    }

    func testCardCashbackReducesTheBill() {
        let s = cardSpend(2_000, date(2026, 10, 5))
        let cashback = Spend(amount: 50, date: date(2026, 10, 25), kind: .cashback, account: .creditCard)
        let b = bill(1_950, date(2026, 11, 2))
        let total = Counting.countedEntries([s, cashback, b]).reduce(Decimal(0)) { $0 + $1.amount }
        XCTAssertEqual(total, 1_950)
    }

    func testReversedCardSpendIsNotOpenForTheBill() {
        let failed = cardSpend(500, date(2026, 10, 5))
        let reversal = Spend(amount: 500, date: date(2026, 10, 6), kind: .reversal, account: .creditCard, reverses: failed.id)
        let b = bill(500, date(2026, 11, 2))
        XCTAssertEqual(Counting.countedAmounts([failed, reversal, b])[b.id], 500) // a real 500 that was not tracked
    }

    func testSavingsOnCardIsOpenForTheBillButNotSpent() {
        let gold = Spend(amount: 3_000, date: date(2026, 10, 5), kind: .savings, account: .creditCard)
        let b = bill(3_000, date(2026, 11, 2))
        XCTAssertTrue(Counting.countedEntries([gold, b]).isEmpty)
    }

    func testExcludedCardSpendStillCoveredByBill() {
        let excluded = Spend(amount: 800, date: date(2026, 10, 5), account: .creditCard, excluded: true)
        let b = bill(800, date(2026, 11, 2))
        XCTAssertTrue(Counting.countedEntries([excluded, b]).isEmpty)
    }

    func testNormalizedCard() {
        XCTAssertEqual(Counting.normalizedCard("XX5678"), "5678")
        XCTAssertEqual(Counting.normalizedCard("card 12345678"), "5678")
        XCTAssertEqual(Counting.normalizedCard("12"), "12")
        XCTAssertNil(Counting.normalizedCard("XX"))
        XCTAssertNil(Counting.normalizedCard(nil))
    }

    // MARK: Budget math

    func testCardSpendsAreNotCountedTwiceInTheBudget() {
        let e = engine() // cap 30,000, 30 days in November
        let txs = [
            cardSpend(2_000, date(2026, 10, 20)),
            cardSpend(600, date(2026, 11, 1)),
            Spend(amount: 400, date: date(2026, 11, 1)),
            bill(2_700, date(2026, 11, 2)), // covers 2,600, 100 counts
        ]
        let snap = e.snapshot(at: date(2026, 11, 2), transactions: txs)
        XCTAssertEqual(snap.day.spent, 100)
        XCTAssertEqual(snap.cycle.spent, 1_100)
        // Day 2 budget: (30000 - 1000) / 29
        XCTAssertEqual(snap.day.budget, 1_000)

        let summaries = e.cycleSummaries(transactions: txs, upTo: date(2026, 11, 2))
        XCTAssertEqual(summaries.map(\.spent), [2_000, 1_100]) // October keeps its card spend
    }

    func testRefundRaisesLaterBudgetsAndSavingsAreSeparate() {
        let e = engine()
        let txs = [
            Spend(amount: 2_000, date: date(2026, 11, 1)),
            Spend(amount: 1_000, date: date(2026, 11, 2), kind: .refund),
            Spend(amount: 5_000, date: date(2026, 11, 2), kind: .savings),
        ]
        let snap = e.snapshot(at: date(2026, 11, 3), transactions: txs)
        XCTAssertEqual(snap.cycle.spent, 1_000)
        XCTAssertEqual(snap.cycle.invested, 5_000)
        // Day 3 budget: (30000 - 2000 + 1000) / 28
        XCTAssertEqual(snap.day.budget.rounded(scale: 2), Decimal(string: "1035.71"))

        let days = e.dayStatuses(for: e.cycle(containing: date(2026, 11, 3)), transactions: txs, through: date(2026, 11, 3))
        XCTAssertEqual(days[1].spent, -1_000)
    }

    func testCycleWithOnlySavingsStillListed() {
        let txs = [Spend(amount: 5_000, date: date(2026, 9, 5), kind: .savings)]
        let summaries = engine().cycleSummaries(transactions: txs, upTo: date(2026, 11, 3))
        XCTAssertEqual(summaries.map(\.invested), [5_000, 0, 0])
    }
}
