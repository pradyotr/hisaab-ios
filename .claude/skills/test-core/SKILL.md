---
name: test-core
description: Run the BudgetCore unit tests (budget math, SMS parser, ledger storage) and interpret failures. Use after changing anything in Packages/BudgetCore, when the user asks to "run tests", or when the test-core CI job fails.
---

# Run BudgetCore tests

BudgetCore is pure Foundation, so its tests run anywhere Swift runs. The iOS app and the widget can only be compiled in CI (see `ship-build`).

## Option A: locally (preferred when available)

1. Check for Swift: `swift --version`.
2. If it's installed, run `swift test --package-path Packages/BudgetCore` from the repo root.
   - Swift on Windows also needs the Visual Studio C++ build tools. If you get linker or SDK errors, the problem is the toolchain, not the code. Say so and use option B.
3. If Swift isn't installed, the user can install it with `winget install --id Swift.Toolchain -e` (official toolchain; also needs Visual Studio Build Tools with the "Desktop development with C++" workload). Offer this once. Don't install it without asking.

## Option B: CI

The `test-core` job (ubuntu-latest) runs the same `swift test` on every push to `main`, on PRs, and on `workflow_dispatch`.

1. Get the user's OK, then push. Or run `gh workflow run build.yml --ref <branch>` for the current pushed branch.
2. Run `gh run watch <id> --exit-status`, then `gh run view <id> --log-failed` if it fails.

## Reading failures

- Each `XCTAssertEqual` failure shows the expected and actual values. In parser tests, the message text is in the failure output.
- Budget math tests use a fixed UTC Gregorian calendar and November 2026 (30 days). If you add date-based tests, build the dates with the same `date(y, m, d, h)` helper so time zones don't cause flaky results.
- If a budget formula changes, update `CLAUDE.md` ("What the app does" section) to match. The formula is documented there and in the `BudgetEngine` doc comment.
