import Foundation

public enum OrganizationPatternError: Error, Equatable {
    case unknownVariable(String)
    case emptyTemplate
    case missingExtensionToken
}

public struct OrganizationPattern: Sendable, Equatable {
    public static let `default` = try! OrganizationPattern(template: "{year}/{month}/{year}-{month}-{day}_{activity}_{title}.{ext}")

    public static let presets: [(label: String, template: String)] = [
        ("Chronologique (défaut)", "{year}/{month}/{year}-{month}-{day}_{activity}_{title}.{ext}"),
        ("Activité d'abord",       "{activity}/{year}/{month}/{year}-{month}-{day}_{title}.{ext}"),
        ("Année puis activité",    "{year}/{activity}/{year}-{month}-{day}_{title}.{ext}")
    ]

    private static let knownVariables: Set<String> = [
        "year", "month", "day", "activity", "subactivity", "title", "ext"
    ]

    public let template: String

    public init(template: String) throws {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OrganizationPatternError.emptyTemplate }

        for variable in Self.extractVariables(from: trimmed) {
            guard Self.knownVariables.contains(variable) else {
                throw OrganizationPatternError.unknownVariable(variable)
            }
        }

        guard trimmed.contains("{ext}") else { throw OrganizationPatternError.missingExtensionToken }

        self.template = trimmed
    }

    public func relativePath(for activity: ActivityDescriptor, calendar: Calendar = .iso8601UTC) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: activity.startDate)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)

        let substitutions: [String: String] = [
            "year": year,
            "month": month,
            "day": day,
            "activity": activity.activityType.shortName,
            "subactivity": activity.activityType.subactivityName,
            "title": activity.title.slugified,
            "ext": activity.sourceFileFormat.rawValue
        ]

        var output = template
        for (key, value) in substitutions {
            output = output.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return output.replacingOccurrences(of: "//", with: "/")
    }

    private static func extractVariables(from template: String) -> Set<String> {
        var result: Set<String> = []
        let pattern = #"\{([a-zA-Z]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(template.startIndex..., in: template)
        regex.enumerateMatches(in: template, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: template) else { return }
            result.insert(String(template[r]))
        }
        return result
    }
}

public extension Calendar {
    static let iso8601UTC: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()
}
