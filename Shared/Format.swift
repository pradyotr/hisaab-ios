import Foundation
import SwiftUI

/// Formatting shared by the app and the widget.
enum Format {
    static func money(_ value: Decimal, _ currencyCode: String) -> String {
        value.formatted(.currency(code: currencyCode).precision(.fractionLength(0)))
    }

    /// "38%", or "—" when there is no budget left to measure against.
    static func percent(_ utilisation: Double?) -> String {
        guard let utilisation else { return "—" }
        return utilisation.formatted(.percent.precision(.fractionLength(0)))
    }

    /// 0...1 for gauges and progress bars. No budget left counts as full.
    static func progress(_ utilisation: Double?) -> Double {
        min(max(utilisation ?? 1, 0), 1)
    }

    static func color(forDifference difference: Decimal) -> Color {
        difference >= 0 ? .green : .red
    }
}
