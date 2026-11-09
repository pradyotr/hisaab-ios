# Hisaab

A personal iOS budget tracker for one person's own iPhone (iOS 18). It is not for the App Store.
Current stage: **zero-cost proof of concept**. After the POC works, the plan is to buy the $99/year Apple Developer account and possibly a Mac.

## What the app does

1. The user enters monthly income and **either** a savings goal **or** a spend cap. The app derives the other one. The user can also set a cycle start day (1–28, e.g. the salary date).
2. The app calculates a **daily budget**. Each day's budget is fixed at the start of the day:
   `B_d = max(S − spentBefore(d), 0) / (N − d)`. Here S is the spend cap, N is the number of days in the cycle, and d is the 0-based day index.
   Underspending raises later daily budgets and overspending lowers them. That is the "rollover". All values are derived from config + spends. Nothing derived is stored.
3. The **lock screen and home screen widgets** show today's budget, the amount used and the % used. A **hide-values mode** shows only percentages. The `Hisaab (Private)` widget always hides values, and a Settings toggle applies the same mode to the normal widget. `Hisaab (Cycle)` is a circular gauge of % of the cycle's spend cap used.
4. **Spends come from bank SMS** through a Shortcuts automation, plus manual add/edit.
   Every money movement is stored as a `Spend` entry with `kind` (spend, cardBill, savings, refund, reversal, cashback, otherCredit), `account` (bank / creditCard), `card`, `ref`, `reverses` and `excluded`. `Counting` (BudgetCore) turns entries into signed counted amounts: savings and otherCredit count 0, credits count negative on their own date, a linked reversal cancels its original, and a card bill counts only what open card charges (minus card credits) do not cover. The engine applies `Counting` to ALL entries before any budget math. Never count twice, and never count only one cycle's entries. Savings are reported as `CycleSummary.invested`.
5. **Charts:** green bars above zero mean saved, red bars below zero mean exceeded.
   - Daily chart: `B_d − spent_d`.
   - Monthly chart: `S − totalSpent`.
   - These do NOT add up to each other, by design. Each daily budget is recalculated from what is left. Don't "fix" this.

## Hard platform constraints (don't propose things that break these)

- **No Mac.** Development happens on Windows. Builds run only on GitHub Actions `macos-latest`. No simulator, no Xcode debugger, no previews. Use the in-app **Debug log** and **Test SMS parser** screens to debug on the device.
- **Free Apple ID sideloading with AltStore Classic** (AltServer on Windows):
  - Sideloadly is ruled out: we tested it and it drops the App Group, so the widget sees no data.
  - The app expires after 7 days. Refresh it in AltStore, or install over the old app to keep the data.
  - Limits: 3 apps, 10 App IDs per week. App + widget = 2 App IDs.
  - Developer Mode must be on.
- **iOS cannot read other apps' notifications or the SMS inbox.** The only SMS path is a Shortcuts personal automation (Message trigger, "Run Immediately") that calls the `LogBankSMSIntent` App Intent with the message text. Don't suggest notification listeners, SMS inbox access, or `ILMessageFilterExtension` (that one only sees unknown senders and can't share data).
- **No continuous background execution.** Work happens when:
  - the App Intent runs (Shortcuts launches the app process in the background), or
  - the app is opened, or
  - the widget timeline reloads. The widget has an entry at "now" and one at the next midnight. `WidgetCenter.reloadAllTimelines()` is called after every change.
- **Widgets are SwiftUI + WidgetKit, native only.** This is why the app is Swift/SwiftUI and not Flutter or React Native.

## Layout

```
project.yml                  XcodeGen spec (Hisaab.xcodeproj is generated in CI and NOT committed)
scripts/build-ipa.sh         macOS-only: xcodegen → xcodebuild (unsigned) → ad-hoc codesign with entitlements → build/Hisaab.ipa
.github/workflows/build.yml  test-core (ubuntu, swift test) → build-ipa (macos) → artifact "Hisaab-ipa"
Packages/BudgetCore/         Pure Swift package: BudgetEngine, SMSParser, Spend, Ledger/LedgerStore + XCTest tests
Shared/                      Compiled into BOTH app and widget: AppGroup (storage location), Format
App/                         SwiftUI app: LedgerModel, Views/, Intents/LogBankSMSIntent.swift
Widget/                      WidgetKit widgets: lock screen (accessoryRectangular / Circular / Inline) + home screen (systemSmall / Medium)
```

## Rules for working in this repo

- **BudgetCore must stay pure Foundation.** Don't import SwiftUI, UIKit, WidgetKit or AppIntents there. It has to build on Linux CI and on Windows. Use `NSRegularExpression`, not Swift `Regex` literals.
- **Any change to the budget math or the parser needs tests** in `Packages/BudgetCore/Tests`. These are the only automated checks. The iOS code is only checked when CI compiles it.
- **SMS samples in tests must be anonymised:** masked account numbers (XX1234), made-up balances and reference numbers. Never commit the user's real SMS text.
- **Storage** is one JSON file (`ledger.json`) in the App Group container, written by `LedgerStore`. Always use `store.update { }`, which re-reads before writing, because the App Intent may have written in the background. Keep decoding tolerant: new fields use `decodeIfPresent` with a default. `LedgerStore` wraps load/save/update in `NSFileCoordinator` on Apple platforms (never nest them). When the stored shape changes, bump `Ledger.currentSchemaVersion` and add a step in `Ledger.migrate()`. Spend amounts are encoded as strings to keep `Decimal` precise.
- **App Group ID** lives in two places that must match: `project.yml` (both entitlements) and `Shared/AppGroup.swift` (`defaultID`). AltStore may rewrite the ID; `AppGroup.id` reads `ALTAppGroups` from Info.plist for that case. Settings → Diagnostics shows whether shared storage works.
- **Don't reuse SwiftUI type or modifier names** for models or view properties: `Transaction`, `Animation`, `Text`, `Color`, `Label` and so on. The spend model is called `Spend` because `Transaction` clashed with SwiftUI's type and broke the first CI build. View properties holding a spend are called `spend`, not `transaction`, because `View.transaction(_:)` exists.
- **Swift language mode 5** (`SWIFT_VERSION 5.0`, tools 5.9) to avoid Swift 6 strict-concurrency errors. Deployment target is iOS 17.
- **I can't compile iOS code locally.** Write conservative, well-known SwiftUI/WidgetKit/AppIntents APIs. After changing app or widget code, the real check is a CI run (`ship-build` skill). Read the failure with `gh run view --log-failed` and fix it.
- Don't commit or push unless the user asks.
- Currency defaults to INR (the user is in India). Amounts are formatted with no decimals in the UI.

## Known POC limitations / next steps

- Past cycles are summarised with the *current* config. To fix: store config history.
- Parser = ignore rules + `SMSRule.bankRules` + `SMSRule.generic`. Add bank-specific rules from real (anonymised) samples with the `add-sms-format` skill.
- Categories are user-created (`SpendCategory`, not `Category`, which clashes with an Objective-C type). `Spend.sources` records who decided each field; only `.user` values may train predictions. Category prediction is not built yet.
- No iCloud backup (Settings has a JSON export). App icon is a placeholder (App/Assets.xcassets/AppIcon.appiconset/AppIcon.png, 1024x1024 RGB, no transparency).
- After paying for the developer account: TestFlight/1-year signing, and Xcode on a Mac or a cloud Mac for real debugging.

## Skills

- `ship-build`: trigger CI, wait for it, download the `.ipa`, and give the sideload steps. Diagnose CI failures.
- `add-sms-format`: turn a pasted bank SMS into a parser rule + tests.
- `test-core`: run the BudgetCore tests (locally if Swift is installed, otherwise through CI).
