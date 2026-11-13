import XCTest
@testable import BudgetCore

/// The ledger / inbox / widget digest split (see `LedgerStore`). File protection itself only exists on a device;
/// these tests cover what the code does around it. All SMS are made up.
final class LockedStorageTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private let upiSpend = "Rs.500.00 debited from A/c XX1234 to VPA shop@upi on 03-11-26. UPI Ref No 612345678901"
    private let cardSpend = "INR 1,249.00 spent on Bank Card XX5678 at AMAZON PAY on 03-11-26. Avl Lmt: INR 50,000.00"
    private let cardBill = "Rs 900 paid towards your Credit Card XX5678"

    private func makeStore() -> (LedgerStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (LedgerStore(url: dir.appendingPathComponent("ledger.json")), dir)
    }

    private func setUpLedger() -> Ledger {
        var ledger = Ledger(config: BudgetConfig(monthlyIncome: 60_000, goal: .save(30_000)))
        ledger.add(Spend(amount: 400, date: date(2026, 10, 30), merchant: "Old cycle"))
        ledger.add(Spend(amount: 1_000, date: date(2026, 11, 2), merchant: "Groceries", account: .creditCard, card: "5678"))
        ledger.add(Spend(amount: 150, date: date(2026, 11, 3), merchant: "Cafe"))
        ledger.add(Spend(amount: 50, date: date(2026, 11, 4), merchant: "Cafe", kind: .refund))
        ledger.add(Spend(amount: 2_000, date: date(2026, 11, 4), merchant: "Broker", kind: .savings))
        ledger.add(Spend(amount: 1_200, date: date(2026, 11, 5), merchant: "Card bill", card: "5678",
                         categoryID: SpendCategory.creditCardBillID))
        return ledger
    }

    // MARK: Unreadable ledger

    func testUnreadableLedgerIsNeverOverwritten() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A folder where the file should be: it exists but can't be read, like a protected file while locked.
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.loadAvailable()) { XCTAssertTrue($0 is LedgerStore.Unavailable) }
        var called = false
        XCTAssertThrowsError(try store.update { _ in called = true }) { XCTAssertTrue($0 is LedgerStore.Unavailable) }
        XCTAssertFalse(called, "nothing is changed on top of a ledger that could not be read")
        XCTAssertEqual(store.load(), Ledger(), "load() is for display only")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path, isDirectory: &isFolder) && isFolder.boolValue)
    }

    func testMissingLedgerIsEmptyNotUnavailable() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try store.loadAvailable(), Ledger())
    }

    // MARK: Inbox

    func testInboxIsTakenInOnTheNextUpdateInOrder() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(setUpLedger())
        XCTAssertFalse(store.hasPendingSMS)

        try store.enqueue(cardSpend, at: date(2026, 11, 6, 10, 5))
        try store.enqueue(upiSpend, at: date(2026, 11, 6, 10, 0))
        XCTAssertTrue(store.hasPendingSMS)

        let ledger = try store.update { _ in }
        XCTAssertFalse(store.hasPendingSMS)
        let logged = ledger.transactions.filter { $0.source == .sms }
        XCTAssertEqual(logged.map(\.amount), [1_249, 500])
        XCTAssertEqual(logged.first?.rawText, cardSpend)
        XCTAssertEqual(ledger.log.count, 2)
        XCTAssertTrue(ledger.log.last?.message.hasPrefix("Logged 500") ?? false, "oldest SMS is taken in first")
    }

    func testDuplicateSMSInInboxIsLoggedOnce() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.enqueue(upiSpend, at: date(2026, 11, 6, 10, 0))
        try store.enqueue(upiSpend, at: date(2026, 11, 6, 10, 1))
        let ledger = try store.update { _ in }
        XCTAssertEqual(ledger.transactions.count, 1)
    }

    // MARK: Widget digest

    func testDigestMatchesTheFullLedger() {
        let ledger = setUpLedger()
        let now = date(2026, 11, 5, 18)
        let digest = WidgetDigest(ledger: ledger, now: now, calendar: calendar)
        let engine = BudgetEngine(config: ledger.config!, calendar: calendar)

        for at in [now, date(2026, 11, 6, 0), date(2026, 11, 30, 23)] {
            XCTAssertEqual(digest.snapshot(at: at, calendar: calendar),
                           engine.snapshot(at: at, transactions: ledger.transactions), "\(at)")
        }
        XCTAssertEqual(digest.categoryTotals(at: now, calendar: calendar),
                       engine.categoryTotals(for: engine.cycle(containing: now), transactions: ledger.transactions))
    }

    func testDigestHoldsNoHistoryOrText() throws {
        var ledger = setUpLedger()
        ledger.logSMS(upiSpend, at: date(2026, 11, 5, 17, 58))
        let digest = WidgetDigest(ledger: ledger, now: date(2026, 11, 5, 18), calendar: calendar)
        XCTAssertFalse(digest.counted.contains { $0.date < date(2026, 11, 1, 0) }, "only the current cycle")
        let json = String(decoding: try JSONEncoder().encode(digest), as: UTF8.self)
        for secret in ["Groceries", "Cafe", "Broker", "shop@upi", "XX1234", "debited"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
    }

    func testStoreWritesDigestOnEverySave() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = date(2026, 11, 5, 18)
        let saved = setUpLedger()
        try store.save(saved, now: now)
        XCTAssertEqual(store.loadDigest(), WidgetDigest(ledger: saved, now: now))

        let ledger = try store.update(now: now) { $0.settings.hideValues = true }
        XCTAssertEqual(store.loadDigest(), WidgetDigest(ledger: ledger, now: now))
        XCTAssertEqual(store.loadDigest()?.settings.hideValues, true)
    }

    // MARK: SMS while locked

    func testLockedSMSUpdatesTheWidgetEstimate() {
        let now = date(2026, 11, 6, 10)
        var digest = WidgetDigest(ledger: setUpLedger(), now: now, calendar: calendar)
        let before = digest.snapshot(at: now, calendar: calendar)!

        XCTAssertFalse(digest.addPending(upiSpend, at: now).ignored)
        let after = digest.snapshot(at: now, calendar: calendar)!
        XCTAssertEqual(after.day.spent, before.day.spent + 500)
        XCTAssertEqual(after.day.budget, before.day.budget, "today's budget is fixed at the start of the day")
        XCTAssertEqual(after.cycle.spent, before.cycle.spent + 500)
        XCTAssertEqual(digest.pendingCount, 1)
    }

    func testLockedDuplicateIsNotCountedTwice() {
        let now = date(2026, 11, 6, 10)
        var digest = WidgetDigest(ledger: setUpLedger(), now: now, calendar: calendar)
        digest.addPending(upiSpend, at: now)
        let once = digest.snapshot(at: now, calendar: calendar)!.day.spent

        let second = digest.addPending(upiSpend, at: now.addingTimeInterval(30))
        XCTAssertFalse(second.ignored, "kept for the ledger, which may learn more from it")
        XCTAssertEqual(digest.snapshot(at: now, calendar: calendar)!.day.spent, once)
    }

    func testLockedDuplicateOfAnSMSLoggedBeforeLocking() {
        let now = date(2026, 11, 6, 10)
        var ledger = setUpLedger()
        ledger.logSMS(upiSpend, at: now.addingTimeInterval(-60))
        var digest = WidgetDigest(ledger: ledger, now: now, calendar: calendar)
        let before = digest.snapshot(at: now, calendar: calendar)!.day.spent
        digest.addPending(upiSpend, at: now)
        XCTAssertEqual(digest.snapshot(at: now, calendar: calendar)!.day.spent, before)
    }

    func testLockedCardBillAndIgnoredSMSCountNothing() {
        let now = date(2026, 11, 6, 10)
        var digest = WidgetDigest(ledger: setUpLedger(), now: now, calendar: calendar)
        let before = digest.snapshot(at: now, calendar: calendar)!

        XCTAssertFalse(digest.addPending(cardBill, at: now).ignored)
        let otp = digest.addPending("123456 is your OTP for login. Do not share it with anyone.", at: now)
        XCTAssertTrue(otp.ignored)
        XCTAssertEqual(digest.snapshot(at: now, calendar: calendar), before)
    }

    func testUnlockReplacesEstimatesWithTheLedger() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = date(2026, 11, 6, 10)
        try store.save(setUpLedger(), now: now)

        // Locked: what the App Intent does.
        for sms in [upiSpend, cardBill] {
            try store.updateDigest { digest in _ = digest.addPending(sms, at: now) }
            try store.enqueue(sms, at: now)
        }
        XCTAssertEqual(store.loadDigest()?.pendingCount, 2)

        // Unlocked: any write.
        let ledger = try store.update(now: now) { _ in }
        let digest = try XCTUnwrap(store.loadDigest())
        XCTAssertEqual(digest.pendingCount, 0)
        XCTAssertEqual(digest, WidgetDigest(ledger: ledger, now: now))
        XCTAssertEqual(ledger.transactions.filter { $0.source == .sms }.count, 2)
    }

    func testUpdateDigestWithoutDigestThrows() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try store.updateDigest { _ in })
    }

    func testDeleteAllRemovesInboxAndDigest() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(setUpLedger())
        try store.enqueue(upiSpend, at: Date())
        try store.deleteAll()
        XCTAssertFalse(store.hasPendingSMS)
        XCTAssertNil(store.loadDigest())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
