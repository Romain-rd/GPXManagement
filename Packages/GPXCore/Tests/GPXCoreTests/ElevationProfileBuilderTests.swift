import XCTest
@testable import GPXCore

final class ElevationProfileBuilderTests: XCTestCase {
    func testTimeBreakdownPartitionsAndSumsToTotal() {
        let t0 = Date(timeIntervalSince1970: 0)
        func p(_ lat: Double, _ slope: Double, _ sec: Double) -> ElevationProfilePoint {
            ElevationProfilePoint(distanceFromStart: 0, altitude: 0, slope: slope, timestamp: t0.addingTimeInterval(sec), latitude: lat, longitude: 6.0)
        }
        // ~0,001° ≈ 111 m (déplacement franc) ; le dernier point reste à ~3 m → pause.
        let profile = [
            p(45.000,  5,   0),   // seg0 : montée 10 s
            p(45.001, -5,  10),   // seg1 : descente 10 s
            p(45.002,  0,  20),   // seg2 : plat 10 s
            p(45.003,  0,  30),   // seg3 : pause 360 s (reste dans le rayon)
            p(45.00303, 0, 390),
        ]
        let bd = ElevationProfileBuilder.timeBreakdown(profile)
        XCTAssertEqual(bd.ascending, 10)
        XCTAssertEqual(bd.descending, 10)
        XCTAssertEqual(bd.flat, 10)
        XCTAssertEqual(bd.paused, 360)
        XCTAssertEqual(bd.ascending + bd.descending + bd.flat + bd.paused, 390) // = temps total écoulé
    }

    func testEmptyReturnsEmpty() {
        let profile = ElevationProfileBuilder.build(points: [])
        XCTAssertTrue(profile.isEmpty)
    }

    func testSingleAltitudePointReturnsEmpty() {
        let p = TrackPoint(latitude: 45, longitude: 6, altitude: 100)
        XCTAssertTrue(ElevationProfileBuilder.build(points: [p]).isEmpty)
    }

    func testTimeByCategoryAccumulatesPerSlope() {
        let start = Date(timeIntervalSince1970: 0)
        var pts: [TrackPoint] = []
        // Montée raide (~10%) sur 100 points espacés de 10s, puis plat.
        for i in 0..<100 {
            let d = Double(i)
            pts.append(TrackPoint(
                latitude: 45.0 + d * 0.0001, longitude: 6.0,
                altitude: 1000 + d * 1.0,
                timestamp: start.addingTimeInterval(d * 10)
            ))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        let times = ElevationProfileBuilder.timeByCategory(profile)
        let total = times.values.reduce(0, +)
        XCTAssertGreaterThan(total, 0)
        // L'essentiel du temps doit être dans des catégories de montée, pas en descente.
        XCTAssertEqual(times[.descent] ?? 0, 0, accuracy: 1)
    }

    func testTimeByCategoryIgnoresGaps() {
        let start = Date(timeIntervalSince1970: 0)
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0, altitude: 100, timestamp: start),
            TrackPoint(latitude: 45.001, longitude: 6.0, altitude: 101, timestamp: start.addingTimeInterval(10)),
            // Gros gap (1h) → ignoré.
            TrackPoint(latitude: 45.002, longitude: 6.0, altitude: 102, timestamp: start.addingTimeInterval(3610)),
        ]
        let profile = ElevationProfileBuilder.build(points: pts)
        let times = ElevationProfileBuilder.timeByCategory(profile)
        XCTAssertEqual(times.values.reduce(0, +), 10, accuracy: 1)
    }

    func testMovementTimeSeparatesMovingAndPaused() {
        let start = Date(timeIntervalSince1970: 0)
        var pts: [TrackPoint] = []
        // 50 points en mouvement (~5 m/s), espacés de 5s.
        for i in 0..<50 {
            let d = Double(i)
            pts.append(TrackPoint(latitude: 45.0 + d * 0.0002, longitude: 6.0, altitude: 100 + d,
                                  timestamp: start.addingTimeInterval(d * 5)))
        }
        // 30 points immobiles (même position), espacés de 5s → pause.
        let pauseStart = start.addingTimeInterval(50 * 5)
        for i in 0..<30 {
            pts.append(TrackPoint(latitude: 45.01, longitude: 6.0, altitude: 150,
                                  timestamp: pauseStart.addingTimeInterval(Double(i) * 5)))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        let (moving, paused) = ElevationProfileBuilder.movementTime(profile)
        XCTAssertGreaterThan(moving, 0)
        XCTAssertGreaterThan(paused, 0)
        XCTAssertGreaterThan(paused, 100)
    }

    func testMonotonicAscentProducesPositiveSlope() {
        var pts: [TrackPoint] = []
        for i in 0..<200 {
            let d = Double(i)
            pts.append(TrackPoint(
                latitude: 45.0 + d * 0.00001,
                longitude: 6.0,
                altitude: 1000 + d * 0.5
            ))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        XCTAssertEqual(profile.count, 200)
        let slopes = profile.dropFirst(30).dropLast(30).map(\.slope)
        XCTAssertGreaterThan(slopes.first ?? 0, 0)
        XCTAssertLessThan(slopes.max() ?? 0, 100)
    }

    func testFlatTerrainHasZeroSlope() {
        var pts: [TrackPoint] = []
        for i in 0..<100 {
            pts.append(TrackPoint(latitude: 45.0 + Double(i) * 1e-5, longitude: 6.0, altitude: 1000))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        for p in profile.dropFirst(10).dropLast(10) {
            XCTAssertEqual(p.slope, 0, accuracy: 0.1)
        }
    }

    func testGPSNoiseDoesNotProduceExcessiveSlope() {
        var pts: [TrackPoint] = []
        for i in 0..<300 {
            let noise = Double.random(in: -2...2)
            pts.append(TrackPoint(
                latitude: 45.0 + Double(i) * 1e-5,
                longitude: 6.0,
                altitude: 1000 + noise
            ))
        }
        let profile = ElevationProfileBuilder.build(points: pts)
        for p in profile {
            XCTAssertLessThan(abs(p.slope), 80, "noise alone shouldn't produce >80% slope")
        }
    }

    func testDecimationReducesPoints() {
        var profile: [ElevationProfilePoint] = []
        for i in 0..<10_000 {
            let d = Double(i)
            profile.append(ElevationProfilePoint(distanceFromStart: d, altitude: 1000 + sin(d * 0.01) * 50, slope: 0))
        }
        let decimated = ElevationProfileBuilder.decimate(profile, tolerance: 1.0, maxPoints: 5_000)
        XCTAssertLessThan(decimated.count, profile.count)
        XCTAssertEqual(decimated.first?.distanceFromStart, profile.first?.distanceFromStart)
        XCTAssertEqual(decimated.last?.distanceFromStart, profile.last?.distanceFromStart)
    }

    func testSlopeCategoryRangesPercent() {
        let s = SlopeScale.percent
        XCTAssertEqual(s.category(for: 0), .gentle)
        XCTAssertEqual(s.category(for: 3.9), .gentle)
        XCTAssertEqual(s.category(for: 6), .moderate)
        XCTAssertEqual(s.category(for: 10), .steep)
        XCTAssertEqual(s.category(for: 15), .veryStep)
        XCTAssertEqual(s.category(for: -5), .descent)
    }

    func testBuildMotionWithoutAltitude() {
        // Points sans altitude (ex. voile) : profil mouvement avec distance cumulée, altitude/pente à 0.
        let pts = [
            TrackPoint(latitude: 45.0, longitude: 6.0, altitude: nil, timestamp: Date(timeIntervalSince1970: 0)),
            TrackPoint(latitude: 45.0, longitude: 6.001, altitude: nil, timestamp: Date(timeIntervalSince1970: 10)),
            TrackPoint(latitude: 45.0, longitude: 6.002, altitude: nil, timestamp: Date(timeIntervalSince1970: 20))
        ]
        XCTAssertTrue(ElevationProfileBuilder.build(points: pts).isEmpty) // build classique exige l'altitude
        let motion = ElevationProfileBuilder.buildMotion(points: pts)
        XCTAssertEqual(motion.count, 3)
        XCTAssertEqual(motion[0].distanceFromStart, 0, accuracy: 0.01)
        XCTAssertGreaterThan(motion[2].distanceFromStart, motion[1].distanceFromStart)
        XCTAssertEqual(motion[1].altitude, 0)
        XCTAssertEqual(motion[1].slope, 0)
        XCTAssertNotNil(motion[1].timestamp)
    }

    func testSlopeScaleCategories() {
        XCTAssertEqual(SlopeScale.percent.categories, [.gentle, .moderate, .steep, .veryStep, .descent])
    }

    func testSlopeScaleLabels() {
        XCTAssertEqual(SlopeScale.percent.label(for: .gentle), "0–4 %")
        XCTAssertEqual(SlopeScale.percent.label(for: .moderate), "4–8 %")
        XCTAssertEqual(SlopeScale.percent.label(for: .steep), "8–12 %")
        XCTAssertEqual(SlopeScale.percent.label(for: .veryStep), "> 12 %")
        XCTAssertEqual(SlopeScale.percent.label(for: .descent), "Descente")
    }

    func testSlopeScaleByActivityType() {
        XCTAssertEqual(ActivityType.skiingTouring.slopeScale, .percent)
        XCTAssertEqual(ActivityType.cyclingRoad.slopeScale, .percent)
    }

    // MARK: Détection de pauses

    private func profilePoint(_ lat: Double, slope: Double = 0, sec: Double) -> ElevationProfilePoint {
        ElevationProfilePoint(distanceFromStart: 0, altitude: 0, slope: slope,
                              timestamp: Date(timeIntervalSince1970: sec), latitude: lat, longitude: 6.0)
    }

    func testPausedSegmentFlagsClusterDetection() {
        // Mouvement (~111 m entre points), puis cluster de 380 s dans un rayon de ~2 m, puis repart.
        let profile = [
            profilePoint(45.000, sec: 0),
            profilePoint(45.001, sec: 10),
            profilePoint(45.002, sec: 20),
            profilePoint(45.00201, sec: 200),
            profilePoint(45.00202, sec: 400),
            profilePoint(45.003, sec: 410),
        ]
        let flags = ElevationProfileBuilder.pausedSegmentFlags(profile, pauseMinSeconds: 300, pauseRadiusMeters: 40)
        XCTAssertEqual(flags, [false, false, true, true, false])
    }

    func testPausedSegmentFlagsIgnoresShortStop() {
        // Même cluster mais 120 s < seuil de 300 s → pas une pause.
        let profile = [
            profilePoint(45.000, sec: 0),
            profilePoint(45.001, sec: 10),
            profilePoint(45.00101, sec: 70),
            profilePoint(45.00102, sec: 130),
            profilePoint(45.002, sec: 140),
        ]
        let flags = ElevationProfileBuilder.pausedSegmentFlags(profile, pauseMinSeconds: 300, pauseRadiusMeters: 40)
        XCTAssertEqual(flags, [false, false, false, false])
    }

    func testPausedSegmentFlagsSingleGapAutoPause() {
        // Trou unique d'auto-pause appareil : 690 s pour ~100 m (> rayon, mais vitesse quasi nulle).
        let profile = [
            profilePoint(45.000, sec: 0),
            profilePoint(45.001, sec: 10),
            profilePoint(45.0019, sec: 700),
            profilePoint(45.0029, sec: 710),
        ]
        let flags = ElevationProfileBuilder.pausedSegmentFlags(profile, pauseMinSeconds: 300, pauseRadiusMeters: 40)
        XCTAssertEqual(flags, [false, true, false])
    }

    func testPausedSegmentFlagsLongGapWhileTravelingIsNotPause() {
        // Enregistrement coupé pendant un déplacement (~6,7 km en 600 s ≈ 11 m/s) → pas une pause.
        let profile = [
            profilePoint(45.000, sec: 0),
            profilePoint(45.001, sec: 10),
            profilePoint(45.061, sec: 610),
            profilePoint(45.062, sec: 620),
        ]
        let flags = ElevationProfileBuilder.pausedSegmentFlags(profile, pauseMinSeconds: 300, pauseRadiusMeters: 40)
        XCTAssertEqual(flags, [false, false, false])
    }

    func testPausedTimeRangesCoverContiguousFlags() {
        // Cluster de pause entre t=20 et t=400 → une seule plage continue [20, 400].
        let profile = [
            profilePoint(45.000, sec: 0),
            profilePoint(45.001, sec: 10),
            profilePoint(45.002, sec: 20),
            profilePoint(45.00201, sec: 200),
            profilePoint(45.00202, sec: 400),
            profilePoint(45.003, sec: 410),
        ]
        let ranges = ElevationProfileBuilder.pausedTimeRanges(profile, pauseMinSeconds: 300, pauseRadiusMeters: 40)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].lowerBound, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(ranges[0].upperBound, Date(timeIntervalSince1970: 400))
    }

    func testPausedTimeRangesEmptyWithoutPause() {
        let profile = [
            profilePoint(45.000, sec: 0),
            profilePoint(45.001, sec: 10),
            profilePoint(45.002, sec: 20),
        ]
        XCTAssertTrue(ElevationProfileBuilder.pausedTimeRanges(profile, pauseMinSeconds: 300, pauseRadiusMeters: 40).isEmpty)
    }

    func testSlopeTimesAndPausePartitioning() {
        // La pente du segment en pause (10 %) ne doit PAS compter dans les catégories.
        let profile = [
            profilePoint(45.000, slope: 2, sec: 0),    // seg0 : 10 s douce
            profilePoint(45.001, slope: 10, sec: 10),  // seg1 : 10 s raide
            profilePoint(45.002, slope: -5, sec: 20),  // seg2 : 10 s descente
            profilePoint(45.003, slope: 10, sec: 30),  // seg3 : pause 360 s (cluster ~3 m)
            profilePoint(45.00303, slope: 0, sec: 390),
        ]
        let (byCat, paused) = ElevationProfileBuilder.slopeTimesAndPause(profile, pauseMinSeconds: 300, pauseRadiusMeters: 40)
        XCTAssertEqual(byCat[.gentle] ?? 0, 10)
        XCTAssertEqual(byCat[.steep] ?? 0, 10)
        XCTAssertEqual(byCat[.descent] ?? 0, 10)
        XCTAssertEqual(paused, 360)
        XCTAssertEqual(byCat.values.reduce(0, +) + paused, 390) // = temps total écoulé
    }
}
