import SwiftUI
import BudgetCore

/// Monthly income + goal (save X, or spend at most Y; the other is derived) + cycle start day.
struct SetupView: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isOnboarding = false

    enum Mode: String, CaseIterable, Identifiable {
        case save = "Save"
        case cap = "Spend at most"
        var id: Self { self }
    }

    // Strings, not Decimal bindings: TextField(value:) only commits on Return, which decimalPad lacks.
    @State private var incomeText = ""
    @State private var amountText = ""
    @State private var mode: Mode = .save
    @State private var startDay = 1
    @State private var currencyCode = "INR"

    var body: some View {
        Form {
            Section("Monthly income") {
                TextField("Salary", text: $incomeText)
                    .keyboardType(.decimalPad)
            }

            Section {
                Picker("Goal", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField(mode == .save ? "Amount to save" : "Maximum to spend", text: $amountText)
                    .keyboardType(.decimalPad)

                if let draft {
                    MoneyRow(title: mode == .save ? "You can spend" : "You will save",
                             value: mode == .save ? draft.spendCap : draft.savingsTarget,
                             currencyCode: currencyCode)
                }
            } header: {
                Text("Goal")
            } footer: {
                if let income = Amount.parse(incomeText), let amount = Amount.parse(amountText), amount > income {
                    Text("This is more than your income.").foregroundStyle(.red)
                }
            }

            Section {
                Stepper("Starts on day \(startDay)", value: $startDay, in: 1...28)
            } header: {
                Text("Budget cycle")
            } footer: {
                Text("Use your salary day if you are paid mid-month.")
            }

            Section {
                Button(isOnboarding ? "Start tracking" : "Save") { save() }
                    .disabled(draft == nil)
            }
        }
        .navigationTitle(isOnboarding ? "Set up Hisaab" : "Budget")
        .onAppear(perform: loadExisting)
    }

    private var draft: BudgetConfig? {
        guard let income = Amount.parse(incomeText), income > 0,
              let amount = Amount.parse(amountText) else { return nil }
        return BudgetConfig(
            monthlyIncome: income,
            goal: mode == .save ? .save(amount) : .spendCap(amount),
            cycleStartDay: startDay,
            currencyCode: currencyCode
        )
    }

    private func loadExisting() {
        guard let config = model.config else { return }
        incomeText = "\(config.monthlyIncome)"
        switch config.goal {
        case .save(let amount):
            mode = .save
            amountText = "\(amount)"
        case .spendCap(let amount):
            mode = .cap
            amountText = "\(amount)"
        }
        startDay = config.cycleStartDay
        currencyCode = config.currencyCode
    }

    private func save() {
        guard let draft else { return }
        model.saveConfig(draft)
        if !isOnboarding { dismiss() }
    }
}
