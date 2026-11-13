import SwiftUI
import BudgetCore

struct SettingsView: View {
    @Environment(LedgerModel.self) private var model
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var newCard = ""
    @State private var newSavingsWord = ""
    @State private var export: ExportFile?
    @State private var exportError: String?
    @AppStorage(AppLock.storageKey) private var appLockEnabled = false
    @State private var appLockError: String?
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Budget") { SetupView() }
                    NavigationLink("Categories") { ManageCategoriesView() }
                    NavigationLink("Learning") { LearningView() }
                }

                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your iPhone's light or dark setting.")
                }

                Section {
                    Toggle("Lock with \(AppLock.methodName)", isOn: Binding(
                        get: { appLockEnabled },
                        set: { setAppLock($0) }
                    ))
                    if let appLockError {
                        Text(appLockError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Asks for \(AppLock.methodName) (or your passcode) when you open Hisaab. The app is always hidden in the app switcher. SMS logging and widgets keep working while the app is locked.")
                }

                Section {
                    Toggle("Hide amounts in widgets", isOn: Binding(
                        get: { model.ledger.settings.hideValues },
                        set: { model.setHideValues($0) }
                    ))
                    Toggle("Hide amounts while iPhone is locked", isOn: Binding(
                        get: { model.ledger.settings.hideWidgetsWhenLocked },
                        set: { model.setHideWidgetsWhenLocked($0) }
                    ))
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("Hide amounts: the \"Hisaab\" and \"Hisaab (Cycle)\" widgets show percentages only, on the lock screen and the home screen. The \"Hisaab (Private)\" widget always hides amounts. While locked: widgets that show amounts are blurred until you unlock your iPhone. Widgets that only show percentages stay visible.")
                }

                Section {
                    ForEach(model.ledger.settings.creditCards, id: \.self) { card in
                        Text("XX\(card)")
                    }
                    .onDelete { offsets in
                        var cards = model.ledger.settings.creditCards
                        cards.remove(atOffsets: offsets)
                        model.setCreditCards(cards)
                    }
                    HStack {
                        TextField("Last 4 digits", text: $newCard)
                            .keyboardType(.numberPad)
                        Button("Add") {
                            guard let card = Counting.normalizedCard(newCard), card.count == 4 else { return }
                            var cards = model.ledger.settings.creditCards
                            if !cards.contains(card) { cards.append(card) }
                            model.setCreditCards(cards)
                            newCard = ""
                        }
                        .disabled(newCard.filter(\.isNumber).count < 4)
                    }
                } header: {
                    Text("Credit cards")
                } footer: {
                    Text("SMS that name one of these cards count as card spends. Card bill payments then only count what your tracked card spends don't already cover. SMS that say \"credit card\" are detected without this.")
                }

                Section {
                    ForEach(model.ledger.settings.savingsKeywords, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { offsets in
                        var words = model.ledger.settings.savingsKeywords
                        words.remove(atOffsets: offsets)
                        model.setSavingsKeywords(words)
                    }
                    HStack {
                        TextField("Recipient name or UPI ID", text: $newSavingsWord)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add") {
                            let word = newSavingsWord.trimmingCharacters(in: .whitespacesAndNewlines)
                            var words = model.ledger.settings.savingsKeywords
                            if !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                                words.append(word)
                            }
                            model.setSavingsKeywords(words)
                            newSavingsWord = ""
                        }
                        .disabled(newSavingsWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Savings recipients")
                } footer: {
                    Text("Debits to these count as savings, not spends. Already detected: Groww, Zerodha, Upstox, Kuvera, Paytm Money, Angel One, INDmoney, ET Money, smallcase, ICCL, NSE Clearing, BSE, mutual funds, SIP, CAMS, KFintech, NPS. Applies to new SMS only.")
                }

                Section {
                    Button("Export data") {
                        do {
                            export = ExportFile(url: try model.exportFile())
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Saves everything as one JSON file that is not encrypted, so keep it somewhere private. Hisaab deletes its own copy when the share sheet closes.")
                }

                Section {
                    LabeledContent("Shared storage") {
                        Text(AppGroup.isShared ? "OK" : "NOT SHARED")
                            .foregroundStyle(AppGroup.isShared ? .green : .red)
                    }
                    LabeledContent("App Group", value: AppGroup.id)
                        .font(.footnote)
                    NavigationLink("Test SMS parser") { ParserPlaygroundView() }
                    NavigationLink("Debug log (\(model.ledger.log.count))") { DebugLogView() }
                    Toggle("Keep full SMS text", isOn: Binding(
                        get: { model.ledger.settings.keepFullSMSText },
                        set: { model.setKeepFullSMSText($0) }
                    ))
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Off: Hisaab keeps the full bank SMS for 7 days, then removes its numbers (balances, account and reference numbers). SMS that are not spends are not stored, and the debug log is cleared after 30 days. Turn on only to report a parsing problem.")
                }

                Section {
                    Button("Delete all data", role: .destructive) { confirmDelete = true }
                    if let deleteError {
                        Text(deleteError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Erases your budget, spends, categories, settings and the debug log from this iPhone. This can't be undone. Export first if you want a copy.")
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $export, onDismiss: { ExportFiles.removeAll() }) { ShareSheet(url: $0.url) }
            .confirmationDialog("Delete all Hisaab data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) {
                    do {
                        try model.deleteAllData()
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            } message: {
                Text("Everything is erased from this iPhone. This can't be undone.")
            }
        }
    }
}

extension SettingsView {
    /// Turning the lock on asks first, so it can't be turned on without a working Face ID or passcode.
    private func setAppLock(_ enabled: Bool) {
        appLockError = nil
        guard enabled else {
            appLockEnabled = false
            return
        }
        Task { @MainActor in
            if let failure = await AppLock.authenticate(reason: "Turn on the app lock for Hisaab.") {
                appLockError = failure
            } else {
                appLockEnabled = true
            }
        }
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
