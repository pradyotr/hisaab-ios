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
            .sheet(isPresented: $showingAdd) { TransactionEditor(spend: nil) }
        }
    }

    private func content(_ snap: TodaySnapshot, currencyCode code: String) -> some View {
        List {
            Section {
                UsageGauge(utilisation: snap.day.utilisation, difference: snap.day.difference)
                MoneyRow(title: "Daily budget", value: snap.day.budget, currencyCode: code)
                MoneyRow(title: "Spent today", value: snap.day.spent, currencyCode: code)
                MoneyRow(title: snap.day.difference >= 0 ? "Left today" : "Over today",
                         value: abs(snap.day.difference), currencyCode: code,
                         tint: Format.color(forDifference: snap.day.difference))
            } header: {
                Text("Today")
            }

            Section("This cycle") {
                UsageGauge(utilisation: snap.cycle.utilisation, difference: snap.cycle.difference)
                MoneyRow(title: "Spend cap", value: snap.cycle.cap, currencyCode: code)
                MoneyRow(title: "Spent", value: snap.cycle.spent, currencyCode: code)
                MoneyRow(title: "Remaining", value: snap.cycle.difference, currencyCode: code,
                         tint: Format.color(forDifference: snap.cycle.difference))
                LabeledContent("Days left", value: "\(snap.daysLeftIncludingToday)")
            }
        }
    }
}

/// Big circular "% used" gauge: green while under budget, red once over.
private struct UsageGauge: View {
    let utilisation: Double?
    let difference: Decimal

    var body: some View {
        HStack {
            Spacer()
            Gauge(value: Format.progress(utilisation)) {
                Text("Used")
            } currentValueLabel: {
                Text(Format.percent(utilisation))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Format.color(forDifference: difference))
            .scaleEffect(1.6)
            .padding(24)
            Spacer()
        }
    }
}
