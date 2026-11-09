import XCTest
@testable import BudgetCore

final class PredictionTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func date(_ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))!
    }

    /// Adds an entry and labels it, as the user would.
    @discardableResult
    private func label(_ ledger: inout Ledger, _ merchant: String, _ amount: Decimal, day: Int, as category: SpendCategory) -> Spend {
        let entry = Spend(amount: amount, date: date(day), merchant: merchant)
        ledger.add(entry, calendar: calendar)
        ledger.setCategory(category.id, for: [entry.id])
        return entry
    }

    private func saved(_ ledger: Ledger, _ entry: Spend) throws -> Spend {
        try XCTUnwrap(ledger.transactions.first { $0.id == entry.id })
    }

    private func twoCategories(_ ledger: inout Ledger) throws -> (SpendCategory, SpendCategory) {
        (try XCTUnwrap(ledger.addCategory(named: "Food")), try XCTUnwrap(ledger.addCategory(named: "Travel")))
    }

    func testNoLabelsMeansNoPrediction() throws {
        var ledger = Ledger()
        _ = try twoCategories(&ledger)
        let entry = Spend(amount: 10, merchant: "Swiggy")
        ledger.add(entry, calendar: calendar)
        XCTAssertNil(try saved(ledger, entry).prediction)
        XCTAssertNil(try saved(ledger, entry).categoryID)
    }

    func testRepeatMerchantIsAutoAssignedAndNotAUserLabel() throws {
        var ledger = Ledger()
        let (food, travel) = try twoCategories(&ledger)
        for day in 1...4 {
            label(&ledger, "Swiggy", 300, day: day, as: food)
            label(&ledger, "Uber", 300, day: day, as: travel)
        }
        let entry = Spend(amount: 280, date: date(6), merchant: "SWIGGY")
        ledger.add(entry, calendar: calendar)
        let result = try saved(ledger, entry)
        XCTAssertEqual(result.categoryID, food.id)
        XCTAssertEqual(result.sources.category, .learned)
        XCTAssertEqual(result.prediction?.candidates.first?.categoryID, food.id)
        XCTAssertEqual(result.prediction?.reason, "4 of 4 past SWIGGY spends")
    }

    func testCandidatesAreAtMostThreeAndBestFirst() throws {
        var ledger = Ledger()
        let names = ["A", "B", "C", "D"].compactMap { ledger.addCategory(named: $0) }
        for (index, category) in names.enumerated() {
            label(&ledger, "Shop", 100, day: index + 1, as: category)
        }
        let entry = Spend(amount: 100, date: date(6), merchant: "Shop")
        ledger.add(entry, calendar: calendar)
        let candidates = try XCTUnwrap(saved(ledger, entry).prediction?.candidates)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.map(\.confidence), candidates.map(\.confidence).sorted(by: >))
    }

    func testAmountSeparatesCategoriesForOneRecipient() throws {
        var ledger = Ledger()
        let order = try XCTUnwrap(ledger.addCategory(named: "Order"))
        let tip = try XCTUnwrap(ledger.addCategory(named: "Tip"))
        for (day, amount) in [(1, Decimal(350)), (3, 320), (5, 300), (7, 340)] { label(&ledger, "ZOMATO", amount, day: day, as: order) }
        for (day, amount) in [(2, Decimal(30)), (4, 25), (6, 35)] { label(&ledger, "ZOMATO", amount, day: day, as: tip) }

        let small = Spend(amount: 28, date: date(9), merchant: "ZOMATO")
        let large = Spend(amount: 330, date: date(10), merchant: "ZOMATOLIMITED")
        ledger.add(small, calendar: calendar)
        ledger.add(large, calendar: calendar)
        XCTAssertEqual(try saved(ledger, small).prediction?.candidates.first?.categoryID, tip.id)
        XCTAssertEqual(try saved(ledger, large).prediction?.candidates.first?.categoryID, order.id)
    }

    func testNewMerchantGetsSuggestionsButNoCategory() throws {
        var ledger = Ledger()
        let (food, travel) = try twoCategories(&ledger)
        for day in 1...3 {
            label(&ledger, "Swiggy", 300, day: day, as: food)
            label(&ledger, "Uber", 300, day: day, as: travel)
        }
        let entry = Spend(amount: 300, date: date(6), merchant: "Brand New Shop")
        ledger.add(entry, calendar: calendar)
        let result = try saved(ledger, entry)
        XCTAssertNil(result.categoryID)
        XCTAssertEqual(result.prediction?.candidates.isEmpty, false)
        XCTAssertEqual(result.prediction?.autoAssign, false)
    }

    func testFewerThanMinimumLabelsIsNotAssigned() throws {
        var ledger = Ledger()
        let (food, _) = try twoCategories(&ledger)
        label(&ledger, "Swiggy", 300, day: 1, as: food)
        label(&ledger, "Swiggy", 300, day: 2, as: food)
        let entry = Spend(amount: 300, date: date(3), merchant: "Swiggy")
        ledger.add(entry, calendar: calendar)
        XCTAssertNil(try saved(ledger, entry).categoryID)
        XCTAssertEqual(try saved(ledger, entry).prediction?.candidates.first?.categoryID, food.id)
    }

    func testACorrectionOutweighsEarlierLabels() throws {
        var ledger = Ledger()
        let (food, travel) = try twoCategories(&ledger)
        label(&ledger, "Shop", 100, day: 1, as: food)
        label(&ledger, "Shop", 100, day: 2, as: food)
        label(&ledger, "Shop", 100, day: 3, as: food)
        let wrong = Spend(amount: 100, date: date(4), merchant: "Shop")
        ledger.add(wrong, calendar: calendar)
        XCTAssertEqual(try saved(ledger, wrong).categoryID, food.id)
        ledger.setCategory(travel.id, for: [wrong.id])

        // As ordinary labels, two Travel would still lose to three Food.
        label(&ledger, "Shop", 100, day: 5, as: travel)
        let after = Spend(amount: 100, date: date(6), merchant: "Shop")
        ledger.add(after, calendar: calendar)
        XCTAssertEqual(try saved(ledger, after).prediction?.candidates.first?.categoryID, travel.id)
    }

    func testAutoAssignedValuesDoNotTrainTheModel() throws {
        var ledger = Ledger()
        let (food, _) = try twoCategories(&ledger)
        for day in 1...3 { label(&ledger, "Swiggy", 100, day: day, as: food) }
        for day in 4...9 { ledger.add(Spend(amount: 100, date: date(day), merchant: "Swiggy"), calendar: calendar) }
        XCTAssertEqual(ledger.transactions.filter { $0.sources.category == .learned }.count, 6)
        XCTAssertEqual(ledger.categoryReplay(calendar: calendar).labels, 3)
    }

    func testTheUsersCategoryIsNeverReplaced() throws {
        var ledger = Ledger()
        let (food, travel) = try twoCategories(&ledger)
        for day in 1...3 { label(&ledger, "Swiggy", 100, day: day, as: food) }
        let entry = Spend(amount: 100, date: date(4), merchant: "Swiggy", categoryID: travel.id,
                          sources: FieldSources(category: .user))
        ledger.add(entry, calendar: calendar)
        ledger.predictUncategorized(calendar: calendar)
        XCTAssertEqual(try saved(ledger, entry).categoryID, travel.id)
        XCTAssertNil(try saved(ledger, entry).prediction)
    }

    func testEntriesThatCountZeroAreNotPredicted() throws {
        var ledger = Ledger()
        let (food, _) = try twoCategories(&ledger)
        for day in 1...3 { label(&ledger, "Swiggy", 100, day: day, as: food) }
        let savings = Spend(amount: 100, date: date(4), merchant: "Swiggy", kind: .savings)
        ledger.add(savings, calendar: calendar)
        XCTAssertNil(try saved(ledger, savings).categoryID)
        XCTAssertNil(try saved(ledger, savings).prediction)
    }

    func testPredictUncategorizedFillsOlderEntries() throws {
        var ledger = Ledger()
        let older = Spend(amount: 100, date: date(1), merchant: "Swiggy")
        ledger.add(older, calendar: calendar)
        let (food, _) = try twoCategories(&ledger)
        for day in 2...4 { label(&ledger, "Swiggy", 100, day: day, as: food) }
        XCTAssertEqual(ledger.predictUncategorized(calendar: calendar), 1)
        XCTAssertEqual(try saved(ledger, older).categoryID, food.id)
        XCTAssertEqual(try saved(ledger, older).sources.category, .learned)
    }

    func testDeletingACategoryRemovesItFromPredictions() throws {
        var ledger = Ledger()
        let (food, _) = try twoCategories(&ledger)
        for day in 1...3 { label(&ledger, "Swiggy", 100, day: day, as: food) }
        let entry = Spend(amount: 100, date: date(4), merchant: "Swiggy")
        ledger.add(entry, calendar: calendar)
        ledger.deleteCategory(food.id)
        XCTAssertNil(try saved(ledger, entry).categoryID)
        XCTAssertNil(try saved(ledger, entry).prediction)
    }

    func testBetterMerchantFromADuplicateUpdatesThePrediction() throws {
        var ledger = Ledger()
        let (food, travel) = try twoCategories(&ledger)
        for day in 1...3 {
            label(&ledger, "BSNL Bill", 177, day: day, as: food)
            label(&ledger, "Uber", 177, day: day, as: travel)
        }
        let now = date(8)
        ledger.add(Spend(amount: 177, date: now, merchant: "AxisBank", source: .sms, rawText: "first"), calendar: calendar)
        XCTAssertNil(ledger.transactions[0].categoryID)
        XCTAssertFalse(ledger.add(Spend(amount: 177, date: now.addingTimeInterval(1), merchant: "BSNL Bill", source: .sms, rawText: "second"),
                                  calendar: calendar))
        XCTAssertEqual(ledger.transactions[0].merchant, "BSNL Bill")
        XCTAssertEqual(ledger.transactions[0].categoryID, food.id)
    }

    func testReplayOnlyUsesEarlierLabels() throws {
        var ledger = Ledger()
        let (food, travel) = try twoCategories(&ledger)
        for day in 1...5 {
            label(&ledger, "Swiggy", 300, day: day * 2 - 1, as: food)
            label(&ledger, "Uber", 300, day: day * 2, as: travel)
        }
        let result = ledger.categoryReplay(calendar: calendar)
        XCTAssertEqual(result.labels, 10)
        XCTAssertEqual(result.tested, 9)
        // Only the first Uber can be wrong: no earlier label names it.
        XCTAssertEqual(result.topCorrect, 8)
        XCTAssertEqual(result.topThreeCorrect, 8)
        XCTAssertEqual(result.autoCorrect, result.autoAssigned)
    }

    func testCompanySuffixesAreRemovedFromTheMerchantKey() {
        func key(_ name: String) -> String? { Spend(amount: 1, merchant: name).merchantKey }
        XCTAssertEqual(key("ZOMATOLIMITED"), "zomato")
        XCTAssertEqual(key("Zomato Ltd"), "zomato")
        XCTAssertEqual(key("Acme Pvt Ltd"), "acme")
        XCTAssertEqual(key("Acme Inc"), "acme")
        XCTAssertEqual(key("Limited"), "limited")
        XCTAssertEqual(key("zinc"), "zinc")
    }

    func testPredictionRoundTripsAndABadValueIsTolerated() throws {
        let id = UUID()
        let entry = Spend(amount: 1, date: Date(timeIntervalSinceReferenceDate: 0),
                          prediction: CategoryPrediction(candidates: [CategoryCandidate(categoryID: id, confidence: 0.5)], reason: "x", autoAssign: true))
        XCTAssertEqual(try JSONDecoder().decode(Spend.self, from: JSONEncoder().encode(entry)), entry)

        let json = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","amount":"10","date":0,"prediction":{"unexpected":true}}"#
        XCTAssertNil(try JSONDecoder().decode(Spend.self, from: Data(json.utf8)).prediction)
    }
}
