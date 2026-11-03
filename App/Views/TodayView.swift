import SwiftUI
import BudgetCore

struct TodayView: View {
    @Environment(LedgerModel.self) private var model
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if let engine = model.engine {
                    content(engine.snapshot(at: Date(), transactions: model.ledger.transactions),
                            currencyCode: engine.config.currencyCode)
                } else {
                    ContentUnavailableView("No budget yet", systemImage: "indianrupeesign.circle")
                }
            }
            .navigationTitle("Hisaab")
            .toolbar {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showingAdd) { TransactionEditor(transaction: nil) }
        }
    }

    private func content(_ snap: TodaySnapshot, currencyCode code: String) -> some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Gauge(value: Format.progress(snap.day.utilisation)) {
                        Text("Used")
                    } currentValueLabel: {
                        Text(Format.percent(snap.day.utilisation))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(snap.day.difference >= 0 ? .green : .red)
                    .scaleEffect(1.6)
                    .padding(24)
                    Spacer()
                }
                MoneyRow(title: "Daily budget", value: snap.day.budget, currencyCode: code)
                MoneyRow(title: "Spent today", value: snap.day.spent, currencyCode: code)
                MoneyRow(title: snap.day.difference >= 0 ? "Left today" : "Over today",
                         value: abs(snap.day.difference), currencyCode: code,
                         tint: Format.color(forDifference: snap.day.difference))
            } header: {
                Text("Today")
            }

            Section("This cycle") {
                MoneyRow(title: "Spend cap", value: snap.cycle.cap, currencyCode: code)
                MoneyRow(title: "Spent", value: snap.cycle.spent, currencyCode: code)
                MoneyRow(title: "Remaining", value: snap.cycle.difference, currencyCode: code,
                         tint: Format.color(forDifference: snap.cycle.difference))
                LabeledContent("Days left", value: "\(snap.daysLeftIncludingToday)")
            }
        }
    }
}
