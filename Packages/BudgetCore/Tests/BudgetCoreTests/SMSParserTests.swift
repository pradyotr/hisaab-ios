import XCTest
@testable import BudgetCore

/// Samples are anonymised. NEVER paste real account numbers, balances or reference IDs here.
final class SMSParserTests: XCTestCase {
    private let parser = SMSParser()

    private func assertDebit(_ text: String, _ amount: String, merchant: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case .debit(let parsed) = parser.parse(text) else {
            return XCTFail("Expected debit, got \(parser.parse(text)) for: \(text)", file: file, line: line)
        }
        XCTAssertEqual(parsed.amount, Decimal(string: amount), file: file, line: line)
        if let merchant {
            XCTAssertEqual(parsed.merchant?.lowercased(), merchant.lowercased(), file: file, line: line)
        }
    }

    private func assertIgnored(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .debit(let parsed) = parser.parse(text) {
            XCTFail("Expected ignored, got debit \(parsed) for: \(text)", file: file, line: line)
        }
    }

    // MARK: Debits

    func testUPIDebitWithBalance() {
        assertDebit("Rs.500.00 debited from A/c XX1234 on 03-11-26 to VPA swiggy@icici. Ref 1234. Avl Bal Rs 10,234.50",
                    "500.00", merchant: "swiggy@icici")
    }

    func testCardSpendWithLimit() {
        assertDebit("INR 1,249.00 spent on Bank Card XX1234 at AMAZON PAY on 03-11-26. Avl Lmt: INR 50,000.00",
                    "1249.00", merchant: "AMAZON PAY")
    }

    func testBalanceBeforeAmountIsSkipped() {
        assertDebit("Avl Bal Rs 9,000.00. Rs 250 debited from A/c XX1234 to merchant@upi on 03-11", "250")
    }

    func testRupeeSymbolAndSent() {
        assertDebit("Sent ₹1,20,000 from A/c XX1234 to John Doe on 03-11. Not you? Call 1800", "120000", merchant: "John Doe")
    }

    func testDebitedAndCreditedToMerchant() {
        assertDebit("Rs 500 debited from A/c XX1234 and credited to zomato@upi", "500", merchant: "zomato@upi")
    }

    func testATMWithdrawal() {
        assertDebit("Rs.2000 withdrawn at ATM XYZ123 from A/c XX1234 on 03-11-26", "2000")
    }

    // MARK: Ignored

    func testOTPIgnored() {
        assertIgnored("123456 is the OTP for txn of Rs 500 at XYZ. Do not share it with anyone.")
    }

    func testSalaryCreditIgnored() {
        assertIgnored("Rs 50,000.00 credited to your A/c XX1234 by SALARY on 01-11")
    }

    func testRefundIgnored() {
        assertIgnored("Refund of Rs 300 has been credited to your card XX1234")
    }

    func testUpcomingAutopayIgnored() {
        assertIgnored("Rs 199 will be debited on 05-11 for STREAMING autopay")
    }

    func testCollectRequestIgnored() {
        assertIgnored("friend@upi has requested money Rs 400 from you. Pay via any UPI app")
    }

    func testFailedIgnored() {
        assertIgnored("Txn of Rs 999 at SHOP on card XX1234 declined due to insufficient funds")
    }

    func testRandomMessageIgnored() {
        assertIgnored("Your order has been shipped and will arrive tomorrow")
    }

    // MARK: Amount helper

    func testAmountParse() {
        XCTAssertEqual(Amount.parse("1,23,456.50"), Decimal(string: "123456.50"))
        XCTAssertEqual(Amount.parse("₹ 500"), 500)
        XCTAssertEqual(Amount.parse("Rs.99"), 99)
        XCTAssertNil(Amount.parse("abc"))
        XCTAssertNil(Amount.parse("1.2.3"))
        XCTAssertNil(Amount.parse(""))
    }
}
