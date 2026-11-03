import SwiftUI
import BudgetCore

struct TransactionsView: View {
    @Environment(LedgerModel.self) private var model
    @State private var editing: Transaction?
    @State private var adding = false

    private var currencyCode: String { model.config?.currencyCode ?? "INR" }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.ledger.transactions) { transaction in
                    Button { editing = transaction } label: {
                        TransactionRow(transaction: transaction, currencyCode: currencyCode)
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { model.ledger.transactions[$0].id })
                    model.delete(ids: ids)
                }
            }
            .overlay {
                if model.ledger.transactions.isEmpty {
                    ContentUnavailableView("No spends yet", systemImage: "tray",
                                           description: Text("Add one with + or set up the SMS automation in Settings."))
                }
            }
            .navigationTitle("Spends")
            .toolbar {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $adding) { TransactionEditor(transaction: nil) }
            .sheet(item: $editing) { TransactionEditor(transaction: $0) }
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    let currencyCode: String

    var body: some View {
        HStack {
            Image(systemName: transaction.source == .sms ? "message" : "hand.tap")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(transaction.merchant ?? transaction.note ?? "Spend")
                    .lineLimit(1)
                Text(transaction.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.money(transaction.amount, currencyCode))
                .monospacedDigit()
        }
    }
}

/// Add (transaction == nil) or edit a spend. Use this to fix wrong SMS parses and to add cash spends.
struct TransactionEditor: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transaction: Transaction?

    @State private var amountText = ""
    @State private var merchant = ""
    @State private var note = ""
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                TextField("Merchant", text: $merchant)
                TextField("Note", text: $note)
                DatePicker("When", selection: $date)

                if let raw = transaction?.rawText {
                    Section("Original SMS") {
                        Text(raw)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(transaction == nil ? "Add spend" : "Edit spend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(amount == nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var amount: Decimal? {
        guard let value = Amount.parse(amountText), value > 0 else { return nil }
        return value
    }

    private func load() {
        guard let transaction else { return }
        amountText = "\(transaction.amount)"
        merchant = transaction.merchant ?? ""
        note = transaction.note ?? ""
        date = transaction.date
    }

    private func save() {
        guard let amount else { return }
        let cleanMerchant = merchant.trimmingCharacters(in: .whitespaces)
        let cleanNote = note.trimmingCharacters(in: .whitespaces)
        if var existing = transaction {
            existing.amount = amount
            existing.merchant = cleanMerchant.isEmpty ? nil : cleanMerchant
            existing.note = cleanNote.isEmpty ? nil : cleanNote
            existing.date = date
            model.update(existing)
        } else {
            model.add(Transaction(amount: amount, date: date,
                                  merchant: cleanMerchant.isEmpty ? nil : cleanMerchant,
                                  note: cleanNote.isEmpty ? nil : cleanNote,
                                  source: .manual))
        }
        dismiss()
    }
}
