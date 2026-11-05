import XCTest
@testable import BudgetCore

final class LedgerTests: XCTestCase {
    func testDuplicateSMSIsSkipped() {
        var ledger = Ledger()
        let now = Date()
        let sms = "Rs 500 debited from A/c XX1234 to shop@upi"
        XCTAssertTrue(ledger.add(Spend(amount: 500, date: now, source: .sms, rawText: sms)))
        XCTAssertFalse(ledger.add(Spend(amount: 500, date: now.addingTimeInterval(30), source: .sms, rawText: sms)))
        XCTAssertTrue(ledger.add(Spend(amount: 500, date: now.addingTimeInterval(3_600), source: .sms, rawText: sms)))
        XCTAssertEqual(ledger.transactions.count, 2)
    }

    func testManualEntriesAreNeverDeduped() {
        var ledger = Ledger()
        XCTAssertTrue(ledger.add(Spend(amount: 50)))
        XCTAssertTrue(ledger.add(Spend(amount: 50)))
    }

    func testTransactionsSortedNewestFirst() {
        var ledger = Ledger()
        let now = Date()
        ledger.add(Spend(amount: 1, date: now.addingTimeInterval(-100)))
        ledger.add(Spend(amount: 2, date: now))
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
        ledger.add(Spend(amount: Decimal(string: "123.45")!, merchant: "Cafe"))
        try store.save(ledger)
        XCTAssertEqual(store.load(), ledger)

        // Older file without some keys still loads.
        try Data(#"{"transactions":[]}"#.utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Ledger())
    }

    // MARK: Duplicates by reference number

    func testSameReferenceFromTwoSendersIsADuplicate() {
        var ledger = Ledger()
        let now = Date()
        XCTAssertTrue(ledger.add(Spend(amount: 500, date: now, source: .sms, rawText: "bank text", ref: "612345678901")))
        XCTAssertFalse(ledger.add(Spend(amount: 500, date: now, source: .sms, rawText: "upi app text", ref: "612345678901")))
        // Same reference but money coming back is the reversal, not a duplicate.
        XCTAssertTrue(ledger.add(Spend(amount: 500, date: now.addingTimeInterval(60), source: .sms,
                                       rawText: "reversal text", kind: .reversal, ref: "612345678901")))
        XCTAssertEqual(ledger.transactions.count, 2)
    }

    // MARK: Reversal linking

    func testReversalLinksByReference() {
        var ledger = Ledger()
        let now = Date()
        let original = Spend(amount: 500, date: now.addingTimeInterval(-3_600), ref: "612345678901")
        let other = Spend(amount: 500, date: now.addingTimeInterval(-60))
        ledger.add(original)
        ledger.add(other)
        ledger.add(Spend(amount: 500, date: now, kind: .reversal, ref: "612345678901"))
        XCTAssertEqual(ledger.transactions.first { $0.kind == .reversal }?.reverses, original.id)
    }

    func testReversalLinksToMostRecentSameAmountInWindow() {
        var ledger = Ledger()
        let now = Date()
        let tooOld = Spend(amount: 500, date: now.addingTimeInterval(-8 * 86_400))
        let older = Spend(amount: 500, date: now.addingTimeInterval(-2 * 86_400))
        let recent = Spend(amount: 500, date: now.addingTimeInterval(-3_600))
        let otherAmount = Spend(amount: 499, date: now.addingTimeInterval(-60))
        [tooOld, older, recent, otherAmount].forEach { ledger.add($0) }

        ledger.add(Spend(amount: 500, date: now, kind: .reversal))
        ledger.add(Spend(amount: 500, date: now.addingTimeInterval(1), kind: .reversal))
        ledger.add(Spend(amount: 500, date: now.addingTimeInterval(2), kind: .reversal))
        let links = ledger.transactions.filter { $0.kind == .reversal }.sorted { $0.date < $1.date }.map(\.reverses)
        XCTAssertEqual(links, [recent.id, older.id, nil]) // each debit is claimed once; tooOld is outside the window
    }

    func testRemovingOriginalExcludesItsReversal() {
        var ledger = Ledger()
        let original = Spend(amount: 500, date: Date().addingTimeInterval(-60))
        ledger.add(original)
        ledger.add(Spend(amount: 500, kind: .reversal))
        ledger.remove(ids: [original.id])
        let reversal = ledger.transactions.first
        XCTAssertNil(reversal?.reverses)
        XCTAssertEqual(reversal?.excluded, true)
        XCTAssertTrue(Counting.countedEntries(ledger.transactions).isEmpty)
    }

    // MARK: Schema

    func testOldFileIsMigrated() throws {
        let json = #"{"transactions":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","amount":"250","date":0,"source":"sms"}],"settings":{"hideValues":true}}"#
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(json.utf8))
        XCTAssertEqual(ledger.schemaVersion, Ledger.currentSchemaVersion)
        let spend = try XCTUnwrap(ledger.transactions.first)
        XCTAssertEqual(spend.kind, .spend)
        XCTAssertEqual(spend.account, .bank)
        XCTAssertNil(spend.card)
        XCTAssertNil(spend.ref)
        XCTAssertNil(spend.reverses)
        XCTAssertFalse(spend.excluded)
        XCTAssertTrue(ledger.settings.hideValues)
        XCTAssertEqual(ledger.settings.creditCards, [])
        XCTAssertEqual(ledger.settings.savingsKeywords, [])
    }

    func testUnknownKindFromNewerBuildFallsBack() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","amount":"250","date":0,"kind":"somethingNew","account":"wallet"}"#
        let spend = try JSONDecoder().decode(Spend.self, from: Data(json.utf8))
        XCTAssertEqual(spend.kind, .spend)
        XCTAssertEqual(spend.account, .bank)
    }

    func testAllFieldsRoundTrip() throws {
        let spend = Spend(amount: Decimal(string: "99.50")!, merchant: "Shop", source: .sms, rawText: "text",
                          kind: .reversal, account: .creditCard, card: "5678", ref: "612345678901",
                          reverses: UUID(), excluded: true)
        let decoded = try JSONDecoder().decode(Spend.self, from: JSONEncoder().encode(spend))
        XCTAssertEqual(decoded, spend)
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
