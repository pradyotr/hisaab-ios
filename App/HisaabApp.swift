import SwiftUI

@main
struct HisaabApp: App {
    @State private var model = LedgerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
