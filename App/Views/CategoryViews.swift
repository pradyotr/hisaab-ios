import SwiftUI
import BudgetCore

/// Tappable category on a spend row. Shows "Add category" when there is none.
struct CategoryChip: View {
    let name: String?
    /// The app assigned `name`, and the user has not confirmed it.
    var isAuto = false
    /// Shown as a question when there is no category.
    var suggestion: String? = nil
    let action: () -> Void

    private var title: String {
        if let name { return name }
        if let suggestion { return "\(suggestion)?" }
        return "Add category"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if isAuto {
                    Image(systemName: "sparkles")
                        .accessibilityLabel("Auto")
                }
                Text(title)
                    .lineLimit(1)
            }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(name == nil ? Color.secondary : Color.accentColor)
                .background {
                    if name == nil {
                        Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3]))
                    } else {
                        Capsule().fill(Color.accentColor.opacity(0.15))
                    }
                }
        }
        .buttonStyle(.borderless)
    }
}

/// Choose a category, or type a new name to create one. Saving the choice is up to the caller.
struct CategoryPickerSheet: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let currentID: UUID?
    var prediction: CategoryPrediction? = nil
    /// Nil = the category was removed.
    let onSelect: (SpendCategory?) -> Void

    @State private var query = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggested: [SpendCategory] {
        guard trimmed.isEmpty else { return [] }
        return (prediction?.candidates ?? []).compactMap { candidate in
            model.ledger.categories.first { $0.id == candidate.categoryID }
        }
    }

    private var matches: [SpendCategory] {
        let all = model.ledger.categoriesByUse
        let suggestedIDs = Set(suggested.map(\.id))
        return trimmed.isEmpty
            ? all.filter { !suggestedIDs.contains($0.id) }
            : all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func row(_ category: SpendCategory) -> some View {
        Button { choose(category) } label: {
            HStack {
                Text(category.name)
                Spacer()
                if category.id == currentID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .tint(.primary)
    }

    private var canCreate: Bool {
        !trimmed.isEmpty && !model.ledger.categories.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(model.ledger.categories.isEmpty ? "Name your first category" : "Search or create",
                              text: $query)
                        .submitLabel(.done)
                        .onSubmit(submit)
                }
                if canCreate {
                    Section {
                        Button("Create \"\(trimmed)\"", action: create)
                    }
                }
                if !suggested.isEmpty {
                    Section {
                        ForEach(suggested) { row($0) }
                    } header: {
                        Text("Suggested")
                    } footer: {
                        if let reason = prediction?.reason { Text(reason) }
                    }
                }
                if !matches.isEmpty {
                    Section {
                        ForEach(matches) { row($0) }
                    }
                }
                if currentID != nil {
                    Section {
                        Button("Remove category", role: .destructive) { choose(nil) }
                    }
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        if canCreate {
            create()
        } else if let first = matches.first, !trimmed.isEmpty {
            choose(first)
        }
    }

    private func create() {
        guard let category = model.createCategory(named: trimmed) else { return }
        choose(category)
    }

    private func choose(_ category: SpendCategory?) {
        onSelect(category)
        dismiss()
    }
}

/// "Apply this category to the other spends from the same merchant".
struct BulkCategoryOffer: Equatable {
    let categoryID: UUID
    let categoryName: String
    let merchant: String
    let ids: Set<UUID>
    var applied = false
}

/// Bottom banner for a `BulkCategoryOffer`. Hides itself after a few seconds. After applying, it offers undo.
struct BulkCategoryBanner: View {
    @Environment(LedgerModel.self) private var model
    @Binding var offer: BulkCategoryOffer?

    var body: some View {
        if let current = offer {
            HStack(spacing: 12) {
                Text(message(current))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if current.applied {
                    Button("Undo") {
                        model.setCategory(nil, for: current.ids)
                        offer = nil
                    }
                    .fontWeight(.semibold)
                } else {
                    Button("Apply") {
                        model.setCategory(current.categoryID, for: current.ids)
                        offer?.applied = true
                    }
                    .fontWeight(.semibold)
                    Button {
                        offer = nil
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.bottom, 8)
            .task(id: current) {
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { offer = nil }
            }
        }
    }

    private func message(_ offer: BulkCategoryOffer) -> String {
        let spends = offer.ids.count == 1 ? "spend" : "spends"
        if offer.applied { return "\(offer.categoryName) applied to \(offer.ids.count) \(spends)" }
        return "Apply \(offer.categoryName) to \(offer.ids.count) other \(offer.merchant) \(spends)?"
    }
}

/// Rename, delete and add categories.
struct ManageCategoriesView: View {
    @Environment(LedgerModel.self) private var model
    @State private var renaming: SpendCategory?
    @State private var deleting: SpendCategory?
    @State private var adding = false
    @State private var nameText = ""
    @State private var nameTaken = false

    private func count(_ category: SpendCategory) -> Int {
        model.ledger.transactions.filter { $0.categoryID == category.id }.count
    }

    var body: some View {
        List {
            ForEach(model.ledger.categoriesByUse) { category in
                Button {
                    nameText = category.name
                    renaming = category
                } label: {
                    LabeledContent(category.name, value: "\(count(category))")
                }
                .tint(.primary)
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = category }
                }
            }
        }
        .overlay {
            if model.ledger.categories.isEmpty {
                ContentUnavailableView("No categories yet", systemImage: "tag",
                                       description: Text("Add one with +, or create one while categorizing a spend."))
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            Button {
                nameText = ""
                adding = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add category")
        }
        .alert("New category", isPresented: $adding) {
            TextField("Name", text: $nameText)
            Button("Add") { model.createCategory(named: nameText) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename category", isPresented: isPresent($renaming)) {
            TextField("Name", text: $nameText)
            Button("Save") {
                if let renaming, !model.renameCategory(renaming.id, to: nameText) { nameTaken = true }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("That name can't be used", isPresented: $nameTaken) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The name is empty, or another category already has it.")
        }
        .alert("Delete \(deleting?.name ?? "category")?", isPresented: isPresent($deleting)) {
            Button("Delete", role: .destructive) {
                if let deleting { model.deleteCategory(deleting.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its spends stay, but become uncategorized.")
        }
    }

    private func isPresent(_ item: Binding<SpendCategory?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// How well predictions work on the user's own history, and a way to apply them to older spends.
struct LearningView: View {
    @Environment(LedgerModel.self) private var model
    @State private var replay: CategoryReplayResult?
    @State private var outcome: String?

    var body: some View {
        Form {
            Section {
                if let replay {
                    LabeledContent("Spends you labelled", value: "\(replay.labels)")
                    LabeledContent("Top guess right", value: percent(replay.topCorrect, of: replay.tested))
                    LabeledContent("Right answer in top 3", value: percent(replay.topThreeCorrect, of: replay.tested))
                    LabeledContent("Auto-assigned correctly", value: percent(replay.autoCorrect, of: replay.autoAssigned))
                } else {
                    ProgressView()
                }
            } header: {
                Text("Category predictions")
            } footer: {
                Text("Measured on your own history: each spend you labelled is predicted using only the labels before it. These numbers mean little until you have about 50 labels. Each correction counts extra.")
            }
            Section {
                Button("Predict uncategorized spends") {
                    let assigned = model.predictUncategorized()
                    outcome = "\(assigned) assigned. The others keep their suggestions."
                }
                if let outcome {
                    Text(outcome)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("New spends are predicted when they are logged. Categories you set are never changed.")
            }
        }
        .navigationTitle("Learning")
        .task(id: model.ledger.transactions.count) {
            let ledger = model.ledger
            replay = await Task.detached { ledger.categoryReplay() }.value
        }
    }

    private func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "–" }
        return "\(Int((Double(part) / Double(whole) * 100).rounded()))% (\(part) of \(whole))"
    }
}

extension PaymentMethod {
    /// Nil when the method is not known.
    var title: String? {
        switch self {
        case .creditCard: return "Credit card"
        case .debitCard: return "Debit card"
        case .upi: return "UPI"
        case .bankTransfer: return "Bank transfer"
        case .atm: return "ATM"
        case .unknown: return nil
        }
    }
}
