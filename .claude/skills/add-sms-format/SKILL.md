---
name: add-sms-format
description: Teach Hisaab's SMS parser a new bank/UPI/card message format, or fix a message it parses wrongly or ignores. Use when the user pastes a bank SMS, says a spend was not logged, was logged with the wrong amount or merchant, or a credit/OTP was logged as a spend.
---

# Add or fix an SMS format

The parser lives in `Packages/BudgetCore/Sources/BudgetCore/SMSParser.swift`. It works in this order:

1. `SMSParser.ignoreRules`: any match means "not a completed spend" (OTP, refund, upcoming autopay, UPI request, failed).
2. `SMSRule.bankRules`: specific rules, tried in order.
3. `SMSRule.generic`: the fallback.
4. Otherwise "credit" or "no rule matched".

All patterns are case-insensitive `NSRegularExpression` strings written as raw strings (`#"..."#`). Don't use Swift `Regex`, because BudgetCore must build on Linux and Windows.

## Steps

1. **Anonymise the sample first.** Replace the account or card number with `XX1234`, the balance with a made-up value, ref/UPI IDs with `1234`, and personal names with `John Doe`. Keep the bank's wording, punctuation and spacing exactly as they are, because those are what the regex depends on. Never write the user's real SMS into the repo.

2. **Decide what it should produce:** a debit (amount + optional merchant), or ignored. Credits, refunds, OTPs, reminders, "will be debited" and failed transactions must be ignored.

3. **Write the failing test first** in `Packages/BudgetCore/Tests/BudgetCoreTests/SMSParserTests.swift`, using the `assertDebit(text, "amount", merchant:)` or `assertIgnored(text)` helpers. Name the test after the bank and format, e.g. `testExampleBankCardSpend`.

4. **Fix it with the smallest change**, in this order of preference:
   - If the message should be ignored, add or extend an entry in `ignoreRules`. Check that no existing debit tests start matching it.
   - If `generic` almost works, adjust it only when the change is clearly general.
   - Otherwise add an `SMSRule` to `bankRules` with:
     - a unique `id` like `"bankname-format"`,
     - a narrow `mustMatch` (bank name or a fixed phrase plus the debit verb),
     - an `amount` pattern whose capture group 1 is the number.
   - `firstAmount` already skips amounts preceded by bal/avl/limit/lmt.

5. **Run the tests** with the `test-core` skill. All existing parser tests must still pass, since one regex can break many messages.

6. **Tell the user** which rule now handles the message. On the phone, they can check it under Settings → Test SMS parser once a new build is installed. If they want a new build, use the `ship-build` skill.

## Notes

- The Shortcuts automation decides *which* messages reach the app (sender or "contains" filter). If a spend never shows up in the in-app **Debug log**, the automation didn't fire. That isn't a parser bug. Ask the user to check the automation's trigger and that "Run Immediately" is set.
- Duplicate protection: the same SMS text within 10 minutes is skipped (`Ledger.add`).
