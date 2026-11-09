import Foundation

/// Feature families, each with its own importance in the score.
enum FeatureGroup: String, CaseIterable, Sendable {
    case merchant, merchantWord, merchantAmount, upiHandle
    case amount, exactAmount
    case method, card
    case weekday, weekend, hour, dayOfMonth, partOfMonth, cycleDay
    case smsWord

    var weight: Double {
        switch self {
        case .merchant: return 3
        case .merchantAmount: return 2.5
        case .exactAmount: return 1.5
        case .merchantWord, .amount: return 1
        case .hour: return 0.75
        case .upiHandle, .method, .card, .weekday, .dayOfMonth: return 0.5
        case .weekend, .partOfMonth, .cycleDay: return 0.25
        case .smsWord: return 0.15
        }
    }
}

struct LearningFeature: Hashable, Sendable {
    let group: FeatureGroup
    let value: String
}

enum FeatureExtractor {
    static func features(of entry: Spend, calendar: Calendar, cycleStartDay: Int) -> [LearningFeature] {
        var result: [LearningFeature] = []
        func add(_ group: FeatureGroup, _ value: String) { result.append(LearningFeature(group: group, value: value)) }

        let amount = max(entry.amount.doubleValue, 0.01)
        // Two overlapping buckets, so amounts near a bucket edge still share one with their neighbours.
        let scaled = log(amount) / log(1.5)
        add(.amount, "a\(Int(scaled.rounded(.down)))")
        add(.amount, "b\(Int((scaled + 0.5).rounded(.down)))")
        add(.exactAmount, "\(entry.amount)")

        if let key = entry.merchantKey {
            add(.merchant, key)
            for word in key.split(separator: " ") where word.count >= 3 { add(.merchantWord, String(word)) }
            // Together, because one recipient can mean different things at different amounts.
            let coarse = Int((log(amount) / log(3)).rounded(.down))
            add(.merchantAmount, "\(key)|\(coarse)")
        }
        if let merchant = entry.merchant, let at = merchant.firstIndex(of: "@") {
            add(.upiHandle, merchant[merchant.index(after: at)...].lowercased())
        }

        add(.method, entry.method.rawValue)
        if let card = Counting.normalizedCard(entry.card) { add(.card, card) }

        let parts = calendar.dateComponents([.weekday, .hour, .day], from: entry.date)
        if let weekday = parts.weekday {
            add(.weekday, "\(weekday)")
            add(.weekend, weekday == 1 || weekday == 7 ? "yes" : "no")
        }
        if let hour = parts.hour {
            add(.hour, "a\(hour / 2)")
            add(.hour, "b\((hour + 1) / 2)")
        }
        if let day = parts.day {
            add(.dayOfMonth, "\(day)")
            add(.partOfMonth, "\(min((day - 1) / 10, 2))")
            add(.cycleDay, "\(((day - cycleStartDay + 31) % 31) / 5)")
        }

        if let text = entry.rawText {
            let words = text.lowercased().split { !$0.isLetter }.filter { $0.count >= 3 }
            for word in Set(words.map { String($0) }) { add(.smsWord, word) }
        }
        return result
    }
}

/// Weighted Naive Bayes. Works from counts, needs little data and accepts new labels at any time.
/// Generic, so any decision the app learns can use it.
struct NaiveBayesLearner<Label: Hashable & Sendable>: Sendable {
    /// Naive Bayes is overconfident because its features overlap. A higher temperature softens that.
    static var temperature: Double { 3 }
    private static var smoothing: Double { 0.5 }

    private var labels: [Label] = []
    private var labelWeight: [Label: Double] = [:]
    private var featureWeight: [Label: [LearningFeature: Double]] = [:]
    private var groupWeight: [Label: [FeatureGroup: Double]] = [:]
    private var groupValues: [FeatureGroup: Set<String>] = [:]

    mutating func add(_ features: [LearningFeature], label: Label, weight: Double) {
        if labelWeight[label] == nil { labels.append(label) }
        labelWeight[label, default: 0] += weight
        for feature in features {
            featureWeight[label, default: [:]][feature, default: 0] += weight
            groupWeight[label, default: [:]][feature.group, default: 0] += weight
            groupValues[feature.group, default: []].insert(feature.value)
        }
    }

    /// Best first. Confidences add up to 1. Empty before any training.
    func rank(_ features: [LearningFeature]) -> [(label: Label, confidence: Double)] {
        guard !labels.isEmpty else { return [] }
        // A value never seen for any label says nothing. Counting it would only penalise the bigger labels.
        let known = features.filter { groupValues[$0.group]?.contains($0.value) ?? false }
        let total = labelWeight.values.reduce(0, +)
        let smoothing = Self.smoothing
        let scores: [Double] = labels.map { label in
            var score = log((labelWeight[label, default: 0] + 1) / (total + Double(labels.count)))
            for feature in known {
                let count = featureWeight[label]?[feature] ?? 0
                let groupTotal = groupWeight[label]?[feature.group] ?? 0
                let distinct = Double(groupValues[feature.group]?.count ?? 1)
                score += feature.group.weight * log((count + smoothing) / (groupTotal + smoothing * distinct))
            }
            return score / Self.temperature
        }
        let best = scores.max() ?? 0
        let relative = scores.map { exp($0 - best) }
        let sum = relative.reduce(0, +)
        return zip(labels, relative)
            .map { (label: $0, confidence: $1 / sum) }
            .enumerated()
            .sorted { $0.element.confidence != $1.element.confidence ? $0.element.confidence > $1.element.confidence : $0.offset < $1.offset }
            .map { $0.element }
    }
}

public struct CategoryCandidate: Codable, Equatable, Sendable {
    public let categoryID: UUID
    public let confidence: Double

    public init(categoryID: UUID, confidence: Double) {
        self.categoryID = categoryID
        self.confidence = confidence
    }
}

/// What the app guessed when it logged an entry. Frozen then, so a later change in the model
/// doesn't rewrite history, and so a correction can be recognised.
public struct CategoryPrediction: Codable, Equatable, Sendable {
    /// Up to three, best first.
    public var candidates: [CategoryCandidate]
    /// Plain words for the user, for example "4 of 5 past Swiggy spends".
    public var reason: String?
    /// Whether there was enough evidence to assign the top candidate.
    public var autoAssign: Bool

    public init(candidates: [CategoryCandidate], reason: String? = nil, autoAssign: Bool = false) {
        self.candidates = candidates
        self.reason = reason
        self.autoAssign = autoAssign
    }
}

/// How the model would have done on the user's own history: each label predicted only from earlier labels.
public struct CategoryReplayResult: Equatable, Sendable {
    public var labels = 0
    public var tested = 0
    public var topCorrect = 0
    public var topThreeCorrect = 0
    public var autoAssigned = 0
    public var autoCorrect = 0
}

/// Predicts categories from the labels the user made. Nothing is stored: it is rebuilt from the entries.
struct CategoryPredictor: Sendable {
    /// Below this, nothing is auto-assigned.
    static let minimumLabels = 3
    /// The recipient has been labelled before.
    static let knownMerchantConfidence = 0.45
    /// A new recipient needs far more evidence.
    static let newMerchantConfidence = 0.75
    static let newMerchantMinimumLabels = 50
    /// Corrections teach more than ordinary labels.
    static let correctionWeight = 3.0
    /// A label loses half its weight over this time, so changed habits win.
    static let halfLife: TimeInterval = 180 * 86_400

    private struct Sample: Sendable {
        let id: UUID
        let label: UUID
        let date: Date
        let merchantKey: String?
        let features: [LearningFeature]
        let isCorrection: Bool
    }

    private let samples: [Sample]
    private let calendar: Calendar
    private let cycleStartDay: Int

    init(ledger: Ledger, calendar: Calendar) {
        self.calendar = calendar
        let startDay = ledger.config?.cycleStartDay ?? 1
        self.cycleStartDay = startDay
        let valid = Set(ledger.categories.map(\.id))
        samples = ledger.transactions.compactMap { entry -> Sample? in
            guard entry.sources.category == .user, let label = entry.categoryID, valid.contains(label) else { return nil }
            // A correction means the app assigned something wrong. Choosing past a mere suggestion is an ordinary label.
            let wrongAssignment = entry.prediction.map { $0.autoAssign && $0.candidates.first?.categoryID != label } ?? false
            return Sample(id: entry.id, label: label, date: entry.date, merchantKey: entry.merchantKey,
                          features: FeatureExtractor.features(of: entry, calendar: calendar, cycleStartDay: startDay),
                          isCorrection: wrongAssignment)
        }
        .sorted { $0.date < $1.date }
    }

    var labelCount: Int { samples.count }

    func predict(_ entry: Spend) -> CategoryPrediction? {
        let features = FeatureExtractor.features(of: entry, calendar: calendar, cycleStartDay: cycleStartDay)
        return predict(entry, features: features, training: samples.filter { $0.id != entry.id })
    }

    private func predict(_ entry: Spend, features: [LearningFeature], training: [Sample]) -> CategoryPrediction? {
        guard !training.isEmpty else { return nil }
        var learner = NaiveBayesLearner<UUID>()
        for sample in training {
            let age = abs(entry.date.timeIntervalSince(sample.date))
            let weight = pow(0.5, age / Self.halfLife) * (sample.isCorrection ? Self.correctionWeight : 1)
            learner.add(sample.features, label: sample.label, weight: weight)
        }
        let ranked = learner.rank(features)
        guard let top = ranked.first else { return nil }

        let key = entry.merchantKey
        let sameMerchant = key == nil ? [] : training.filter { $0.merchantKey == key }
        let enough = training.count >= Self.minimumLabels
        let autoAssign: Bool
        if sameMerchant.isEmpty {
            autoAssign = training.count >= Self.newMerchantMinimumLabels && top.confidence >= Self.newMerchantConfidence
        } else {
            autoAssign = enough && top.confidence >= Self.knownMerchantConfidence
        }

        let reason: String
        if sameMerchant.isEmpty {
            reason = "Based on similar amounts and times"
        } else {
            let matching = sameMerchant.filter { $0.label == top.label }.count
            reason = "\(matching) of \(sameMerchant.count) past \(entry.merchant ?? "similar") spends"
        }
        let candidates = ranked.prefix(3).map { CategoryCandidate(categoryID: $0.label, confidence: $0.confidence) }
        return CategoryPrediction(candidates: Array(candidates), reason: reason, autoAssign: autoAssign)
    }

    /// Predicts the latest `limit` labels, each using only the labels before it.
    func replay(limit: Int = 200) -> CategoryReplayResult {
        var result = CategoryReplayResult()
        result.labels = samples.count
        guard samples.count > 1 else { return result }
        for index in max(1, samples.count - limit)..<samples.count {
            let sample = samples[index]
            // Only the fields the prediction reads: the date and the merchant.
            let probe = Spend(amount: 1, date: sample.date, merchant: sample.merchantKey)
            guard let prediction = predict(probe, features: sample.features, training: Array(samples[..<index])) else { continue }
            let ids = prediction.candidates.map(\.categoryID)
            result.tested += 1
            if ids.first == sample.label { result.topCorrect += 1 }
            if ids.contains(sample.label) { result.topThreeCorrect += 1 }
            if prediction.autoAssign {
                result.autoAssigned += 1
                if ids.first == sample.label { result.autoCorrect += 1 }
            }
        }
        return result
    }
}

extension Ledger {
    /// The guess for this entry from the current labels. Changes nothing.
    public func categoryPrediction(for entry: Spend, calendar: Calendar = .current) -> CategoryPrediction? {
        CategoryPredictor(ledger: self, calendar: calendar).predict(entry)
    }

    /// Accuracy on the user's own history.
    public func categoryReplay(calendar: Calendar = .current) -> CategoryReplayResult {
        CategoryPredictor(ledger: self, calendar: calendar).replay()
    }

    /// Fills in predictions for entries that need a category. Returns how many got one assigned.
    @discardableResult
    public mutating func predictUncategorized(calendar: Calendar = .current) -> Int {
        var assigned = 0
        let predictor = CategoryPredictor(ledger: self, calendar: calendar)
        let ids = Set(entriesNeedingCategory.map(\.id))
        for index in transactions.indices where ids.contains(transactions[index].id) {
            guard let prediction = predictor.predict(transactions[index]) else { continue }
            applyPrediction(prediction, at: index)
            if transactions[index].categoryID != nil { assigned += 1 }
        }
        return assigned
    }

    /// Predicts one entry, if its category is not the user's and the entry counts towards spending.
    mutating func predictCategory(at index: Int, calendar: Calendar) {
        guard !categories.isEmpty, transactions[index].sources.category != .user else { return }
        let entry = transactions[index]
        guard (Counting.countedAmounts(transactions)[entry.id] ?? 0) != 0 else { return }
        applyPrediction(CategoryPredictor(ledger: self, calendar: calendar).predict(entry), at: index)
    }

    private mutating func applyPrediction(_ prediction: CategoryPrediction?, at index: Int) {
        transactions[index].prediction = prediction
        if let prediction, prediction.autoAssign, let top = prediction.candidates.first {
            transactions[index].categoryID = top.categoryID
            transactions[index].sources.category = .learned
        } else if transactions[index].sources.category == .learned {
            transactions[index].categoryID = nil
            transactions[index].sources.category = nil
        }
    }
}
