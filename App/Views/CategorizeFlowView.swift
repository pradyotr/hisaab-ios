import SwiftUI
import BudgetCore

/// Catch up on uncategorized spends, one at a time. The biggest merchant groups come first.
struct CategorizeFlowView: View {
    @Environment(LedgerModel.self) private var model
    @State private var total = 0
    @State private var skipped: Set<UUID> = []
    @State private var history: [UUID] = []
    /// Set while going back to an earlier spend.
    @State private var revisiting: UUID?
    @State private var offer: BulkCategoryOffer?
    @State private var newName = ""

    private var currencyCode: String { model.config?.currencyCode ?? "INR" }

    private var current: Spend? {
        if let revisiting, let spend = model.ledger.transactions.first(where: { $0.id == revisiting }) {
            return spend
        }
        return model.ledger.categorizationQueue.first { !skipped.contains($0.id) }
    }

    var body: some View {
        Group {
            if let spend = current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        progress
                        summary(spend)
                        categories(for: spend)
                        controls(for: spend)
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text(skipped.isEmpty ? "Every spend has a category." : "Only the spends you skipped are left."))
            }
        }
        .navigationTitle("Categorize")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { BulkCategoryBanner(offer: $offer) }
        .sensoryFeedback(.selection, trigger: history.count)
        .onAppear { total = model.ledger.entriesNeedingCategory.count }
    }

    private var progress: some View {
        let left = min(model.ledger.entriesNeedingCategory.count, total)
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(total - left), total: Double(max(total, 1)))
            Text("\(left) left")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ spend: Spend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Format.money(spend.amount, currencyCode))
                .font(.largeTitle.bold())
                .monospacedDigit()
            Text(spend.merchant ?? spend.note ?? spend.kind.title)
                .font(.title3)
            Text(details(spend))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if spend.merchant == nil, let raw = spend.rawText {
                Text(raw)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private func details(_ spend: Spend) -> String {
        let date = spend.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return [date, spend.method.title].compactMap { $0 }.joined(separator: " · ")
    }

    private func categories(for spend: Spend) -> some View {
        let prediction = model.ledger.categoryPrediction(for: spend)
        let suggestedIDs = (prediction?.candidates ?? []).map(\.categoryID)
        let all = model.ledger.categoriesByUse
        let suggested = suggestedIDs.compactMap { id in all.first { $0.id == id } }
        let ordered = suggested + all.filter { !suggestedIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 12) {
            if let reason = prediction?.reason {
                SwiftUI.Label("Suggested first: \(reason)", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(ordered) { category in
                    Button { assign(category, to: spend) } label: {
                        Text(category.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 6)
                            .foregroundStyle(category.id == spend.categoryID ? Color.white : Color.primary)
                            .background(category.id == spend.categoryID ? Color.accentColor : Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("New category", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { createAndAssign(to: spend) }
                Button("Add") { createAndAssign(to: spend) }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func controls(for spend: Spend) -> some View {
        HStack {
            Button("Back", action: back)
                .disabled(history.isEmpty)
            Spacer()
            Button("Skip") {
                skipped.insert(spend.id)
                history.append(spend.id)
                revisiting = nil
                offer = nil
            }
        }
    }

    private func back() {
        guard let previous = history.popLast() else { return }
        skipped.remove(previous)
        revisiting = previous
        offer = nil
    }

    private func createAndAssign(to spend: Spend) {
        guard let category = model.createCategory(named: newName) else { return }
        newName = ""
        assign(category, to: spend)
    }

    private func assign(_ category: SpendCategory, to spend: Spend) {
        model.setCategory(category.id, for: [spend.id])
        history.append(spend.id)
        revisiting = nil
        offer = model.bulkOffer(after: spend, category: category)
    }
}
