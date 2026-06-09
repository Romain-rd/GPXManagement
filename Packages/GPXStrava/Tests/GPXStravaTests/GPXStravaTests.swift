import XCTest
@testable import GPXStrava

/// Intercepte les requêtes de URLSession.shared pour servir des réponses Strava simulées.
final class StravaMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.strava.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GPXStravaTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StravaMockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StravaMockURLProtocol.self)
        StravaMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - StravaAPI.activities

    func testActivitiesPageParsing() async throws {
        let payload: [[String: Any]] = [
            [
                "id": 123_456_789, "name": "Col d'Èze", "sport_type": "Ride",
                "start_date": "2026-05-27T08:30:00Z", "distance": 45_200.5,
                "start_latlng": [43.72, 7.36]
            ],
            [
                // Sans GPS (start_latlng vide) : retenu mais hasGPS = false.
                "id": 987, "name": "Home trainer", "type": "VirtualRide",
                "start_date": "2026-05-28T18:00:00Z", "distance": 20_000,
                "start_latlng": [Double]()
            ],
            [
                // Date invalide → entrée ignorée.
                "id": 1, "name": "Corrompue", "sport_type": "Ride", "start_date": "pas-une-date"
            ]
        ]
        StravaMockURLProtocol.handler = { [data = json(payload)] _ in (200, data) }

        let activities = try await StravaAPI().activities(accessToken: "tok", after: nil, page: 1)
        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0].id, 123_456_789)
        XCTAssertEqual(activities[0].name, "Col d'Èze")
        XCTAssertEqual(activities[0].sportType, "Ride")
        XCTAssertEqual(activities[0].distanceMeters, 45_200.5)
        XCTAssertTrue(activities[0].hasGPS)
        XCTAssertEqual(activities[1].sportType, "VirtualRide") // retombe sur "type" si sport_type absent
        XCTAssertFalse(activities[1].hasGPS)
    }

    func testActivitiesPassesAfterAndPagination() async throws {
        nonisolated(unsafe) var captured: URL?
        StravaMockURLProtocol.handler = { [data = json([[String: Any]]())] request in
            captured = request.url
            return (200, data)
        }
        let after = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await StravaAPI().activities(accessToken: "tok", after: after, page: 3, perPage: 25)

        let comps = URLComponents(url: try XCTUnwrap(captured), resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "page" }?.value, "3")
        XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "25")
        XCTAssertEqual(items.first { $0.name == "after" }?.value, "1750000000")
    }

    func testActivitiesRateLimitThrows() async {
        StravaMockURLProtocol.handler = { _ in (429, Data()) }
        do {
            _ = try await StravaAPI().activities(accessToken: "tok", after: nil, page: 1)
            XCTFail("Une erreur rateLimited était attendue")
        } catch StravaError.rateLimited {
            // attendu
        } catch {
            XCTFail("Erreur inattendue : \(error)")
        }
    }

    func testActivitiesHTTPErrorThrows() async {
        StravaMockURLProtocol.handler = { _ in (401, Data("{\"message\":\"Authorization Error\"}".utf8)) }
        do {
            _ = try await StravaAPI().activities(accessToken: "bad", after: nil, page: 1)
            XCTFail("Une erreur http était attendue")
        } catch StravaError.http(let code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("Erreur inattendue : \(error)")
        }
    }

    // MARK: - StravaAPI.streams

    func testStreamsReconstruction() async throws {
        let payload: [String: Any] = [
            "latlng": ["data": [[45.0, 6.0], [45.001, 6.001], [45.002, 6.002]]],
            "altitude": ["data": [1000.0, 1010.0, 1025.0]],
            "time": ["data": [0.0, 10.0, 20.0]],
            "heartrate": ["data": [120.0, 130.0, 140.0]]
        ]
        StravaMockURLProtocol.handler = { [data = json(payload)] _ in (200, data) }

        let points = try await StravaAPI().streams(accessToken: "tok", activityId: 42)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[1].latitude, 45.001)
        XCTAssertEqual(points[1].altitude, 1010)
        XCTAssertEqual(points[1].timeOffset, 10)
        XCTAssertEqual(points[1].heartRate, 130)
        XCTAssertNil(points[1].cadence)  // stream absent → nil
        XCTAssertNil(points[1].power)
    }

    func testStreamsMissingFieldsShorterThanLatLng() async throws {
        // Streams optionnels plus courts que latlng : pas de crash, valeurs nil au-delà.
        let payload: [String: Any] = [
            "latlng": ["data": [[45.0, 6.0], [45.001, 6.001]]],
            "altitude": ["data": [1000.0]]
        ]
        StravaMockURLProtocol.handler = { [data = json(payload)] _ in (200, data) }

        let points = try await StravaAPI().streams(accessToken: "tok", activityId: 42)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].altitude, 1000)
        XCTAssertNil(points[1].altitude)
    }

    func testStreamsWithoutLatLngReturnsEmpty() async throws {
        StravaMockURLProtocol.handler = { [data = json(["altitude": ["data": [1.0]]])] _ in (200, data) }
        let points = try await StravaAPI().streams(accessToken: "tok", activityId: 42)
        XCTAssertTrue(points.isEmpty)
    }

    // MARK: - StravaOAuth

    func testAuthorizationURL() {
        let oauth = StravaOAuth(clientId: "123", clientSecret: "secret")
        let url = oauth.authorizationURL(redirectURI: "http://127.0.0.1:8721/callback", state: "abc")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        XCTAssertEqual(comps?.host, "www.strava.com")
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, "123")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "http://127.0.0.1:8721/callback")
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "activity:read_all")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "abc")
        XCTAssertNil(items.first { $0.name == "client_secret" }) // jamais dans l'URL
    }

    func testExchangeCodeParsesTokensAndAthlete() async throws {
        let payload: [String: Any] = [
            "access_token": "at", "refresh_token": "rt", "expires_at": 1_800_000_000.0,
            "athlete": ["id": 555, "firstname": "Romain", "lastname": "D."]
        ]
        StravaMockURLProtocol.handler = { [data = json(payload)] _ in (200, data) }

        let tokens = try await StravaOAuth(clientId: "1", clientSecret: "s").exchangeCode("code")
        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertEqual(tokens.refreshToken, "rt")
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(tokens.athleteId, 555)
        XCTAssertEqual(tokens.athleteName, "Romain D.")
    }

    func testRefreshKeepsAthleteWhenAbsentFromResponse() async throws {
        let payload: [String: Any] = [
            "access_token": "at2", "refresh_token": "rt2", "expires_at": 1_900_000_000.0
        ]
        StravaMockURLProtocol.handler = { [data = json(payload)] _ in (200, data) }

        let previous = StravaTokens(accessToken: "at", refreshToken: "rt",
                                    expiresAt: .distantPast, athleteId: 555, athleteName: "Romain D.")
        let refreshed = try await StravaOAuth(clientId: "1", clientSecret: "s").refresh(previous)
        XCTAssertEqual(refreshed.accessToken, "at2")
        XCTAssertEqual(refreshed.athleteId, 555)
        XCTAssertEqual(refreshed.athleteName, "Romain D.")
    }

    func testTokensExpiryMargin() {
        let soon = StravaTokens(accessToken: "a", refreshToken: "r",
                                expiresAt: Date().addingTimeInterval(30), athleteId: 1, athleteName: nil)
        XCTAssertTrue(soon.isExpired) // expire dans 30 s < marge de 60 s
        let later = StravaTokens(accessToken: "a", refreshToken: "r",
                                 expiresAt: Date().addingTimeInterval(3600), athleteId: 1, athleteName: nil)
        XCTAssertFalse(later.isExpired)
    }
}
