import SwiftUI
import WidgetKit
import BudgetCore

// MARK: - Timeline

struct HisaabEntry: TimelineEntry {
    let date: Date
    let snapshot: TodaySnapshot?
    let currencyCode: String
    let hideValues: Bool
}

/// Reads the shared ledger. Produces one entry for now and one for the next midnight,
/// so the new day's budget appears without opening the app.
/// The app and the App Intent call WidgetCenter.reloadAllTimelines() after every change.
struct HisaabProvider: TimelineProvider {
    /// True for the "Private" widget: always percentages only.
    let forceHide: Bool

    func placeholder(in context: Context) -> HisaabEntry {
        Self.sample(hide: forceHide)
    }

    func getSnapshot(in context: Context, completion: @escaping (HisaabEntry) -> Void) {
        completion(context.isPreview ? Self.sample(hide: forceHide) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HisaabEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let midnight = calendar.startOfDay(for: tomorrow)
        completion(Timeline(entries: [entry(at: now), entry(at: midnight)], policy: .after(midnight)))
    }

    private func entry(at date: Date) -> HisaabEntry {
        let ledger = AppGroup.store.load()
        let hide = forceHide || ledger.settings.hideValues
        guard let config = ledger.config else {
            return HisaabEntry(date: date, snapshot: nil, currencyCode: "INR", hideValues: hide)
        }
        let snapshot = BudgetEngine(config: config).snapshot(at: date, transactions: ledger.transactions)
        return HisaabEntry(date: date, snapshot: snapshot, currencyCode: config.currencyCode, hideValues: hide)
    }

    static func sample(hide: Bool) -> HisaabEntry {
        let config = BudgetConfig(monthlyIncome: 60_000, goal: .save(30_000))
        let now = Date()
        let snapshot = BudgetEngine(config: config)
            .snapshot(at: now, transactions: [Transaction(amount: 380, date: now)])
        return HisaabEntry(date: now, snapshot: snapshot, currencyCode: "INR", hideValues: hide)
    }
}

// MARK: - Views

struct HisaabWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HisaabEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryCircular: circular(snapshot)
                case .accessoryInline: inline(snapshot)
                default: rectangular(snapshot)
                }
            } else {
                Text("Set up Hisaab")
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private func money(_ value: Decimal) -> String { Format.money(value, entry.currencyCode) }

    private func circular(_ s: TodaySnapshot) -> some View {
        Gauge(value: Format.progress(s.day.utilisation)) {
            Image(systemName: "indianrupeesign")
        } currentValueLabel: {
            Text(Format.percent(s.day.utilisation))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private func rectangular(_ s: TodaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.hideValues {
                Text("Hisaab today")
                    .font(.headline)
                    .widgetAccentable()
                Text("\(Format.percent(s.day.utilisation)) used")
            } else {
                Text("Today \(money(s.day.budget))")
                    .font(.headline)
                    .widgetAccentable()
                Text("\(money(s.day.spent)) used · \(Format.percent(s.day.utilisation))")
            }
            ProgressView(value: Format.progress(s.day.utilisation))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inline(_ s: TodaySnapshot) -> some View {
        if entry.hideValues {
            Text("Hisaab \(Format.percent(s.day.utilisation)) used")
        } else {
            Text("\(money(max(s.day.difference, 0))) left today")
        }
    }
}

// MARK: - Widgets

struct HisaabWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HisaabWidget", provider: HisaabProvider(forceHide: false)) { entry in
            HisaabWidgetView(entry: entry)
        }
        .configurationDisplayName("Hisaab")
        .description("Today's budget and how much of it you've used.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct HisaabPrivateWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HisaabPrivateWidget", provider: HisaabProvider(forceHide: true)) { entry in
            HisaabWidgetView(entry: entry)
        }
        .configurationDisplayName("Hisaab (Private)")
        .description("Percentages only, no amounts.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

@main
struct HisaabWidgetBundle: WidgetBundle {
    var body: some Widget {
        HisaabWidget()
        HisaabPrivateWidget()
    }
}
