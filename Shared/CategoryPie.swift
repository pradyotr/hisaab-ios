import Charts
import SwiftUI
import BudgetCore

struct CategorySlice: Identifiable {
    let name: String
    let amount: Double
    let color: Color
    var id: String { name }
}

/// Shared by the app chart and the widget, so a category has the same colour in both.
enum CategoryPie {
    /// Fixed values checked for colour-blind separation and contrast in light and dark mode.
    /// The system orange, teal and green are too light for this.
    static let palette: [Color] = [
        Color(red: 0, green: 122 / 255, blue: 1),
        Color(red: 204 / 255, green: 112 / 255, blue: 0),
        Color(red: 0, green: 149 / 255, blue: 184 / 255),
        Color(red: 1, green: 45 / 255, blue: 85 / 255),
        Color(red: 175 / 255, green: 82 / 255, blue: 222 / 255),
        Color(red: 42 / 255, green: 166 / 255, blue: 72 / 255),
    ]

    /// Categories with a net refund have no slice, because a pie can't show a negative share.
    /// Each of the first categories created keeps its colour across cycles; later ones are "Other".
    static func slices(totals: [CategoryTotal], categories: [SpendCategory]) -> [CategorySlice] {
        let positive = totals.filter { $0.amount > 0 }
        var result: [CategorySlice] = []
        var rest = 0.0
        for total in positive {
            guard let id = total.categoryID else { continue }
            if let index = categories.firstIndex(where: { $0.id == id }), index < palette.count {
                result.append(CategorySlice(name: categories[index].name, amount: total.amount.doubleValue, color: palette[index]))
            } else {
                rest += total.amount.doubleValue
            }
        }
        if rest > 0 { result.append(CategorySlice(name: "Other", amount: rest, color: .brown)) }
        if let loose = positive.first(where: { $0.categoryID == nil }) {
            result.append(CategorySlice(name: "Uncategorized", amount: loose.amount.doubleValue, color: .gray))
        }
        return result
    }
}

struct CategoryDonut: View {
    let slices: [CategorySlice]

    var body: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Spent", slice.amount), innerRadius: .ratio(0.6), angularInset: 1)
                .cornerRadius(3)
                .foregroundStyle(slice.color)
        }
    }
}
