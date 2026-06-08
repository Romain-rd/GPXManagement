import Foundation

public enum RouteNameBuilder {
    public static func build(startName: String?, viaNames: [String?], endName: String?, isLoop: Bool) -> String? {
        let start = clean(startName)
        let vias = viaNames.compactMap(clean)
        let end = clean(endName)

        // Séquence des étapes (départ → vias → arrivée), sans doublon consécutif.
        var stops: [String] = []
        func add(_ name: String?) { if let name, name != stops.last { stops.append(name) } }
        add(start)
        vias.forEach { add($0) }
        add(end)

        // Boucle (détectée, ou départ == arrivée) sans point de passage → rien à lister.
        let isClosed = isLoop || (start != nil && start == end)
        if isClosed && vias.isEmpty {
            if let start { return "Boucle de \(start)" }
            return nil
        }

        switch (start, end) {
        case (nil, nil):
            if stops.isEmpty { return nil }
            return stops.count == 1 ? "Par \(stops[0])" : stops.joined(separator: " → ")
        case let (s?, nil):
            return stops.count >= 2 ? stops.joined(separator: " → ") : "Départ de \(s)"
        case let (nil, e?):
            return stops.count >= 2 ? stops.joined(separator: " → ") : "Arrivée à \(e)"
        case (_?, _?):
            return stops.joined(separator: " → ")
        }
    }

    private static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
