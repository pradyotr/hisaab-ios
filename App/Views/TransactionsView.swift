import SwiftUI
import BudgetCore

/// Every money movement: spends, card bills, savings and credits (refunds, reversals, cashback, other).
struct TransactionsView: View {
    @Environment(LedgerModel.self) private var model
    @State private var editing: Spend?
    @State private var adding = false
    @State private var categorizing: Spend?
    @State private var offer: BulkCategoryOffer?

    private var currencyCode: String { model.config?.currencyCode ?? "INR" }

    var body: some View {
        let entries = model.ledger.transactions
        let counted = Counting.countedAmounts(entries)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(model.ledger.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let uncategorized = model.ledger.entriesNeedingCategory.count
        NavigationStack {
            List {
                ForEach(entries) { spend in
                    // Not a Button: a row Button would swallow taps on the category chip inside it.
                    TransactionRow(spend: spend, counted: counted[spend.id],
                                   original: spend.reverses.flatMap { byID[$0] }, currencyCode: currencyCode,
                                   categoryName: spend.categoryID.flatMap { names[$0] },
                                   onTapCategory: categoryAction(for: spend, counted: counted[spend.id]))
                    .contentShape(Rectangle())
                    .onTapGesture { editing = spend }
                    .accessibilityAddTraits(.isButton)
                    .contextMenu { quickActions(for: spend) }
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { entries[$0].id })
                    model.delete(ids: ids)
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No spends yet", systemImage: "tray",
                                           description: Text("Add one with +, or log one from a bank SMS."))
                }
            }
            .navigationTitle("Spends")
            .toolbar {
                if uncategorized > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink("Categorize (\(uncategorized))") { CategorizeFlowView() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) { BulkCategoryBanner(offer: $offer) }
            .sheet(isPresented: $adding) { TransactionEditor(spend: nil) }
            .sheet(item: $editing) { TransactionEditor(spend: $0) }
            .sheet(item: $categorizing) { spend in
                CategoryPickerSheet(currentID: spend.categoryID) { chosen in
                    model.setCategory(chosen?.id, for: [spend.id])
                    offer = chosen.flatMap { model.bulkOffer(after: spend, category: $0) }
                }
            }
        }
    }

    /// Entries that count 0 (savings, money in, covered card bills) don't need a category.
    private func categoryAction(for spend: Spend, counted: Decimal?) -> (() -> Void)? {
        guard (counted ?? 0) != 0 || spend.categoryID != nil else { return nil }
        return { categorizing = spend }
    }

    /// Long-press menu to fix the type without opening the editor.
    @ViewBuilder
    private func quickActions(for spend: Spend) -> some View {
        Menu("Mark as") {
            ForEach(EntryKind.allCases, id: \.self) { kind in
                Button {
                    var changed = spend
                    changed.kind = kind
                    if kind == .reversal, changed.reverses == nil {
                        changed.reverses = model.ledger.reversalTarget(for: changed)
                    }
                    if kind != .reversal { changed.reverses = nil }
                    model.update(changed)
                } label: {
                    SwiftUI.Label(kind.title, systemImage: kind.symbol)
                }
                .disabled(spend.kind == kind)
            }
        }
        if spend.kind.usesAccount {
            Button {
                var changed = spend
                changed.account = spend.account == .creditCard ? .bank : .creditCard
                model.update(changed)
            } label: {
                SwiftUI.Label(spend.account == .creditCard ? "Not on a credit card" : "On a credit card",
                              systemImage: "creditcard")
            }
        }
        Button {
            var changed = spend
            changed.excluded.toggle()
            model.update(changed)
        } label: {
            SwiftUI.Label(spend.excluded ? "Count it" : "Don't count it",
                          systemImage: spend.excluded ? "eye" : "eye.slash")
        }
    }
}

extension EntryKind {
    var title: String {
        switch self {
        case .spend: return "Spend"
        case .cardBill: return "Credit card bill payment"
        case .savings: return "Savings / investment"
        case .refund: return "Refund"
        case .reversal: return "Reversal"
        case .cashback: return "Cashback"
        case .otherCredit: return "Other credit"
        }
    }

    var symbol: String {
        switch self {
        case .spend: return "indianrupeesign.circle"
        case .cardBill: return "creditcard.and.123"
        case .savings: return "chart.line.uptrend.xyaxis"
        case .refund: return "arrow.uturn.backward.circle"
        case .reversal: return "arrow.counterclockwise.circle"
        case .cashback: return "gift"
        case .otherCredit: return "arrow.down.circle"
        }
    }

    var explanation: String {
        switch self {
        case .spend:
            return "Counts in full. On a credit card, the card bill will not count it again."
        case .cardBill:
            return "Only the part not already covered by tracked card spends counts (for example interest, fees or purchases without an SMS)."
        case .savings:
            return "Money moved to an investment (SIP, stocks, mutual funds). It is saved, not spent, so it does not count. It shows as Invested."
        case .refund:
            return "Money back for a purchase. Lowers what you spent, on the day it comes back."
        case .reversal:
            return "A failed or cancelled payment returned. When linked, it cancels that payment as if it never happened. Not linked, it counts like a refund."
        case .cashback:
            return "Lowers what you spent, on the day it is credited."
        case .otherCredit:
            return "Salary, transfers in, interest and other money in. Kept in the list, never counted."
        }
    }

    /// Bank vs credit card matters for these (card bill matching). A card bill is always paid from a bank account.
    var usesAccount: Bool { self != .cardBill && self != .otherCredit }
}

struct TransactionRow: View {
    let spend: Spend
    /// Signed amount that counts towards the budget (see `Counting`).
    let counted: Decimal?
    /// For a linked reversal: the entry it cancels.
    let original: Spend?
    let currencyCode: String
    var categoryName: String? = nil
    /// Nil hides the category chip.
    var onTapCategory: (() -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(spend.merchant ?? spend.note ?? spend.kind.title)
                    .lineLimit(1)
                Text(spend.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let onTapCategory {
                    CategoryChip(name: categoryName, action: onTapCategory)
                        .padding(.top, 2)
                }
            }
            Spacer()
            Text((spend.kind.isCredit ? "+" : "") + Format.money(spend.amount, currencyCode))
                .monospacedDigit()
                .foregroundStyle(amountStyle)
                .strikethrough(countsNothing && spend.kind != .savings && spend.kind != .otherCredit)
        }
        .opacity(spend.excluded ? 0.5 : 1)
    }

    private var countsNothing: Bool { (counted ?? 0) == 0 }

    private var icon: String {
        switch spend.kind {
        case .spend where spend.account == .creditCard: return "creditcard"
        case .spend: return spend.source == .sms ? "message" : "hand.tap"
        default: return spend.kind.symbol
        }
    }

    private var amountStyle: AnyShapeStyle {
        if spend.excluded || spend.kind == .otherCredit { return AnyShapeStyle(.secondary) }
        switch spend.kind {
        case .refund, .reversal, .cashback: return AnyShapeStyle(Color.green)
        case .savings: return AnyShapeStyle(Color.blue)
        default: return AnyShapeStyle(.primary)
        }
    }

    private var detail: String? {
        if spend.excluded { return "Not counted" }
        let card = spend.card.map { " XX\($0)" } ?? ""
        let onCard = spend.account == .creditCard ? " · credit card\(card)" : ""
        switch spend.kind {
        case .spend:
            return spend.account == .creditCard ? "Credit card\(card)" : nil
        case .cardBill:
            let counts = counted ?? spend.amount
            return "Card bill\(card) · \(Format.money(counts, currencyCode)) counted, \(Format.money(spend.amount - counts, currencyCode)) already tracked"
        case .savings:
            return "Savings · not a spend\(onCard)"
        case .refund, .cashback:
            return "\(spend.kind.title) · lowers spent\(onCard)"
        case .reversal:
            if let original {
                return "Cancels \(original.merchant ?? original.kind.title), \(original.date.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Reversal · no original linked, lowers spent\(onCard)"
        case .otherCredit:
            return "Money in · not counted"
        }
    }
}

/// Add (spend == nil) or edit an entry. Use this to fix wrong SMS parses and to add cash spends.
struct TransactionEditor: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spend: Spend?

    @State private var amountText = ""
    @State private var merchant = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var kind: EntryKind = .spend
    @State private var onCreditCard = false
    @State private var cardText = ""
    @State private var reverses: UUID?
    @State private var excluded = false
    @State private var categoryID: UUID?
    @State private var choosingCategory = false

    private var categoryName: String {
        model.ledger.categories.first { $0.id == categoryID }?.name ?? "None"
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                TextField(kind.isCredit ? "From" : "Merchant", text: $merchant)
                TextField("Note", text: $note)
                DatePicker("When", selection: $date)
                Button { choosingCategory = true } label: {
                    LabeledContent("Category", value: categoryName)
                }
                .tint(.primary)

                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(EntryKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if kind.usesAccount {
                        Toggle("On a credit card", isOn: $onCreditCard)
                    }
                    if kind == .cardBill || (kind.usesAccount && onCreditCard) {
                        TextField(kind == .cardBill ? "Card being paid, last 4 digits (optional)" : "Card last 4 digits (optional)",
                                  text: $cardText)
                            .keyboardType(.numberPad)
                    }
                    if kind == .reversal {
                        Picker("Cancels", selection: $reverses) {
                            Text("Nothing (counts like a refund)").tag(UUID?.none)
                            ForEach(reversalCandidates) { candidate in
                                Text(candidateTitle(candidate)).tag(UUID?.some(candidate.id))
                            }
                        }
                    }
                    Toggle("Don't count", isOn: $excluded)
                } footer: {
                    Text(excluded ? "Kept in the list, but counts 0." : kind.explanation)
                }

                if spend?.ref != nil || spend?.rawText != nil {
                    Section("Original SMS") {
                        if let ref = spend?.ref {
                            LabeledContent("Reference", value: ref)
                        }
                        if let raw = spend?.rawText {
                            Text(raw)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(spend == nil ? "Add" : "Edit")
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
            .sheet(isPresented: $choosingCategory) {
                CategoryPickerSheet(currentID: categoryID) { categoryID = $0?.id }
            }
            .onChange(of: kind) { _, newKind in
                if newKind == .reversal, reverses == nil {
                    reverses = model.ledger.reversalTarget(for: draft())
                }
            }
        }
    }

    private var amount: Decimal? {
        guard let value = Amount.parse(amountText), value > 0 else { return nil }
        return value
    }

    /// Debits from the 30 days before this reversal, plus the one it is linked to now.
    private var reversalCandidates: [Spend] {
        let window: TimeInterval = 30 * 86_400
        return model.ledger.transactions.filter { other in
            if other.id == reverses { return true }
            guard other.id != spend?.id, other.kind == .spend || other.kind == .savings else { return false }
            return other.date <= date && date.timeIntervalSince(other.date) <= window
        }
    }

    private func candidateTitle(_ candidate: Spend) -> String {
        let name = candidate.merchant ?? candidate.note ?? candidate.kind.title
        return "\(name) · \(Format.money(candidate.amount, model.config?.currencyCode ?? "INR")) · \(candidate.date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func load() {
        guard let spend else { return }
        amountText = "\(spend.amount)"
        merchant = spend.merchant ?? ""
        note = spend.note ?? ""
        date = spend.date
        kind = spend.kind
        onCreditCard = spend.account == .creditCard
        cardText = spend.card ?? ""
        reverses = spend.reverses
        excluded = spend.excluded
        categoryID = spend.categoryID
    }

    /// The entry as currently entered (id kept when editing).
    private func draft() -> Spend {
        let cleanMerchant = merchant.trimmingCharacters(in: .whitespaces)
        let cleanNote = note.trimmingCharacters(in: .whitespaces)
        let account: PaymentAccount = kind.usesAccount && onCreditCard ? .creditCard : .bank
        let showsCard = kind == .cardBill || account == .creditCard
        var entry = spend ?? Spend(amount: amount ?? 0, source: .manual)
        entry.amount = amount ?? entry.amount
        entry.merchant = cleanMerchant.isEmpty ? nil : cleanMerchant
        entry.note = cleanNote.isEmpty ? nil : cleanNote
        entry.date = date
        entry.kind = kind
        entry.account = account
        entry.card = showsCard ? Counting.normalizedCard(cardText) : nil
        entry.reverses = kind == .reversal ? reverses : nil
        entry.excluded = excluded
        entry.categoryID = categoryID
        // A new entry has no earlier version for `Ledger.update` to compare with.
        if spend == nil { entry.sources.category = categoryID == nil ? nil : .user }
        return entry
    }

    private func save() {
        guard amount != nil else { return }
        let entry = draft()
        if spend != nil {
            model.update(entry)
        } else {
            // The "Cancels" picker already chose the link (or chose none on purpose).
            model.add(entry, linkReversal: false)
        }
        dismiss()
    }
}
