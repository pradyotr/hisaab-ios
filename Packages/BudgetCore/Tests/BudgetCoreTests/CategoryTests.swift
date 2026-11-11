import XCTest
@testable import BudgetCore

final class CategoryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var engine: BudgetEngine {
        BudgetEngine(config: BudgetConfig(monthlyIncome: 50_000, goal: .save(20_000)), calendar: calendar)
    }

    // MARK: Managing categories

    func testAddCategoryTrimsAndReusesAnExistingName() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "  Food "))
        XCTAssertEqual(food.name, "Food")
        XCTAssertEqual(ledger.addCategory(named: "FOOD")?.id, food.id)
        XCTAssertNil(ledger.addCategory(named: "   "))
        XCTAssertEqual(ledger.categories.count, 1 + SpendCategory.builtIn.count)
    }

    func testRenameRefusesANameAlreadyInUse() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food"))
        ledger.addCategory(named: "Rent")
        XCTAssertFalse(ledger.renameCategory(food.id, to: "rent"))
        XCTAssertTrue(ledger.renameCategory(food.id, to: "FOOD"))
        XCTAssertEqual(ledger.categories.first { $0.id == food.id }?.name, "FOOD")
    }

    func testDeleteCategoryClearsItsEntries() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food"))
        let entry = Spend(amount: 10)
        ledger.add(entry)
        ledger.setCategory(food.id, for: [entry.id])
        ledger.deleteCategory(food.id)
        XCTAssertNil(ledger.transactions[0].categoryID)
        XCTAssertNil(ledger.transactions[0].sources.category)
    }

    func testSetCategoryRecordsTheUserAsSource() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food"))
        let entry = Spend(amount: 10)
        ledger.add(entry)
        ledger.setCategory(food.id, for: [entry.id])
        XCTAssertEqual(ledger.transactions[0].categoryID, food.id)
        XCTAssertEqual(ledger.transactions[0].sources.category, .user)
        ledger.setCategory(nil, for: [entry.id])
        XCTAssertNil(ledger.transactions[0].sources.category)
    }

    func testSetCategoryIgnoresAnUnknownCategory() {
        var ledger = Ledger()
        let entry = Spend(amount: 10)
        ledger.add(entry)
        ledger.setCategory(UUID(), for: [entry.id])
        XCTAssertNil(ledger.transactions[0].categoryID)
    }

    func testCategoriesByUse() throws {
        var ledger = Ledger()
        let rent = try XCTUnwrap(ledger.addCategory(named: "Rent"))
        let food = try XCTUnwrap(ledger.addCategory(named: "Food"))
        let bills = try XCTUnwrap(ledger.addCategory(named: "Bills"))
        let entry = Spend(amount: 10)
        ledger.add(entry)
        ledger.setCategory(rent.id, for: [entry.id])
        XCTAssertEqual(ledger.categoriesByUse.map(\.id), [rent.id, bills.id, SpendCategory.creditCardBillID, food.id])
    }

    // MARK: Which entries need a category

    func testOnlyEntriesThatCountNeedACategory() {
        var ledger = Ledger()
        let spend = Spend(amount: 10)
        let refund = Spend(amount: 5, kind: .refund)
        [spend, refund, Spend(amount: 10, kind: .savings), Spend(amount: 10, kind: .otherCredit),
         Spend(amount: 10, excluded: true)].forEach { ledger.add($0) }
        XCTAssertEqual(Set(ledger.entriesNeedingCategory.map(\.id)), [spend.id, refund.id])
    }

    func testQueuePutsTheBiggestMerchantGroupFirst() {
        var ledger = Ledger()
        let now = date(2026, 11, 5)
        let once = Spend(amount: 1, date: now, merchant: "Chemist")
        let swiggyOld = Spend(amount: 2, date: now.addingTimeInterval(-100), merchant: "SWIGGY")
        let swiggyNew = Spend(amount: 3, date: now.addingTimeInterval(-50), merchant: "swiggy@ybl")
        let noMerchant = Spend(amount: 4, date: now.addingTimeInterval(50))
        [once, swiggyOld, swiggyNew, noMerchant].forEach { ledger.add($0) }
        XCTAssertEqual(ledger.categorizationQueue.map(\.id), [swiggyNew.id, swiggyOld.id, once.id, noMerchant.id])
    }

    func testSimilarUncategorizedMatchesTheMerchantAndSkipsCategorized() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food"))
        let first = Spend(amount: 1, merchant: "Swiggy")
        let same = Spend(amount: 2, merchant: "SWIGGY")
        let done = Spend(amount: 3, merchant: "swiggy")
        let other = Spend(amount: 4, merchant: "Chemist")
        [first, same, done, other].forEach { ledger.add($0) }
        ledger.setCategory(food.id, for: [done.id])
        XCTAssertEqual(ledger.similarUncategorized(to: first).map(\.id), [same.id])
    }

    // MARK: Field sources

    func testUpdateRecordsOnlyTheFieldsThatChanged() {
        var ledger = Ledger()
        let entry = Spend(amount: 10, merchant: "Shop", source: .sms, rawText: "text")
        ledger.add(entry)
        var edited = entry
        edited.kind = .savings
        edited.merchant = "Better name"
        ledger.update(edited)
        let saved = ledger.transactions[0].sources
        XCTAssertEqual(saved.kind, .user)
        XCTAssertEqual(saved.merchant, .user)
        XCTAssertNil(saved.amount)
        XCTAssertNil(saved.account)
    }

    func testAccountResetByATypeChangeIsNotAUserDecision() {
        var ledger = Ledger()
        let entry = Spend(amount: 10, account: .creditCard)
        ledger.add(entry)
        var edited = entry
        edited.kind = .otherCredit
        edited.account = .bank
        ledger.update(edited)
        XCTAssertEqual(ledger.transactions[0].sources.kind, .user)
        XCTAssertNil(ledger.transactions[0].sources.account)
    }

    // MARK: Storage

    func testOldFileLoadsAtTheCurrentSchemaVersion() throws {
        let json = #"{"schemaVersion":1,"transactions":[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","amount":"10","date":0}]}"#
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(json.utf8))
        XCTAssertEqual(ledger.schemaVersion, Ledger.currentSchemaVersion)
        XCTAssertEqual(ledger.categories, SpendCategory.builtIn)
        XCTAssertNil(ledger.transactions[0].categoryID)
        XCTAssertEqual(ledger.transactions[0].sources, FieldSources())
    }

    func testCategoryAndSourcesRoundTrip() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food"))
        let entry = Spend(amount: 10)
        ledger.add(entry)
        ledger.setCategory(food.id, for: [entry.id])
        let decoded = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    func testUnknownSourceValueDoesNotBreakTheFile() throws {
        let json = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","amount":"10","date":0,"sources":{"kind":"fromTheFuture"}}"#
        let entry = try JSONDecoder().decode(Spend.self, from: Data(json.utf8))
        XCTAssertEqual(entry.sources, FieldSources())
    }

    // MARK: Payment method

    private func method(_ text: String?, account: PaymentAccount = .bank) -> PaymentMethod {
        Spend(amount: 1, source: .sms, rawText: text, account: account).method
    }

    func testPaymentMethod() {
        XCTAssertEqual(method("Rs 10 spent via UPI on Credit Card XX1234", account: .creditCard), .creditCard)
        XCTAssertEqual(method("Rs 10 debited from A/c XX1234 to shop@ybl"), .upi)
        XCTAssertEqual(method("Rs 10 paid using BHIM"), .upi)
        XCTAssertEqual(method("Rs 10 spent on Debit Card XX1234 at SHOP"), .debitCard)
        XCTAssertEqual(method("Rs 10 withdrawn at ATM using Debit Card XX1234"), .atm)
        XCTAssertEqual(method("Rs 10 debited by NEFT from A/c XX1234"), .bankTransfer)
        XCTAssertEqual(method("Rs 10 debited from A/c XX1234"), .unknown)
        XCTAssertEqual(method(nil), .unknown)
    }

    // MARK: Merging duplicate SMS

    func testDuplicateFillsMissingDetailsAndTheRealMerchant() {
        var ledger = Ledger()
        let now = Date()
        XCTAssertTrue(ledger.add(Spend(amount: 177, date: now, merchant: "AxisBank", source: .sms, rawText: "first", ref: nil)))
        XCTAssertFalse(ledger.add(Spend(amount: 177, date: now.addingTimeInterval(1), merchant: "Mobile Bill", source: .sms,
                                        rawText: "second", account: .creditCard, card: "1234", ref: "123456789012")))
        XCTAssertEqual(ledger.transactions.count, 1)
        XCTAssertEqual(ledger.transactions[0].merchant, "Mobile Bill")
        XCTAssertEqual(ledger.transactions[0].ref, "123456789012")
        XCTAssertEqual(ledger.transactions[0].card, "1234")
        XCTAssertEqual(ledger.transactions[0].account, .creditCard)
    }

    func testDuplicateDoesNotReplaceARealMerchantWithAGateway() {
        var ledger = Ledger()
        let now = Date()
        ledger.add(Spend(amount: 177, date: now, merchant: "Mobile Bill", source: .sms, rawText: "first"))
        ledger.add(Spend(amount: 177, date: now.addingTimeInterval(1), merchant: "AxisBank", source: .sms, rawText: "second"))
        XCTAssertEqual(ledger.transactions[0].merchant, "Mobile Bill")
    }

    func testDuplicateNeverReplacesTheUsersValues() {
        var ledger = Ledger()
        let now = Date()
        let entry = Spend(amount: 177, date: now, merchant: "AxisBank", source: .sms, rawText: "first", account: .bank)
        ledger.add(entry)
        var edited = entry
        edited.merchant = "HDFC Bank"
        ledger.update(edited)
        var account = ledger.transactions[0]
        account.account = .creditCard
        ledger.update(account)
        account.account = .bank
        ledger.update(account)

        ledger.add(Spend(amount: 177, date: now.addingTimeInterval(1), merchant: "Mobile Bill", source: .sms,
                         rawText: "second", account: .creditCard))
        XCTAssertEqual(ledger.transactions[0].merchant, "HDFC Bank")
        XCTAssertEqual(ledger.transactions[0].account, .bank)
    }

    // MARK: Totals

    func testCategoryTotalsAddUpToCycleSpentAndUseCountedAmounts() throws {
        var ledger = Ledger()
        let food = try XCTUnwrap(ledger.addCategory(named: "Food"))
        let bills = try XCTUnwrap(ledger.addCategory(named: "Bills"))
        let meal = Spend(amount: 500, date: date(2026, 11, 3), kind: .spend, categoryID: food.id)
        let refund = Spend(amount: 100, date: date(2026, 11, 4), kind: .refund, categoryID: food.id)
        let cardSpend = Spend(amount: 800, date: date(2026, 11, 5), account: .creditCard, categoryID: bills.id)
        // 1,000 paid: 800 was tracked, 200 (fees, untracked spends) counts under the bill category.
        let cardBill = Spend(amount: 1_000, date: date(2026, 11, 6), categoryID: SpendCategory.creditCardBillID)
        let loose = Spend(amount: 50, date: date(2026, 11, 7))
        let savings = Spend(amount: 900, date: date(2026, 11, 8), kind: .savings, categoryID: food.id)
        let lastCycle = Spend(amount: 999, date: date(2026, 10, 8), categoryID: food.id)
        let entries = [meal, refund, cardSpend, cardBill, loose, savings, lastCycle]
        let cycle = engine.cycle(containing: date(2026, 11, 15))

        let totals = engine.categoryTotals(for: cycle, transactions: entries)
        XCTAssertEqual(totals.map(\.categoryID), [bills.id, food.id, SpendCategory.creditCardBillID, nil])
        XCTAssertEqual(totals.map(\.amount), [800, 400, 200, 50])
        XCTAssertEqual(totals.map(\.count), [1, 2, 1, 1])
        XCTAssertEqual(totals.reduce(Decimal(0)) { $0 + $1.amount }, engine.summary(for: cycle, transactions: entries).spent)
    }

    func testCategoryTrendIncludesEmptyCyclesOldestFirst() throws {
        let food = UUID()
        let entries = [
            Spend(amount: 100, date: date(2026, 8, 5), categoryID: food),
            Spend(amount: 200, date: date(2026, 10, 5), categoryID: food),
            Spend(amount: 400, date: date(2026, 10, 6)),
        ]
        let trend = engine.categoryTrend(categoryID: food, transactions: entries, upTo: date(2026, 11, 15), limit: 3)
        XCTAssertEqual(trend.map(\.amount), [0, 200, 0])
        XCTAssertEqual(trend.map { calendar.component(.month, from: $0.cycle.start) }, [9, 10, 11])
    }
}
