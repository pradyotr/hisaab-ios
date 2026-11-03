import Foundation

extension Decimal {
    public var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }

    public func rounded(scale: Int = 2) -> Decimal {
        var input = self
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, .plain)
        return output
    }
}

public enum Amount {
    /// Parses user or SMS amounts like "1,23,456.50", "₹ 500", "Rs.99". Returns nil if not a number.
    public static func parse(_ text: String) -> Decimal? {
        var cleaned = text.replacingOccurrences(of: ",", with: "")
        for token in ["₹", "Rs.", "Rs", "rs.", "rs", "INR", "inr"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isNumber || $0 == "." }),
              cleaned.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return value
    }
}
