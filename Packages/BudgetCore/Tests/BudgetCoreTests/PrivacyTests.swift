import XCTest
@testable import BudgetCore

/// Data minimisation and erasure. All SMS here are made up.
final class PrivacyTests: XCTestCase {
    private let sms = "Rs.1,250.00 debited from A/c XX4821 on 03-11-26 to 9876543210@ybl. UPI Ref 512398765432. Avl Bal Rs.18,402.17"

    // MARK: Redaction

    func testRedactionRemovesEveryNumber() {
        let redacted = SMSRedaction.redact(sms)
        XCTAssertFalse(redacted.contains { $0.isNumber }, redacted)
        XCTAssertEqual(redacted, "Rs.*,*.* debited from A/c XX* on *-*-* to *@ybl. UPI Ref *. Avl Bal Rs.*,*.*")
        XCTAssertEqual(SMSRedaction.redact(redacted), redacted, "redacting twice changes nothing")
    }

    func testRedactionKeepsPaymentMethod() {
        func method(_ text: String) -> PaymentMethod { Spend(amount: 1, source: .sms, rawText: text).method }
        let samples = [
            "Rs 10 debited from A/c XX1234 to 9876543210@ybl",
            "Rs 10 spent on Debit Card XX1234 at SHOP",
            "Rs 10 withdrawn at ATM using Debit Card XX1234",
            "Rs 10 debited by NEFT from A/c XX1234",
        ]
        for text in samples {
            XCTAssertEqual(method(SMSRedaction.redact(text)), method(text), text)
        }
        XCTAssertEqual(method(SMSRedaction.redact(samples[0])), .upi)
    }

    func testRedactionKeepsLearningFeatures() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let raw = Spend(amount: 1_250, date: date, merchant: "9876543210@ybl", source: .sms, rawText: sms)
        var redacted = raw
        redacted.rawText = SMSRedaction.redact(sms)
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(Set(FeatureExtractor.features(of: redacted, calendar: calendar, cycleStartDay: 1)),
                       Set(FeatureExtractor.features(of: raw, calendar: calendar, cycleStartDay: 1)))
    }

    // MARK: Retention

    func testOldSMSTextIsRedactedAndRecentIsKept() {
        let now = Date()
        var ledger = Ledger()
        ledger.add(Spend(amount: 1_250, date: now.addingTimeInterval(-Ledger.fullSMSRetention - 60), source: .sms,
                         rawText: sms, ref: "512398765432"))
        ledger.add(Spend(amount: 99, date: now.addingTimeInterval(-3_600), source: .sms, rawText: "Rs 99 debited A/c XX4821"))

        XCTAssertTrue(ledger.applyRetention(now: now))
        let old = ledger.transactions.first { $0.amount == 1_250 }
        XCTAssertEqual(old?.rawText, SMSRedaction.redact(sms))
        XCTAssertEqual(old?.ref, "512398765432", "parsed fields are kept for reversal matching")
        XCTAssertEqual(ledger.transactions.first { $0.amount == 99 }?.rawText, "Rs 99 debited A/c XX4821")

        XCTAssertFalse(ledger.applyRetention(now: now), "nothing left to change, so no save is needed")
    }

    func testOldLogEntriesLoseTextThenAreDeleted() {
        let now = Date()
        var ledger = Ledger()
        ledger.appendLog("very old", rawText: sms, at: now.addingTimeInterval(-Ledger.logRetention - 60))
        ledger.appendLog("old", rawText: sms, at: now.addingTimeInterval(-Ledger.fullSMSRetention - 60))
        ledger.appendLog("new", rawText: sms, at: now)

        ledger.applyRetention(now: now)
        XCTAssertEqual(ledger.log.map(\.message), ["new", "old"])
        XCTAssertEqual(ledger.log.map(\.rawText), [sms, nil])
    }

    func testKeepFullSMSTextTurnsRetentionOff() {
        let now = Date()
        var ledger = Ledger(settings: AppSettings(keepFullSMSText: true))
        ledger.add(Spend(amount: 1_250, date: now.addingTimeInterval(-Ledger.logRetention - 60), source: .sms, rawText: sms))
        ledger.appendLog("very old", rawText: sms, at: now.addingTimeInterval(-Ledger.logRetention - 60))

        XCTAssertFalse(ledger.applyRetention(now: now))
        XCTAssertEqual(ledger.transactions.first?.rawText, sms)
        XCTAssertEqual(ledger.log.first?.rawText, sms)
    }

    func testIgnoredSMSTextIsNotLogged() {
        var ledger = Ledger()
        ledger.appendSMSLog("Ignored: no amount", sms: "Hi, dinner at 8?", logged: false)
        ledger.appendSMSLog("Logged 1250", sms: sms, logged: true)
        XCTAssertEqual(ledger.log.map(\.rawText), [sms, nil])

        ledger.settings.keepFullSMSText = true
        ledger.appendSMSLog("Ignored: no amount", sms: "Hi, dinner at 8?", logged: false)
        XCTAssertEqual(ledger.log.first?.rawText, "Hi, dinner at 8?")
    }

    func testPrivacySettingsDecodeWithDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hideValues":true}"#.utf8))
        XCTAssertFalse(settings.keepFullSMSText)
        XCTAssertFalse(settings.hideWidgetsWhenLocked)
        let all = AppSettings(keepFullSMSText: true, hideWidgetsWhenLocked: true)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(all)), all)
    }

    // MARK: Erasure

    func testDeleteAllRemovesLedgerAndCorruptCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LedgerStore(url: dir.appendingPathComponent("ledger.json"))
        var ledger = Ledger(config: BudgetConfig(monthlyIncome: 50_000, goal: .save(10_000)))
        ledger.add(Spend(amount: 10, source: .sms, rawText: sms))
        try store.save(ledger)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("ledger.corrupt-1.json"))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("widget-skips.json"))

        try store.deleteAll()
        XCTAssertEqual(store.load(), Ledger())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["widget-skips.json"],
                       "only the store's own files are deleted; the app removes the rest")
        XCTAssertNoThrow(try store.deleteAll(), "deleting twice is fine")
    }
}
