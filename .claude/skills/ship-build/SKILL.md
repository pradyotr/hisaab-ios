---
name: ship-build
description: Build the Hisaab .ipa on GitHub Actions, wait for the result, download the artifact and walk the user through sideloading it to their iPhone with a free Apple ID. Use when the user says "build", "ship", "new ipa", "install on my phone", "re-sign", "app expired", or after app/widget code changes need verification. Also diagnoses CI build failures.
---

# Ship a Hisaab build

There is no Mac. The only way to compile iOS code is the `Build` workflow (`.github/workflows/build.yml`) on GitHub Actions.

## 1. Preconditions

- `gh auth status` must succeed. If it doesn't, ask the user to run `! gh auth login`.
- The repo needs a GitHub remote (`git remote -v`). If there is none, tell the user and offer to run `gh repo create hisaab --private --source . --push`. Only do this after they agree. Private repos get about 200 free macOS minutes a month (macOS minutes count 10×). Public repos are unlimited.
- **Never commit or push without the user asking.** If there are uncommitted changes, show `git status --short` and ask.

## 2. Run the workflow

- If the user approved a push to `main`, the push triggers the workflow.
- Otherwise run `gh workflow run build.yml --ref <branch>`.
- Find the run: `gh run list --workflow build.yml --limit 1 --json databaseId,status,headSha`.
- Wait for it: `gh run watch <id> --exit-status` (run in the background; a build takes about 5–10 minutes).

## 3. If it fails

1. Run `gh run view <id> --log-failed`. Swift compile errors look like `path/File.swift:LINE:COL: error: ...`.
2. The full xcodebuild log is the `xcodebuild-log` artifact: `gh run download <id> -n xcodebuild-log -D build/`.
3. Fix the cause in the source.
   - `test-core` failures are BudgetCore test failures. Use the `test-core` skill.
   - Don't silence errors with `#if` or by deleting features without telling the user.
4. Ask before committing and pushing the fix, then re-run.

## 4. Download

```
gh run download <id> -n Hisaab-ipa -D build/
```

The result is `build/Hisaab.ipa`. It is ad-hoc signed only, so it won't install as-is. It has to be re-signed.

## 5. Tell the user how to install it (Windows)

**Sideloadly** (simplest):
1. Install iTunes and iCloud from Apple's website, not the Microsoft Store versions.
2. Connect the iPhone by USB and trust the computer.
3. Drag `build/Hisaab.ipa` into Sideloadly, enter the Apple ID, and click Start.
4. On the iPhone:
   - Settings → General → VPN & Device Management → trust your Apple ID.
   - Settings → Privacy & Security → Developer Mode → On (needs a restart the first time).

**If Settings → Diagnostics in the app shows "Shared storage: NOT SHARED"**, the widget can't see data. The App Group was dropped while signing. Use **AltStore** (AltServer for Windows) instead, because it registers App Groups for free accounts. `AppGroup.id` already reads AltStore's rewritten ID.

**Free account limits:**
- The app expires after 7 days. Re-run steps 3–4 with the same `.ipa` or a newer one, installing over the existing app. Data is kept as long as the app is not deleted.
- 3 sideloaded apps at a time, 10 App IDs per week. Hisaab uses 2.

After the first install, remind the user about the one-time Shortcuts automation (Settings screen in the app lists the steps) and adding the widget to the lock screen (long-press the lock screen → Customize → Lock Screen → add widget → Hisaab).
