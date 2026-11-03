import SwiftUI
import BudgetCore

struct SettingsView: View {
    @Environment(LedgerModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Budget") { SetupView() }
                }

                Section {
                    Toggle("Hide amounts on lock screen", isOn: Binding(
                        get: { model.ledger.settings.hideValues },
                        set: { model.setHideValues($0) }
                    ))
                } footer: {
                    Text("The \"Hisaab\" widget then shows percentages only. The \"Hisaab (Private)\" widget always hides amounts.")
                }

                Section("SMS automation (one-time setup)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Open Shortcuts > Automation > + > Message.")
                        Text("2. Sender: your bank. Or Message Contains: \"debited\".")
                        Text("3. Choose Run Immediately.")
                        Text("4. Add action \"Log Bank SMS\" (Hisaab). Set Message to Shortcut Input > Content.")
                        Text("Add one automation for each bank sender or keyword.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
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
        }
    }
}
