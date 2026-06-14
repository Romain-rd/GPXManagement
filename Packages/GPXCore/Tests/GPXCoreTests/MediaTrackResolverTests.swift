import XCTest
@testable import GPXCore

final class MediaTrackResolverTests: XCTestCase {
    // Aller-retour : 0 → 0.002° → retour à 0, horodaté toutes les 100 s.
    private func outAndBack() -> [TrackPoint] {
        let t0 = Date(timeIntervalSince1970: 0)
        return [
            TrackPoint(latitude: 0, longitude: 0,     timestamp: t0),
            TrackPoint(latitude: 0, longitude: 0.001, timestamp: t0.addingTimeInterval(100)),
            TrackPoint(latitude: 0, longitude: 0.002, timestamp: t0.addingTimeInterval(200)), // demi-tour
            TrackPoint(latitude: 0, longitude: 0.001, timestamp: t0.addingTimeInterval(300)), // retour, même lieu que p1
            TrackPoint(latitude: 0, longitude: 0,     timestamp: t0.addingTimeInterval(400)),
        ]
    }

    func testTimeDisambiguatesOutAndBack() {
        let r = MediaTrackResolver(points: outAndBack())
        let total = r.totalDistance
        // Photo prise à t=300 s (jambe retour) à la position de p1/p3.
        let date = Date(timeIntervalSince1970: 300)
        let d = r.distance(manualMeters: nil, captureDate: date, gpsLatitude: 0, gpsLongitude: 0.001)!
        // Sans l'heure, le GPS (0,0.001) est ambigu (p1 OU p3). Avec l'heure, on doit être sur le retour (> moitié).
        XCTAssertGreaterThan(d, total / 2)
    }

    func testManualOverridesEverything() {
        let r = MediaTrackResolver(points: outAndBack())
        let d = r.distance(manualMeters: 123, captureDate: Date(timeIntervalSince1970: 0), gpsLatitude: 0, gpsLongitude: 0)!
        XCTAssertEqual(d, 123, accuracy: 0.001)
    }

    func testManualIsClampedToTrack() {
        let r = MediaTrackResolver(points: outAndBack())
        XCTAssertEqual(r.distance(manualMeters: -50, captureDate: nil, gpsLatitude: nil, gpsLongitude: nil), 0)
        XCTAssertEqual(r.distance(manualMeters: 1e9, captureDate: nil, gpsLatitude: nil, gpsLongitude: nil)!, r.totalDistance, accuracy: 0.001)
    }

    func testDisplayCoordinatePrefersRawGPS() {
        let r = MediaTrackResolver(points: outAndBack())
        let c = r.displayCoordinate(manualMeters: nil, captureDate: nil, gpsLatitude: 1.2345, gpsLongitude: 6.789)!
        XCTAssertEqual(c.latitude, 1.2345, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, 6.789, accuracy: 1e-9)
    }

    func testNilWhenNothingResolvable() {
        let r = MediaTrackResolver(points: outAndBack())
        XCTAssertNil(r.distance(manualMeters: nil, captureDate: nil, gpsLatitude: nil, gpsLongitude: nil))
        XCTAssertNil(r.displayCoordinate(manualMeters: nil, captureDate: nil, gpsLatitude: nil, gpsLongitude: nil))
    }
}
