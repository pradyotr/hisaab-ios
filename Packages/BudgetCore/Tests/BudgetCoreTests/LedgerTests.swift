import XCTest
@testable import BudgetCore

final class LedgerTests: XCTestCase {
    func testDuplicateSMSIsSkipped() {
        var ledger = Ledger()
        let now = Date()
        let sms = "Rs 500 debited from A/c XX1234 to shop@upi"
        XCTAssertTrue(ledger.add(Transaction(amount: 500, date: now, source: .sms, rawText: sms)))
        XCTAssertFalse(ledger.add(Transaction(amount: 500, date: now.addingTimeInterval(30), source: .sms, rawText: sms)))
        XCTAssertTrue(ledger.add(Transaction(amount: 500, date: now.addingTimeInterval(3_600), source: .sms, rawText: sms)))
        XCTAssertEqual(ledger.transactions.count, 2)
    }

    func testManualEntriesAreNeverDeduped() {
        var ledger = Ledger()
        XCTAssertTrue(ledger.add(Transaction(amount: 50)))
        XCTAssertTrue(ledger.add(Transaction(amount: 50)))
    }

    func testTransactionsSortedNewestFirst() {
        var ledger = Ledger()
        let now = Date()
        ledger.add(Transaction(amount: 1, date: now.addingTimeInterval(-100)))
        ledger.add(Transaction(amount: 2, date: now))
        XCTAssertEqual(ledger.transactions.map(\.amount), [2, 1])
    }

    func testLogIsCapped() {
        var ledger = Ledger()
        for i in 0..<(Ledger.maxLogEntries + 10) { ledger.appendLog("entry \(i)") }
        XCTAssertEqual(ledger.log.count, Ledger.maxLogEntries)
        XCTAssertEqual(ledger.log.first?.message, "entry \(Ledger.maxLogEntries + 9)")
    }

    func testStoreRoundTripAndTolerantDecoding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LedgerStore(url: dir.appendingPathComponent("ledger.json"))

        XCTAssertEqual(store.load(), Ledger())

        var ledger = Ledger(config: BudgetConfig(monthlyIncome: 50_000, goal: .save(10_000)))
        ledger.add(Transaction(amount: Decimal(string: "123.45")!, merchant: "Cafe"))
        try store.save(ledger)
        XCTAssertEqual(store.load(), ledger)

        // Older file without some keys still loads.
        try Data(#"{"transactions":[]}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Ledger())
    }

    func testCorruptFileIsMovedAsideNotLost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LedgerStore(url: dir.appendingPathComponent("ledger.json"))
        try Data("not json".utf8).write(to: store.url)

        let ledger = store.load()
        XCTAssertNil(ledger.config)
        XCTAssertEqual(ledger.log.count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt") })
    }
}
