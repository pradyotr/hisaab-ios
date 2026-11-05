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
        let result = parser.parse(text)
        if let parsed = result.parsed {
            XCTFail("Expected ignored, got \(result) (\(parsed.kind)) for: \(text)", file: file, line: line)
        }
    }

    /// Checks kind, account and card of a debit or credit.
    private func assertKind(_ text: String, _ kind: EntryKind, account: PaymentAccount = .bank, card: String? = nil,
                            amount: String? = nil, parser: SMSParser = SMSParser(),
                            file: StaticString = #filePath, line: UInt = #line) {
        let result = parser.parse(text)
        guard let parsed = result.parsed else {
            return XCTFail("Expected an entry, got \(result) for: \(text)", file: file, line: line)
        }
        switch result {
        case .debit: XCTAssertFalse(kind.isCredit, "parsed as debit", file: file, line: line)
        case .credit: XCTAssertTrue(kind.isCredit, "parsed as credit", file: file, line: line)
        case .ignored: break
        }
        XCTAssertEqual(parsed.kind, kind, file: file, line: line)
        XCTAssertEqual(parsed.account, account, file: file, line: line)
        XCTAssertEqual(parsed.card, card, file: file, line: line)
        if let amount {
            XCTAssertEqual(parsed.amount, Decimal(string: amount), file: file, line: line)
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
        assertKind("Rs 500 debited from A/c XX1234 and credited to zomato@upi for payment", .spend)
    }

    func testATMWithdrawal() {
        assertDebit("Rs.2000 withdrawn at ATM XYZ123 from A/c XX1234 on 03-11-26", "2000")
    }

    func testReferenceNumber() {
        let parsed = parser.parse("Rs.500.00 debited from A/c XX1234 to VPA shop@upi on 03-11-26. UPI Ref No 612345678901").parsed
        XCTAssertEqual(parsed?.ref, "612345678901")
        XCTAssertEqual(parser.parse("Txn of Rs 75 debited from A/c XX1234. RRN: 445566778").parsed?.ref, "445566778")
        // Short numbers are not references (too easy to confuse with dates / account digits).
        XCTAssertNil(parser.parse("Rs.500.00 debited from A/c XX1234 to shop@upi. Ref 1234").parsed?.ref)
    }

    // MARK: Ignored

    func testOTPIgnored() {
        assertIgnored("123456 is the OTP for txn of Rs 500 at XYZ. Do not share it with anyone.")
    }

    func testUpcomingAutopayIgnored() {
        assertIgnored("Rs 199 will be debited on 05-11 for STREAMING autopay")
    }

    func testUpcomingRefundIgnored() {
        assertIgnored("Your UPI txn of Rs 500 failed. The amount will be reversed to your A/c XX1234 within 3 days")
        assertIgnored("Refund of Rs 300 initiated for your order. It will reflect in 5-7 days")
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

    // MARK: Credits

    func testRefund() {
        assertKind("Refund of Rs 300 has been credited to your card XX1234", .refund, amount: "300")
    }

    func testRefundToCreditCard() {
        assertKind("Rs 1,200.00 refunded to your Credit Card XX5678 by FLIPKART on 04-11-26", .refund,
                   account: .creditCard, card: "5678", amount: "1200.00")
    }

    func testReversal() {
        assertKind("Rs.500.00 reversed to your A/c XX1234 on 04-11-26. UPI Ref No 612345678901", .reversal, amount: "500.00")
        XCTAssertEqual(parser.parse("Rs.500.00 reversed to your A/c XX1234 on 04-11-26. UPI Ref No 612345678901").parsed?.ref,
                       "612345678901")
    }

    func testFailedTxnRefundIsAReversal() {
        assertKind("Your txn of Rs 500 failed and the amount has been refunded to A/c XX1234", .reversal, amount: "500")
    }

    func testCashback() {
        assertKind("Cashback of Rs 25 credited to your A/c XX1234 for txn paid at SHOP", .cashback, amount: "25")
    }

    func testCashbackAdInADebitIsStillADebit() {
        assertKind("Rs 500 spent on Debit Card XX1234 at SHOP. Get 5% cashback on your next order", .spend, amount: "500")
    }

    func testSalaryIsOtherCredit() {
        guard case .credit(let parsed) = parser.parse("Rs 50,000.00 credited to your A/c XX1234 by SALARY on 01-11") else {
            return XCTFail("Expected credit")
        }
        XCTAssertEqual(parsed.kind, .otherCredit)
        XCTAssertEqual(parsed.amount, 50_000)
        XCTAssertEqual(parsed.merchant, "SALARY")
    }

    func testUPIReceived() {
        assertKind("You have received Rs 400 from friend@upi in your A/c XX1234", .otherCredit, amount: "400")
    }

    // MARK: Credit cards

    func testCreditCardSpend() {
        assertKind("Rs.1,499.00 spent on your Credit Card XX5678 at FLIPKART on 03-11-26. Avl Lmt Rs 45,000",
                   .spend, account: .creditCard, card: "5678", amount: "1499.00")
    }

    func testDebitCardIsBank() {
        assertKind("Rs.250 spent on Debit Card XX1234 at CAFE on 03-11-26. Avl Bal Rs 9,000", .spend)
    }

    func testAmbiguousCardIsBankUnlessRegistered() {
        let sms = "INR 1,249.00 spent on Bank Card XX5678 at AMAZON PAY on 03-11-26. Avl Lmt: INR 50,000.00"
        assertKind(sms, .spend)
        assertKind(sms, .spend, account: .creditCard, card: "5678", parser: SMSParser(creditCards: ["XX5678"]))
        assertKind(sms, .spend, parser: SMSParser(creditCards: ["9999"]))
    }

    func testCardBillFromBankAccount() {
        assertKind("Rs 15,000.00 debited from A/c XX1234 towards your Bank Credit Card XX5678 on 02-11-26. Ref 998877",
                   .cardBill, card: "5678", amount: "15000.00")
    }

    func testCardBillPaymentWording() {
        assertKind("Your A/c XX1234 is debited for Rs 8,200 on 02-11 for Credit Card bill payment. Ref 112233",
                   .cardBill, amount: "8200")
    }

    func testCardBillViaCRED() {
        assertKind("Rs.12,000 debited from A/c XX1234 to VPA cred.club@upi on 02-11-26. Ref 445566", .cardBill, amount: "12000")
    }

    func testRegisteredCardBillWithoutCreditCardWords() {
        assertKind("Rs 6,000 debited from A/c XX1234 towards Card XX5678 on 02-11-26", .cardBill, card: "5678",
                   parser: SMSParser(creditCards: ["5678"]))
    }

    func testBillMerchantFallback() {
        guard case .debit(let parsed) = parser.parse("Rs 900 paid towards your Credit Card XX5678") else {
            return XCTFail("Expected debit")
        }
        XCTAssertEqual(parsed.kind, .cardBill)
        XCTAssertEqual(parsed.merchant, "Credit card bill")
    }

    func testIssuerPaymentReceivedIgnored() {
        assertIgnored("Payment of Rs 15,000.00 received towards your Credit Card XX5678. Thank you.")
        assertIgnored("We have received your payment of INR 8,200 for Card XX5678 on 02-11-26")
    }

    func testCardBillReminderIgnored() {
        assertIgnored("Your Credit Card XX5678 bill of Rs 15,000 is due on 10-11-26. Pay now to avoid charges.")
    }

    // MARK: Savings

    func testInvestmentPlatformIsSavings() {
        assertKind("Rs 5,000.00 debited from A/c XX1234 to VPA groww.iccl@validupi on 05-11-26. UPI Ref No 712345678901",
                   .savings, amount: "5000.00")
    }

    func testSIPMandateIsSavings() {
        assertKind("Your A/c XX1234 has been debited with INR 2,000.00 towards NACH for ICCL MUTUAL FUND SIP on 05-11",
                   .savings, amount: "2000.00")
    }

    func testUserSavingsKeyword() {
        let sms = "Rs 3,000 sent from A/c XX1234 to MyBroker Ltd on 05-11"
        assertKind(sms, .spend)
        assertKind(sms, .savings, parser: SMSParser(savingsKeywords: ["mybroker", "  "]))
    }

    func testCardBillWinsOverSavingsWords() {
        // "SIP" never names a card bill, but a card bill must not become savings because of other words.
        assertKind("Rs 4,000 debited from A/c XX1234 for Credit Card bill payment via BSE gateway", .cardBill)
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
