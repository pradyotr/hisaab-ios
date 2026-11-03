import Foundation

/// What the user commits to: either an amount to save, or a cap on spending. The other is derived.
public enum BudgetGoal: Codable, Equatable, Sendable {
    case save(Decimal)
    case spendCap(Decimal)
}

public struct BudgetConfig: Codable, Equatable, Sendable {
    public var monthlyIncome: Decimal
    public var goal: BudgetGoal
    /// Day of month the budget cycle starts (1...28). Use the salary date if paid mid-month.
    public var cycleStartDay: Int
    public var currencyCode: String

    public init(monthlyIncome: Decimal, goal: BudgetGoal, cycleStartDay: Int = 1, currencyCode: String = "INR") {
        self.monthlyIncome = monthlyIncome
        self.goal = goal
        self.cycleStartDay = BudgetConfig.clampStartDay(cycleStartDay)
        self.currencyCode = currencyCode
    }

    /// Total amount that may be spent in one cycle.
    public var spendCap: Decimal {
        switch goal {
        case .save(let saving): return max(monthlyIncome - saving, 0)
        case .spendCap(let cap): return max(cap, 0)
        }
    }

    /// Amount that will be saved if exactly `spendCap` is spent.
    public var savingsTarget: Decimal {
        switch goal {
        case .save(let saving): return saving
        case .spendCap(let cap): return monthlyIncome - cap
        }
    }

    static func clampStartDay(_ day: Int) -> Int { min(max(day, 1), 28) }
}
