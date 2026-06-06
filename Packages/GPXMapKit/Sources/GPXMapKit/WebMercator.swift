import Foundation

/// Projection Web Mercator (schéma de tuiles XYZ/WMTS « PM », tuiles 256 px).
public enum WebMercator {
    /// Position d'un point (lat/lon) en pixels monde au zoom `z` (origine en haut-gauche, y vers le bas).
    public static func pixel(lat: Double, lon: Double, z: Int) -> (x: Double, y: Double) {
        let worldPx = 256.0 * pow(2.0, Double(z))
        let x = (lon + 180.0) / 360.0 * worldPx
        let s = sin(lat * .pi / 180.0)
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * worldPx
        return (x, y)
    }
}
