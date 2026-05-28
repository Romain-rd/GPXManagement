import Foundation

public enum MapLayer: String, CaseIterable, Identifiable, Sendable {
    case ignScan25          = "ign_scan25"
    case ignPlanV2          = "ign_planv2"
    case ignTopoModern      = "ign_topo_modern"
    case ignSlopes          = "ign_slopes"
    case ignOrthophotos     = "ign_orthophotos"
    case mapkitStandard     = "mapkit_standard"
    case mapkitSatellite    = "mapkit_satellite"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ignScan25:        return "IGN — SCAN 25 (Top 25)"
        case .ignPlanV2:        return "IGN — Plan v2"
        case .ignTopoModern:    return "IGN — Carte topo"
        case .ignSlopes:        return "IGN — Pentes ski"
        case .ignOrthophotos:   return "IGN — Orthophotos"
        case .mapkitStandard:   return "Apple — Standard"
        case .mapkitSatellite:  return "Apple — Satellite"
        }
    }

    public var isIGN: Bool {
        switch self {
        case .ignScan25, .ignPlanV2, .ignTopoModern, .ignSlopes, .ignOrthophotos: return true
        case .mapkitStandard, .mapkitSatellite:                                   return false
        }
    }

    public var wmtsLayerIdentifier: String? {
        switch self {
        case .ignScan25:        return "GEOGRAPHICALGRIDSYSTEMS.MAPS.SCAN25TOUR"
        case .ignPlanV2:        return "GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2"
        case .ignTopoModern:    return "GEOGRAPHICALGRIDSYSTEMS.MAPS.BDUNI.J1"
        case .ignSlopes:        return "GEOGRAPHICALGRIDSYSTEMS.SLOPES.MOUNTAIN"
        case .ignOrthophotos:   return "ORTHOIMAGERY.ORTHOPHOTOS"
        default:                return nil
        }
    }

    public var wmtsFormat: String {
        switch self {
        case .ignScan25, .ignOrthophotos: return "image/jpeg"
        default:                          return "image/png"
        }
    }

    /// Clé de découverte publique IGN requise pour les couches sous l'endpoint privé
    /// (`data.geopf.fr/private/wmts`). Le SCAN 25 est un produit sous licence : usage
    /// personnel toléré, à vérifier pour toute redistribution.
    public var discoveryAPIKey: String? {
        switch self {
        case .ignScan25: return "ign_scan_ws"
        default:         return nil
        }
    }

    public var maxZoom: Int {
        switch self {
        case .ignScan25:        return 16
        case .ignPlanV2:        return 18
        case .ignTopoModern:    return 18
        case .ignSlopes:        return 17
        case .ignOrthophotos:   return 19
        default:                return 21
        }
    }
}
