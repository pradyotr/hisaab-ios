import XCTest
@testable import BudgetCore

/// A card bill is a spend in the built-in "Credit Card Bill" category (no separate kind).
final class CardBillCategoryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func date(_ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }

    private let billID = SpendCategory.creditCardBillID

    @discardableResult
    private func label(_ ledger: inout Ledger, _ merchant: String, _ amount: Decimal, day: Int, as category: UUID,
                       account: PaymentAccount = .bank) -> Spend {
        let entry = Spend(amount: amount, date: date(day), merchant: merchant, account: account)
        ledger.add(entry, calendar: calendar)
        ledger.setCategory(category, for: [entry.id])
        return entry
    }

    private func saved(_ ledger: Ledger, _ entry: Spend) throws -> Spend {
        try XCTUnwrap(ledger.transactions.first { $0.id == entry.id })
    }

    // MARK: Built-in category

    func testEveryLedgerHasTheBuiltInCategory() {
        XCTAssertEqual(Ledger().categories, [SpendCategory.creditCardBill])
        XCTAssertTrue(SpendCategory.creditCardBill.isBuiltIn)
        XCTAssertFalse(SpendCategory(name: "Food").isBuiltIn)
    }

    func testBuiltInCategoryCanBeRenamedButNotDeleted() {
        var ledger = Ledger()
        let entry = Spend(amount: 10)
        ledger.add(entry)
        ledger.setCategory(billID, for: [entry.id])
        ledger.deleteCategory(billID)
        XCTAssertTrue(ledger.categories.contains { $0.id == billID })
        XCTAssertEqual(ledger.transactions[0].categoryID, billID)
        XCTAssertTrue(ledger.renameCategory(billID, to: "Card bills"))
        XCTAssertEqual(ledger.addCategory(named: "card BILLS")?.id, billID)
    }

    func testEntryCountsAsABillOnlyAsASpendInTheBuiltInCategory() {
        XCTAssertTrue(Spend(amount: 1, categoryID: billID).isCardBill)
        XCTAssertFalse(Spend(amount: 1, kind: .savings, categoryID: billID).isCardBill)
        XCTAssertFalse(Spend(amount: 1, kind: .refund, categoryID: billID).isCardBill)
        XCTAssertFalse(Spend(amount: 1, categoryID: UUID()).isCardBill)
    }

    func testCategoryDecidesHowABillCounts() {
        let charge = Spend(amount: 700, date: date(3), account: .creditCard, card: "1234")
        var bill = Spend(amount: 1_000, date: date(10), merchant: "Card issuer")
        XCTAssertEqual(Counting.countedAmounts([charge, bill])[bill.id], 1_000, "uncategorized: a normal spend")
        bill.categoryID = billID
        XCTAssertEqual(Counting.countedAmounts([charge, bill])[bill.id], 300, "bill: only the untracked part")
        XCTAssertEqual(Counting.countedAmounts([charge, bill])[charge.id], 700)
    }

    // MARK: Migration

    func testOldCardBillKindBecomesTheBuiltInCategory() throws {
        let json = #"""
        {"schemaVersion":3,
         "categories":[{"id":"DB4F63E9-38DF-4E47-8381-1441CBFF4DFE","name":"Food"}],
         "transactions":[
          {"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","amount":"12493","date":10,"kind":"cardBill","account":"bank",
           "card":"1234","sources":{"kind":"user"}},
          {"id":"8C9E6679-7425-40DE-944B-E07FC1F90AE7","amount":"5000","date":5,"kind":"cardBill"},
          {"id":"9C9E6679-7425-40DE-944B-E07FC1F90AE7","amount":"300","date":1,"kind":"spend","account":"creditCard"}
         ]}
        """#
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(json.utf8))
        XCTAssertEqual(ledger.schemaVersion, Ledger.currentSchemaVersion)
        XCTAssertEqual(Set(ledger.categories.map(\.name)), ["Food", "Credit Card Bill"])

        let byUser = try XCTUnwrap(ledger.transactions.first { $0.amount == 12_493 })
        XCTAssertEqual(byUser.kind, .spend)
        XCTAssertEqual(byUser.categoryID, billID)
        XCTAssertEqual(byUser.sources.category, .user, "the user chose the old type, so it trains predictions")
        XCTAssertEqual(byUser.card, "1234")
        XCTAssertTrue(byUser.isCardBill)

        let byRule = try XCTUnwrap(ledger.transactions.first { $0.amount == 5_000 })
        XCTAssertEqual(byRule.categoryID, billID)
        XCTAssertEqual(byRule.sources.category, .rule)

        let spend = try XCTUnwrap(ledger.transactions.first { $0.amount == 300 })
        XCTAssertNil(spend.categoryID)

        // Round trip: the old kind is gone from the file.
        let data = try JSONEncoder().encode(ledger)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("cardBill"))
        XCTAssertEqual(try JSONDecoder().decode(Ledger.self, from: data), ledger)
    }

    func testUserCategoryWithTheSameNameBecomesTheBuiltInOne() throws {
        let oldID = UUID()
        let entry = Spend(amount: 900, categoryID: oldID, sources: FieldSources(category: .user),
                          prediction: CategoryPrediction(candidates: [CategoryCandidate(categoryID: oldID, confidence: 0.9)]))
        let ledger = Ledger(transactions: [entry], categories: [SpendCategory(id: oldID, name: "credit card bill")])
        XCTAssertEqual(ledger.categories.map(\.id), [billID])
        XCTAssertEqual(ledger.categories.first?.name, "credit card bill", "keeps the user's spelling")
        XCTAssertEqual(ledger.transactions[0].categoryID, billID)
        XCTAssertEqual(ledger.transactions[0].prediction?.candidates.first?.categoryID, billID)
    }

    // MARK: Learning

    func testLabelledBillTeachesTheNextBillFromTheSameMerchant() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food")).id
        let travel = try XCTUnwrap(ledger.addCategory(named: "Travel")).id
        for day in 1...3 {
            label(&ledger, "Swiggy", 300, day: day, as: food, account: .creditCard)
            label(&ledger, "Uber", 250, day: day, as: travel, account: .creditCard)
        }
        label(&ledger, "SBI Cards and Payment Ser", 12_493, day: 4, as: billID)
        let charge = label(&ledger, "Swiggy", 1_000, day: 5, as: food, account: .creditCard)

        let next = Spend(amount: 9_000, date: date(12), merchant: "SBI Cards and Payment Ser", source: .sms, rawText: "Sent Rs.9000.00")
        ledger.add(next, calendar: calendar)
        let result = try saved(ledger, next)
        XCTAssertEqual(result.categoryID, billID)
        XCTAssertEqual(result.sources.category, .learned)
        XCTAssertTrue(result.isCardBill)
        // The bill covers the 1,000 card spend from day 5 and counts only the rest.
        let counted = Counting.countedAmounts(ledger.transactions)
        XCTAssertEqual(counted[next.id], 8_000)
        XCTAssertEqual(counted[charge.id], 1_000)
    }

    func testBillCategoryIsNeverAutoAssignedToACardSpend() throws {
        var ledger = Ledger()
        for day in 1...4 { label(&ledger, "Card Issuer", 5_000, day: day, as: billID) }
        let onCard = Spend(amount: 5_000, date: date(6), merchant: "Card Issuer", account: .creditCard)
        ledger.add(onCard, calendar: calendar)
        let result = try saved(ledger, onCard)
        XCTAssertNil(result.categoryID)
        XCTAssertEqual(result.prediction?.candidates.first?.categoryID, billID, "still offered as a suggestion")
        XCTAssertEqual(result.prediction?.autoAssign, false)
    }

    func testRuleBillIsNotReplacedByAPrediction() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food")).id
        for day in 1...4 { label(&ledger, "Bank", 2_000, day: day, as: food) }
        let text = "Rs 2,000 debited from A/c XX1234 towards your Bank Credit Card XX5678 on 06-11-26. Ref 998877"
        let entry = try XCTUnwrap(SMSParser().parse(text).parsed).makeEntry(date: date(6), rawText: text)
        ledger.add(entry, calendar: calendar)
        let result = try saved(ledger, entry)
        XCTAssertEqual(result.categoryID, billID)
        XCTAssertEqual(result.sources.category, .rule)
    }

    // MARK: Duplicates

    func testDuplicateSMSThatSeesABillMakesTheEntryABill() throws {
        var ledger = Ledger()
        let generic = Spend(amount: 8_000, date: date(6), merchant: "SBI Cards and Payment Ser", source: .sms,
                            rawText: "Sent Rs.8000.00 From A/C *1234 To SBI Cards and Payment Ser", ref: "112233445566")
        XCTAssertTrue(ledger.add(generic, calendar: calendar))
        let text = "Rs 8,000 debited from A/c XX1234 towards your Bank Credit Card XX5678 on 06-11-26. Ref 112233445566"
        let billSMS = try XCTUnwrap(SMSParser().parse(text).parsed).makeEntry(date: date(6).addingTimeInterval(30), rawText: text)
        XCTAssertFalse(ledger.add(billSMS, calendar: calendar))
        let kept = try saved(ledger, generic)
        XCTAssertTrue(kept.isCardBill)
        XCTAssertEqual(kept.sources.category, .rule)
        XCTAssertEqual(kept.card, "5678")
    }

    // MARK: Review queue (Categorize widget)

    func testReviewQueueHasUncategorizedAndAutoAssignedEntriesNewestFirst() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food")).id
        let mine = Spend(amount: 10, date: date(1), categoryID: food, sources: FieldSources(category: .user))
        let learned = Spend(amount: 20, date: date(2), categoryID: food, sources: FieldSources(category: .learned))
        let rule = Spend(amount: 5_000, date: date(3), categoryID: billID, sources: FieldSources(category: .rule))
        let open = Spend(amount: 40, date: date(4))
        let savings = Spend(amount: 50, date: date(5), kind: .savings)
        ledger = Ledger(transactions: [mine, learned, rule, open, savings], categories: ledger.categories)

        XCTAssertEqual(ledger.reviewQueue.map(\.id), [open.id, rule.id, learned.id])

        // Tapping the category that was already assigned confirms it.
        ledger.setCategory(food, for: [learned.id])
        XCTAssertEqual(try saved(ledger, learned).sources.category, .user)
        XCTAssertEqual(ledger.reviewQueue.map(\.id), [open.id, rule.id])
    }
}
