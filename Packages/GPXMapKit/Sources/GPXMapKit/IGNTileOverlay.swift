import Foundation
import MapKit

public final class IGNTileOverlay: MKTileOverlay {
    private static let endpoint = "https://data.geopf.fr/wmts"
    private let layerIdentifier: String
    private let format: String

    public init(layer: MapLayer) {
        guard let identifier = layer.wmtsLayerIdentifier else {
            fatalError("IGNTileOverlay can only be created for IGN layers; got \(layer)")
        }
        self.layerIdentifier = identifier
        self.format = layer.wmtsFormat
        super.init(urlTemplate: nil)
        self.maximumZ = layer.maxZoom
        self.minimumZ = 0
        self.canReplaceMapContent = true
        self.tileSize = CGSize(width: 256, height: 256)
    }

    public override func url(forTilePath path: MKTileOverlayPath) -> URL {
        Self.buildURL(layerIdentifier: layerIdentifier, format: format, z: path.z, x: path.x, y: path.y)
    }

    static func buildURL(layerIdentifier: String, format: String, z: Int, x: Int, y: Int) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMTS"),
            URLQueryItem(name: "REQUEST", value: "GetTile"),
            URLQueryItem(name: "VERSION", value: "1.0.0"),
            URLQueryItem(name: "LAYER", value: layerIdentifier),
            URLQueryItem(name: "STYLE", value: "normal"),
            URLQueryItem(name: "FORMAT", value: format),
            URLQueryItem(name: "TILEMATRIXSET", value: "PM"),
            URLQueryItem(name: "TILEMATRIX", value: String(z)),
            URLQueryItem(name: "TILEROW", value: String(y)),
            URLQueryItem(name: "TILECOL", value: String(x))
        ]
        return components.url!
    }
}
