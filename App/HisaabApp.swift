import SwiftUI

@main
struct HisaabApp: App {
    @State private var model = LedgerModel()
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            PrivacyGate {
                ContentView()
            }
            .environment(model)
            .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// In-app light/dark choice. A UI preference for the app only, so it lives in UserDefaults, not ledger.json.
/// The widgets follow the system appearance and ignore this.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil follows the iPhone's setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
