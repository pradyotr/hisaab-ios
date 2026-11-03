// swift-tools-version:5.9
// Pure-Swift core: budget math, SMS parsing, ledger persistence.
// No UIKit/SwiftUI/WidgetKit imports allowed here — it must build and test on Windows/Linux too.
import PackageDescription

let package = Package(
    name: "BudgetCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BudgetCore", targets: ["BudgetCore"]),
    ],
    targets: [
        .target(name: "BudgetCore"),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"]),
    ]
)
