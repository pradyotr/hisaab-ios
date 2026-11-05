import Foundation

/// How much each entry adds to the budget. Pure function of the entries list: nothing derived is stored.
///
/// | Kind            | Counts                                               |
/// |-----------------|------------------------------------------------------|
/// | spend           | + amount                                             |
/// | savings         | 0 (it is saved, not spent; reported as `invested`)   |
/// | cardBill        | + the part not covered by open card charges          |
/// | refund/cashback | − amount, on its own date                            |
/// | reversal        | linked: cancels the original (both count 0); not linked: − amount |
/// | otherCredit     | 0                                                    |
/// | excluded entry  | 0                                                    |
///
/// Credit card matching (oldest first, per card when both name a card; no card matches any card):
/// - A debit on a card (spend or savings) is an open charge, after using up any open card credit.
/// - A refund / cashback / unlinked reversal on a card first reduces open charges; the rest is an open
///   card credit that reduces the next charges (the bill will be smaller by that much).
/// - A bill covers open charges from on or before its date; only what is left over counts.
/// - A partial payment counts 0, and the rest of the charges stay open for the next bill.
/// Excluded entries still take part in matching, because the money really moved on the card.
public enum Counting {
    public struct Amounts: Equatable, Sendable {
        /// Signed amount added to "spent".
        public var counted: Decimal
        /// Amount added to "invested" (savings entries only).
        public var invested: Decimal
    }

    public static func evaluate(_ entries: [Spend]) -> [UUID: Amounts] {
        // Linked reversals reduce their original's amount, and count 0 themselves.
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reversedAmount: [UUID: Decimal] = [:]
        var linkedReversals = Set<UUID>()
        for entry in entries where entry.kind == .reversal {
            guard let target = entry.reverses, let original = byID[target], !original.kind.isCredit else { continue }
            reversedAmount[target, default: 0] += entry.amount
            linkedReversals.insert(entry.id)
        }

        var results: [UUID: Amounts] = [:]
        var charges: [Open] = []
        var credits: [Open] = []

        for entry in ordered(entries) {
            if linkedReversals.contains(entry.id) {
                results[entry.id] = Amounts(counted: 0, invested: 0)
                continue
            }
            let amount = max(entry.amount - reversedAmount[entry.id, default: 0], 0)
            let card = normalizedCard(entry.card)
            let onCard = entry.account == .creditCard
            var counted: Decimal = 0
            var invested: Decimal = 0

            switch entry.kind {
            case .spend, .savings:
                if onCard {
                    let left = consume(amount, card: card, from: &credits)
                    if left > 0 { charges.append(Open(card: card, remaining: left)) }
                }
                if entry.kind == .spend { counted = amount } else { invested = amount }
            case .cardBill:
                counted = consume(amount, card: card, from: &charges)
            case .refund, .cashback, .reversal:
                if onCard {
                    let left = consume(amount, card: card, from: &charges)
                    if left > 0 { credits.append(Open(card: card, remaining: left)) }
                }
                counted = -amount
            case .otherCredit:
                break
            }

            results[entry.id] = entry.excluded ? Amounts(counted: 0, invested: 0) : Amounts(counted: counted, invested: invested)
        }
        return results
    }

    /// Signed amount each entry adds to "spent", keyed by id.
    public static func countedAmounts(_ entries: [Spend]) -> [UUID: Decimal] {
        evaluate(entries).mapValues(\.counted)
    }

    /// The entries with each amount replaced by its signed counted amount. Entries that count 0 are dropped.
    /// Pass ALL entries (not one cycle): a bill can cover card spends from an earlier cycle.
    public static func countedEntries(_ entries: [Spend]) -> [Spend] {
        replacingAmounts(entries, with: evaluate(entries).mapValues(\.counted))
    }

    /// Savings entries with their invested amount (after reversals). Entries that invest 0 are dropped.
    public static func investedEntries(_ entries: [Spend]) -> [Spend] {
        replacingAmounts(entries, with: evaluate(entries).mapValues(\.invested))
    }

    /// "XX1234", "card 1234", "1234" → "1234". Nil when there are no digits.
    public static func normalizedCard(_ text: String?) -> String? {
        guard let text else { return nil }
        let digits = text.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return String(digits.suffix(4))
    }

    // MARK: Private

    private struct Open {
        let card: String?
        var remaining: Decimal
    }

    /// Takes up to `amount` from the matching open items, oldest first. Returns what is left of `amount`.
    private static func consume(_ amount: Decimal, card: String?, from items: inout [Open]) -> Decimal {
        var left = amount
        for index in items.indices where left > 0 && items[index].remaining > 0 {
            let other = items[index].card
            guard card == nil || other == nil || card == other else { continue }
            let take = min(items[index].remaining, left)
            items[index].remaining -= take
            left -= take
        }
        items.removeAll { $0.remaining <= 0 }
        return left
    }

    private static func replacingAmounts(_ entries: [Spend], with amounts: [UUID: Decimal]) -> [Spend] {
        entries.compactMap { entry in
            guard let amount = amounts[entry.id], amount != 0 else { return nil }
            var copy = entry
            copy.amount = amount
            return copy
        }
    }

    /// Oldest first. At the same time: debits, then credits, then bills, so a bill can cover both.
    private static func ordered(_ entries: [Spend]) -> [Spend] {
        func rank(_ kind: EntryKind) -> Int {
            switch kind {
            case .spend, .savings: return 0
            case .refund, .reversal, .cashback, .otherCredit: return 1
            case .cardBill: return 2
            }
        }
        return entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if rank($0.kind) != rank($1.kind) { return rank($0.kind) < rank($1.kind) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
