import SwiftUI
import WidgetKit
import BudgetCore

// MARK: - Timeline

struct HisaabEntry: TimelineEntry {
    let date: Date
    let snapshot: TodaySnapshot?
    let currencyCode: String
    let hideValues: Bool
    /// Settings > Widgets > Hide amounts while iPhone is locked.
    var hideWhenLocked = false
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
        if AppGroup.takeInPendingSMS() { WidgetCenter.shared.reloadAllTimelines() }
        let now = Date()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let midnight = calendar.startOfDay(for: tomorrow)
        completion(Timeline(entries: [entry(at: now), entry(at: midnight)], policy: .after(midnight)))
    }

    /// From the widget digest, not the ledger: the ledger can't be read while the iPhone is locked.
    private func entry(at date: Date) -> HisaabEntry {
        let digest = AppGroup.widgetDigest(now: date)
        let hide = forceHide || (digest?.settings.hideValues ?? false)
        guard let digest, let config = digest.config, let snapshot = digest.snapshot(at: date) else {
            return HisaabEntry(date: date, snapshot: nil, currencyCode: "INR", hideValues: hide)
        }
        return HisaabEntry(date: date, snapshot: snapshot, currencyCode: config.currencyCode, hideValues: hide,
                           hideWhenLocked: digest.settings.hideWidgetsWhenLocked)
    }

    static func sample(hide: Bool) -> HisaabEntry {
        let config = BudgetConfig(monthlyIncome: 60_000, goal: .save(30_000))
        let now = Date()
        let snapshot = BudgetEngine(config: config)
            .snapshot(at: now, transactions: [Spend(amount: 380, date: now)])
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
                case .systemSmall: HomeTodaySmall(entry: entry, s: snapshot)
                case .systemMedium: HomeTodayMedium(entry: entry, s: snapshot)
                case .accessoryCircular: circular(snapshot)
                case .accessoryInline: inline(snapshot)
                default: rectangular(snapshot)
                }
            } else {
                Text("Set up Hisaab")
            }
        }
        // The circular gauge shows only a percentage, so it stays visible.
        .privacySensitive(entry.hideWhenLocked && !entry.hideValues && family != .accessoryCircular)
        .widgetBackground(family)
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

/// Circular "% of the cycle's spend cap used". The calendar icon in the ring's gap tells it apart
/// from the daily widget. On the lock screen it shows only a percentage. The home screen version
/// also shows amounts unless hide-values is on.
struct HisaabCycleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HisaabEntry

    var body: some View {
        Group {
            if let s = entry.snapshot, family == .systemSmall {
                HomeCycleSmall(entry: entry, s: s)
            } else if let s = entry.snapshot {
                Gauge(value: Format.progress(s.cycle.utilisation)) {
                    Image(systemName: "calendar")
                } currentValueLabel: {
                    Text(Format.percent(s.cycle.utilisation))
                }
                .gaugeStyle(.accessoryCircular)
                .widgetAccentable()
            } else {
                Image(systemName: "indianrupeesign")
            }
        }
        // Only the home screen version shows amounts.
        .privacySensitive(entry.hideWhenLocked && !entry.hideValues && family == .systemSmall)
        .widgetBackground(family)
    }
}

// MARK: - Home screen views

extension View {
    /// Lock screen widgets are drawn by iOS on the wallpaper, so they get no background.
    /// Home screen widgets get the normal system widget background.
    @ViewBuilder
    func widgetBackground(_ family: WidgetFamily) -> some View {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge:
            containerBackground(.fill.tertiary, for: .widget)
        default:
            containerBackground(for: .widget) { Color.clear }
        }
    }
}

/// Bar colour on the home screen: green while within budget, red once over it (or nothing left).
private func usageTint(_ utilisation: Double?) -> Color {
    (utilisation ?? 2) > 1 ? .red : .green
}

private struct HomeHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// Today: what is left, the day's budget, the amount used and % used.
struct HomeTodaySmall: View {
    let entry: HisaabEntry
    let s: TodaySnapshot

    private func money(_ value: Decimal) -> String { Format.money(value, entry.currencyCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HomeHeader(title: "Today", systemImage: "indianrupeesign.circle")
            Spacer(minLength: 0)
            if entry.hideValues {
                Text(Format.percent(s.day.utilisation))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(money(max(s.day.difference, 0)))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("left of \(money(s.day.budget))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            ProgressView(value: Format.progress(s.day.utilisation))
                .tint(usageTint(s.day.utilisation))
            Text(entry.hideValues
                 ? "\(s.daysLeftIncludingToday) days left in cycle"
                 : "\(money(s.day.spent)) used · \(Format.percent(s.day.utilisation))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Today on the left, the whole cycle on the right.
struct HomeTodayMedium: View {
    let entry: HisaabEntry
    let s: TodaySnapshot

    private func money(_ value: Decimal) -> String { Format.money(value, entry.currencyCode) }

    var body: some View {
        HStack(spacing: 16) {
            HomeTodaySmall(entry: entry, s: s)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HomeHeader(title: "This cycle", systemImage: "calendar")
                Spacer(minLength: 0)
                Text(Format.percent(s.cycle.utilisation))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(entry.hideValues
                     ? "of spend cap used"
                     : "\(money(s.cycle.spent)) of \(money(s.cycle.cap))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                ProgressView(value: Format.progress(s.cycle.utilisation))
                    .tint(usageTint(s.cycle.utilisation))
                Text("\(s.daysLeftIncludingToday) days left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// Cycle: a ring with the % of the spend cap used.
struct HomeCycleSmall: View {
    let entry: HisaabEntry
    let s: TodaySnapshot

    private func money(_ value: Decimal) -> String { Format.money(value, entry.currencyCode) }

    var body: some View {
        VStack(spacing: 6) {
            HomeHeader(title: "This cycle", systemImage: "calendar")
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: Format.progress(s.cycle.utilisation))
                    .stroke(usageTint(s.cycle.utilisation),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Format.percent(s.cycle.utilisation))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(12)
            }
            .frame(width: 80, height: 80)
            Spacer(minLength: 0)
            Text(entry.hideValues
                 ? "\(s.daysLeftIncludingToday) days left"
                 : "\(money(s.cycle.spent)) of \(money(s.cycle.cap))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct HisaabCycleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HisaabCycleWidget", provider: HisaabProvider(forceHide: false)) { entry in
            HisaabCycleWidgetView(entry: entry)
        }
        .configurationDisplayName("Hisaab (Cycle)")
        .description("How much of this cycle's spend cap you've used.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct HisaabPrivateWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HisaabPrivateWidget", provider: HisaabProvider(forceHide: true)) { entry in
            HisaabWidgetView(entry: entry)
        }
        .configurationDisplayName("Hisaab (Private)")
        .description("Percentages only, no amounts.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

@main
struct HisaabWidgetBundle: WidgetBundle {
    var body: some Widget {
        HisaabWidget()
        HisaabCycleWidget()
        HisaabPrivateWidget()
        HisaabCategoryChartWidget()
        HisaabCategorizeWidget()
    }
}
