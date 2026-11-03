# Hisaab

A personal budget tracker for iPhone. It shows a daily spend budget on the lock screen, tracks spends from bank SMS through a Shortcuts automation, and charts what you saved or overspent each day and month.

You build it on Windows without paying anything: GitHub Actions compiles it, and Sideloadly or AltStore installs it with a free Apple ID (the app lasts 7 days per install).

## First-time setup

1. **Create a GitHub repo and push.**
   ```
   git add -A && git commit -m "Hisaab scaffold"
   gh repo create hisaab --private --source . --push
   ```
   Public repos get unlimited free macOS build minutes. Private repos get about 200 a month, and one build takes about 5–10 minutes.
2. **Wait for the `Build` workflow** in the Actions tab, then download the `Hisaab-ipa` artifact (or run `gh run download -n Hisaab-ipa`).
3. **Install it with Sideloadly** (Windows):
   - Install iTunes and iCloud from apple.com (not the Microsoft Store).
   - Connect the iPhone, drag in `Hisaab.ipa`, and sign in with your Apple ID.
4. **On the iPhone:**
   - Settings → General → VPN & Device Management → trust your Apple ID.
   - Settings → Privacy & Security → Developer Mode → On.
5. **In Hisaab:** enter your income and goal. Then go to **Settings → Diagnostics** and check that *Shared storage* says **OK**. If it says NOT SHARED, re-install with AltStore so the widget can read the data.
6. **Lock screen:** long-press the lock screen → Customize → add the **Hisaab** or **Hisaab (Private)** widget.
7. **SMS automation:**
   - Shortcuts → Automation → + → **Message**.
   - Pick your bank as the sender, or use *contains "debited"*.
   - Choose **Run Immediately**.
   - Add the action **Log Bank SMS** and set Message to *Shortcut Input → Content*.

Re-sign every 7 days by installing the new or same `.ipa` over the existing app. Your data is kept.

See `CLAUDE.md` for the architecture, the budget formula and the constraints.
