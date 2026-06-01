import Foundation

public enum MapLayer: String, CaseIterable, Identifiable, Sendable {
    // France (IGN — WMTS)
    case ignScan25          = "ign_scan25"
    case ignPlanV2          = "ign_planv2"
    case ignTopoModern      = "ign_topo_modern"
    case ignSlopes          = "ign_slopes"
    case ignOrthophotos     = "ign_orthophotos"
    // Apple
    case mapkitStandard     = "mapkit_standard"
    case mapkitSatellite    = "mapkit_satellite"
    // Monde (tuiles XYZ)
    case osm                = "osm"
    case openTopoMap        = "opentopomap"
    case cyclOSM            = "cyclosm"
    case esriImagery        = "esri_imagery"
    // Espagne (IGN ES — WMTS KVP)
    case ignEsTopo          = "ign_es_mtn"
    case ignEsOrtho         = "ign_es_pnoa"
    // Suisse (swisstopo)
    case swissTopo          = "swisstopo_color"
    case swissImage         = "swisstopo_image"
    // Belgique (NGI)
    case ngiTopo            = "ngi_topo"

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
        case .osm:              return "OpenStreetMap"
        case .openTopoMap:      return "OpenTopoMap"
        case .cyclOSM:          return "CyclOSM (vélo)"
        case .esriImagery:      return "Esri — Satellite"
        case .ignEsTopo:        return "IGN España — Topo (MTN)"
        case .ignEsOrtho:       return "IGN España — Orthophotos"
        case .swissTopo:        return "swisstopo — Carte nationale"
        case .swissImage:       return "swisstopo — SwissImage"
        case .ngiTopo:          return "NGI — Topo (Cartoweb)"
        }
    }

    /// Regroupement par pays/zone pour l'organisation du sélecteur.
    public var country: String {
        switch self {
        case .ignScan25, .ignPlanV2, .ignTopoModern, .ignSlopes, .ignOrthophotos: return "France"
        case .mapkitStandard, .mapkitSatellite:                                    return "Apple"
        case .osm, .openTopoMap, .cyclOSM, .esriImagery:                           return "Monde"
        case .ignEsTopo, .ignEsOrtho:                                              return "Espagne"
        case .swissTopo, .swissImage:                                              return "Suisse"
        case .ngiTopo:                                                             return "Belgique"
        }
    }

    /// Ordre d'affichage des groupes.
    public static let countryOrder = ["France", "Monde", "Espagne", "Suisse", "Belgique", "Apple"]

    public var isApple: Bool { self == .mapkitStandard || self == .mapkitSatellite }

    public var isIGN: Bool {
        switch self {
        case .ignScan25, .ignPlanV2, .ignTopoModern, .ignSlopes, .ignOrthophotos: return true
        default: return false
        }
    }

    /// Gabarit d'URL de tuile XYZ ({z}/{x}/{y}) pour les couches non-IGN-France et non-Apple.
    public var tileURLTemplate: String? {
        switch self {
        case .osm:           return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .openTopoMap:   return "https://a.tile.opentopomap.org/{z}/{x}/{y}.png"
        case .cyclOSM:       return "https://a.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png"
        case .esriImagery:   return "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
        case .ignEsTopo:     return "https://www.ign.es/wmts/mapa-raster?service=WMTS&request=GetTile&version=1.0.0&layer=MTN&style=default&format=image/jpeg&tilematrixset=GoogleMapsCompatible&TileMatrix={z}&TileRow={y}&TileCol={x}"
        case .ignEsOrtho:    return "https://www.ign.es/wmts/pnoa-ma?service=WMTS&request=GetTile&version=1.0.0&layer=OI.OrthoimageCoverage&style=default&format=image/jpeg&tilematrixset=GoogleMapsCompatible&TileMatrix={z}&TileRow={y}&TileCol={x}"
        case .swissTopo:     return "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.pixelkarte-farbe/default/current/3857/{z}/{x}/{y}.jpeg"
        case .swissImage:    return "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.swissimage/default/current/3857/{z}/{x}/{y}.jpeg"
        case .ngiTopo:       return "https://cartoweb.wmts.ngi.be/1.0.0/topo/default/3857/{z}/{x}/{y}.png"
        default:             return nil
        }
    }

    /// Mention d'attribution à afficher (couches tierces).
    public var attribution: String? {
        switch self {
        case .ignScan25, .ignPlanV2, .ignTopoModern, .ignSlopes, .ignOrthophotos: return "© IGN-F / Géoportail"
        case .osm:           return "© OpenStreetMap contributors"
        case .openTopoMap:   return "© OpenTopoMap (CC-BY-SA) · © OpenStreetMap"
        case .cyclOSM:       return "CyclOSM · © OpenStreetMap contributors"
        case .esriImagery:   return "© Esri, Maxar, Earthstar Geographics"
        case .ignEsTopo, .ignEsOrtho: return "© Instituto Geográfico Nacional de España"
        case .swissTopo, .swissImage: return "© swisstopo"
        case .ngiTopo:       return "© NGI / IGN Belgique"
        case .mapkitStandard, .mapkitSatellite: return nil
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

    public var wmtsTileMatrixSet: String {
        switch self {
        case .ignScan25: return "PM_6_16"
        default:         return "PM"
        }
    }

    /// Clé de découverte publique IGN requise pour les couches sous l'endpoint privé.
    public var discoveryAPIKey: String? {
        switch self {
        case .ignScan25: return "ign_scan_ws"
        default:         return nil
        }
    }

    /// Nombre de tuiles téléchargées simultanément. Faible pour les couches OSM/OpenTopoMap
    /// (politique d'usage stricte, bannissement des rafales), plus élevé pour les serveurs robustes.
    public var maxConcurrentTileRequests: Int {
        switch self {
        case .openTopoMap:                  return 2
        case .osm, .cyclOSM:                return 3
        case .ignScan25, .ignPlanV2, .ignTopoModern, .ignSlopes, .ignOrthophotos: return 5
        case .ignEsTopo, .ignEsOrtho, .ngiTopo: return 4
        default:                            return 6
        }
    }

    public var maxZoom: Int {
        switch self {
        case .ignScan25:        return 16
        case .ignPlanV2:        return 18
        case .ignTopoModern:    return 18
        case .ignSlopes:        return 17
        case .ignOrthophotos:   return 19
        case .osm:              return 19
        case .openTopoMap:      return 17
        case .cyclOSM:          return 18
        case .esriImagery:      return 19
        case .ignEsTopo:        return 17
        case .ignEsOrtho:       return 19
        case .swissTopo:        return 18
        case .swissImage:       return 19
        case .ngiTopo:          return 17
        case .mapkitStandard, .mapkitSatellite: return 21
        }
    }
}
