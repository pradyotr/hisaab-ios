import SwiftUI
import BudgetCore

struct SettingsView: View {
    @Environment(LedgerModel.self) private var model
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    @State private var newCard = ""
    @State private var newSavingsWord = ""
    @State private var export: ExportFile?
    @State private var exportError: String?

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
                    Toggle("Hide amounts in widgets", isOn: Binding(
                        get: { model.ledger.settings.hideValues },
                        set: { model.setHideValues($0) }
                    ))
                } footer: {
                    Text("The \"Hisaab\" and \"Hisaab (Cycle)\" widgets then show percentages only, on the lock screen and the home screen. The \"Hisaab (Private)\" widget always hides amounts.")
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
                    Text("Saves everything as one JSON file. It includes your spends and the original bank SMS, so keep it private.")
                }

                Section("Diagnostics") {
                    LabeledContent("Shared storage") {
                        Text(AppGroup.isShared ? "OK" : "NOT SHARED")
                            .foregroundStyle(AppGroup.isShared ? .green : .red)
                    }
                    LabeledContent("App Group", value: AppGroup.id)
                        .font(.footnote)
                    NavigationLink("Test SMS parser") { ParserPlaygroundView() }
                    NavigationLink("Debug log (\(model.ledger.log.count))") { DebugLogView() }
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $export) { ShareSheet(url: $0.url) }
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
