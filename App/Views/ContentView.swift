import SwiftUI

struct ContentView: View {
    @Environment(LedgerModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.config == nil {
                NavigationStack { SetupView(isOnboarding: true) }
            } else {
                TabView {
                    TodayView()
                        .tabItem { Label("Today", systemImage: "sun.max") }
                    TransactionsView()
                        .tabItem { Label("Spends", systemImage: "list.bullet") }
                    ChartsView()
                        .tabItem { Label("Trends", systemImage: "chart.bar.xaxis") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        // Pick up spends logged by the Shortcuts automation while the app was in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.reload() }
        }
    }
}

/// "Label ........ ₹1,234" row, optionally coloured.
struct MoneyRow: View {
    let title: String
    let value: Decimal
    let currencyCode: String
    var tint: Color? = nil

    var body: some View {
        LabeledContent(title) {
            Text(Format.money(value, currencyCode))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
    }
}
