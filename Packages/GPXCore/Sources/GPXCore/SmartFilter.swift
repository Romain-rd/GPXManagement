import Foundation

public enum SmartFilterField: String, Codable, CaseIterable, Sendable {
    case activityType, date, distance, elevationGain, duration, avgSpeed, avgHeartRate, source, tag, raid, text
}

public enum SmartFilterOperator: String, Codable, Sendable {
    case isEqual, isNot, contains, greater, less, between, before, after, isTrue, isFalse
}

public struct SmartFilterRule: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var field: SmartFilterField
    public var op: SmartFilterOperator
    public var stringValue: String
    public var number1: Double
    public var number2: Double

    public init(id: UUID = UUID(), field: SmartFilterField = .distance, op: SmartFilterOperator = .greater,
                stringValue: String = "", number1: Double = 0, number2: Double = 0) {
        self.id = id
        self.field = field
        self.op = op
        self.stringValue = stringValue
        self.number1 = number1
        self.number2 = number2
    }
}

public struct SmartFilter: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var matchAll: Bool
    public var rules: [SmartFilterRule]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, matchAll: Bool = true, rules: [SmartFilterRule] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.matchAll = matchAll
        self.rules = rules
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func matches(_ s: ActivitySummary) -> Bool {
        guard !rules.isEmpty else { return true }
        return matchAll ? rules.allSatisfy { $0.matches(s) } : rules.contains { $0.matches(s) }
    }
}

extension SmartFilterRule {
    public func matches(_ s: ActivitySummary) -> Bool {
        switch field {
        case .activityType:
            switch op {
            case .isNot: return s.activityType.rawValue != stringValue
            default:     return s.activityType.rawValue == stringValue
            }
        case .source:
            switch op {
            case .isNot: return s.source.id != stringValue
            default:     return s.source.id == stringValue
            }
        case .tag:
            switch op {
            case .isEqual: return s.tags.contains(stringValue)
            default:       return s.tags.contains { $0.range(of: stringValue, options: .caseInsensitive) != nil }
            }
        case .text:
            let haystack = (s.title + " " + (s.notes ?? "")).lowercased()
            return stringValue.isEmpty || haystack.contains(stringValue.lowercased())
        case .raid:
            return op == .isFalse ? (s.raidId == nil) : (s.raidId != nil)
        case .date:
            let year = Double(Calendar.current.component(.year, from: s.startDate))
            switch op {
            case .before:  return year < number1
            case .after:   return year > number1
            case .between: return year >= Swift.min(number1, number2) && year <= Swift.max(number1, number2)
            default:       return year == number1
            }
        case .distance, .elevationGain, .duration, .avgSpeed, .avgHeartRate:
            guard let value = numericValue(of: s) else { return false }
            switch op {
            case .less:    return value < number1
            case .between: return value >= Swift.min(number1, number2) && value <= Swift.max(number1, number2)
            default:       return value > number1
            }
        }
    }

    private func numericValue(of s: ActivitySummary) -> Double? {
        switch field {
        case .distance:      return s.distance / 1000
        case .elevationGain: return s.elevationGain
        case .duration:      return s.duration / 60
        case .avgSpeed:      return s.avgSpeed * 3.6
        case .avgHeartRate:  return s.avgHeartRate
        default:             return nil
        }
    }
}
