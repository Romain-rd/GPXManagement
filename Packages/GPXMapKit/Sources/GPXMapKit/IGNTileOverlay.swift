import Foundation
import MapKit

public final class IGNTileOverlay: MKTileOverlay {
    private static let publicEndpoint = "https://data.geopf.fr/wmts"
    private static let privateEndpoint = "https://data.geopf.fr/private/wmts"
    private let layerIdentifier: String
    private let format: String
    private let tileMatrixSet: String
    private let apiKey: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    public init(layer: MapLayer) {
        guard let identifier = layer.wmtsLayerIdentifier else {
            fatalError("IGNTileOverlay can only be created for IGN layers; got \(layer)")
        }
        self.layerIdentifier = identifier
        self.format = layer.wmtsFormat
        self.tileMatrixSet = layer.wmtsTileMatrixSet
        self.apiKey = layer.discoveryAPIKey
        super.init(urlTemplate: nil)
        self.maximumZ = layer.maxZoom
        self.minimumZ = 0
        self.canReplaceMapContent = true
        self.tileSize = CGSize(width: 256, height: 256)
    }

    public override func url(forTilePath path: MKTileOverlayPath) -> URL {
        Self.buildURL(layerIdentifier: layerIdentifier, format: format, tileMatrixSet: tileMatrixSet, apiKey: apiKey, z: path.z, x: path.x, y: path.y)
    }

    public override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let url = self.url(forTilePath: path)
        Self.load(url: url, attemptsLeft: 3, session: Self.session, result: result)
    }

    private static func load(url: URL, attemptsLeft: Int, session: URLSession, result: @escaping (Data?, (any Error)?) -> Void) {
        let task = session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, !data.isEmpty {
                result(data, nil)
                return
            }
            // 404 = pas de tuile à ce niveau/zone : inutile de réessayer.
            if status == 404 {
                result(nil, error)
                return
            }
            if attemptsLeft > 1 {
                let backoff = 0.4 * Double(4 - attemptsLeft)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + backoff) {
                    load(url: url, attemptsLeft: attemptsLeft - 1, session: session, result: result)
                }
            } else {
                result(data, error)
            }
        }
        task.resume()
    }

    static func buildURL(layerIdentifier: String, format: String, tileMatrixSet: String = "PM", apiKey: String? = nil, z: Int, x: Int, y: Int) -> URL {
        let endpoint = apiKey == nil ? publicEndpoint : privateEndpoint
        var components = URLComponents(string: endpoint)!
        var items: [URLQueryItem] = []
        if let apiKey {
            items.append(URLQueryItem(name: "apikey", value: apiKey))
        }
        items.append(contentsOf: [
            URLQueryItem(name: "SERVICE", value: "WMTS"),
            URLQueryItem(name: "REQUEST", value: "GetTile"),
            URLQueryItem(name: "VERSION", value: "1.0.0"),
            URLQueryItem(name: "LAYER", value: layerIdentifier),
            URLQueryItem(name: "STYLE", value: "normal"),
            URLQueryItem(name: "FORMAT", value: format),
            URLQueryItem(name: "TILEMATRIXSET", value: tileMatrixSet),
            URLQueryItem(name: "TILEMATRIX", value: String(z)),
            URLQueryItem(name: "TILEROW", value: String(y)),
            URLQueryItem(name: "TILECOL", value: String(x))
        ])
        components.queryItems = items
        return components.url!
    }
}
