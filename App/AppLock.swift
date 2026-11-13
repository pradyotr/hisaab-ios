import SwiftUI
import LocalAuthentication

/// Optional Face ID / Touch ID / passcode lock for the app. A UI preference for this device, so it lives in
/// UserDefaults, not ledger.json. It only guards the app's screens: the App Intent and the widgets keep working.
enum AppLock {
    static let storageKey = "appLockEnabled"

    /// "Face ID", "Touch ID" or "Passcode", for labels.
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }

    /// Asks for Face ID / Touch ID, with the passcode as fallback. Returns nil on success, or why it failed.
    @MainActor
    static func authenticate(reason: String) async -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.localizedDescription ?? "Set a passcode on this iPhone first."
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                continuation.resume(returning: success ? nil : (error?.localizedDescription ?? "Not unlocked."))
            }
        }
    }
}

/// Covers the app while it is not active, so the app switcher snapshot shows no amounts,
/// and, when the app lock is on, until the user unlocks.
struct PrivacyGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLock.storageKey) private var lockEnabled = false
    @State private var unlocked = false
    /// Ask automatically once per launch / return from the background. After a cancel the user taps Unlock.
    @State private var shouldPrompt = true
    @State private var authenticating = false
    @State private var failure: String?
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var isLocked: Bool { lockEnabled && !unlocked }
    private var isCovered: Bool { isLocked || scenePhase != .active }

    var body: some View {
        ZStack {
            content
                .accessibilityHidden(isCovered)
            if isCovered {
                cover
            }
        }
        .onAppear(perform: promptIfNeeded)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                unlocked = false
                shouldPrompt = true
                failure = nil
            case .active:
                promptIfNeeded()
            default:
                break
            }
        }
        // Turning the lock on in Settings happens while unlocked: don't lock the user out right away.
        .onChange(of: lockEnabled) { _, enabled in
            if enabled { unlocked = true }
        }
    }

    private var cover: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Hisaab")
                    .font(.title2.bold())
                if isLocked && scenePhase == .active && !authenticating {
                    Button("Unlock with \(AppLock.methodName)") { unlock() }
                        .buttonStyle(.borderedProminent)
                    if let failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
        }
    }

    private func promptIfNeeded() {
        guard isLocked, shouldPrompt, scenePhase == .active, !authenticating else { return }
        shouldPrompt = false
        unlock()
    }

    private func unlock() {
        authenticating = true
        Task { @MainActor in
            let result = await AppLock.authenticate(reason: "Unlock Hisaab to see your spends.")
            authenticating = false
            failure = result
            if result == nil { unlocked = true }
        }
    }
}
