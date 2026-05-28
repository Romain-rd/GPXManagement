import Foundation

public enum RouteNameBuilder {
    public static func build(startName: String?, viaName: String?, endName: String?, isLoop: Bool) -> String? {
        let start = clean(startName)
        let via = clean(viaName)
        let end = clean(endName)

        if isLoop {
            guard let start else {
                if let via { return "Boucle par \(via)" }
                return nil
            }
            if let via, via != start {
                return "Boucle de \(start) par \(via)"
            }
            return "Boucle de \(start)"
        }

        switch (start, end) {
        case let (s?, e?):
            if s == e {
                if let via, via != s { return "Boucle de \(s) par \(via)" }
                return "Boucle de \(s)"
            }
            if let via, via != s, via != e {
                return "\(s) → \(via) → \(e)"
            }
            return "\(s) → \(e)"
        case let (s?, nil):
            if let via, via != s { return "\(s) → \(via)" }
            return "Départ de \(s)"
        case let (nil, e?):
            if let via, via != e { return "\(via) → \(e)" }
            return "Arrivée à \(e)"
        case (nil, nil):
            if let via { return "Par \(via)" }
            return nil
        }
    }

    private static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
