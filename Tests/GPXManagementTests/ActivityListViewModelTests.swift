import XCTest
import GPXCore
@testable import GPXManagement

@MainActor
final class ActivityListViewModelTests: XCTestCase {
    private var persistence: PersistenceController!
    private var repository: CoreDataActivityRepository!
    private var vm: ActivityListViewModel!

    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true)
        repository = CoreDataActivityRepository(persistence: persistence)
        vm = ActivityListViewModel(repository: repository)
    }

    private func seed(_ payloads: [ActivityCreationPayload]) async throws {
        for p in payloads { try await repository.createActivity(p) }
        await vm.reload()
    }

    private func payload(type: ActivityType, year: Int, distance: Double = 10_000, title: String = "Ride") -> ActivityCreationPayload {
        var c = DateComponents(); c.year = year; c.month = 6; c.day = 1
        let date = Calendar.current.date(from: c)!
        let stats = ActivityStats(
            distance: distance, duration: 3600, movingDuration: 3600,
            elevationGain: 500, elevationLoss: 480,
            avgSpeed: 10, maxSpeed: 15,
            avgHeartRate: nil, maxHeartRate: nil,
            boundingBox: .zero
        )
        return ActivityCreationPayload(
            id: UUID(), title: title, activityType: type, origin: .manualImport,
            sourceFileName: "f.gpx", sourceFileFormat: .gpx,
            startDate: date, endDate: date.addingTimeInterval(3600),
            stats: stats, trackData: Data(), fileSHA256: "x"
        )
    }

    func testReloadFetchesAll() async throws {
        try await seed([
            payload(type: .cyclingRoad, year: 2025),
            payload(type: .hiking, year: 2024)
        ])
        XCTAssertEqual(vm.allActivities.count, 2)
    }

    func testFilterByActivityType() async throws {
        try await seed([
            payload(type: .cyclingRoad, year: 2025),
            payload(type: .hiking, year: 2025)
        ])
        vm.filters.activityTypes = [.hiking]
        XCTAssertEqual(vm.visibleActivities.count, 1)
        XCTAssertEqual(vm.visibleActivities.first?.activityType, .hiking)
    }

    func testSearchByTitle() async throws {
        try await seed([
            payload(type: .cyclingRoad, year: 2025, title: "Col d'Èze"),
            payload(type: .cyclingRoad, year: 2025, title: "Tour du lac")
        ])
        vm.searchText = "eze"
        XCTAssertEqual(vm.visibleActivities.count, 1)
        XCTAssertEqual(vm.visibleActivities.first?.title, "Col d'Èze")
    }

    func testSortByDistance() async throws {
        try await seed([
            payload(type: .cyclingRoad, year: 2025, distance: 5_000, title: "A"),
            payload(type: .cyclingRoad, year: 2025, distance: 20_000, title: "B"),
            payload(type: .cyclingRoad, year: 2025, distance: 10_000, title: "C")
        ])
        vm.sortOrder = .distance
        XCTAssertEqual(vm.visibleActivities.map(\.title), ["B", "C", "A"])
    }

    func testAvailableActivityTypes() async throws {
        try await seed([
            payload(type: .cyclingRoad, year: 2025),
            payload(type: .cyclingRoad, year: 2024),
            payload(type: .hiking, year: 2024)
        ])
        let entries = vm.availableActivityTypes
        XCTAssertEqual(entries.first(where: { $0.type == .cyclingRoad })?.count, 2)
        XCTAssertEqual(entries.first(where: { $0.type == .hiking })?.count, 1)
    }

    func testAvailableYears() async throws {
        try await seed([
            payload(type: .cyclingRoad, year: 2025),
            payload(type: .cyclingRoad, year: 2024),
            payload(type: .cyclingRoad, year: 2024)
        ])
        XCTAssertEqual(vm.availableYears.map(\.year), [2025, 2024])
        XCTAssertEqual(vm.availableYears.first(where: { $0.year == 2024 })?.count, 2)
    }

    func testDeleteRemovesActivity() async throws {
        try await seed([payload(type: .cyclingRoad, year: 2025)])
        let id = vm.allActivities[0].id
        await vm.delete(id: id)
        XCTAssertEqual(vm.allActivities.count, 0)
    }

    func testUpdateNotesPersists() async throws {
        try await seed([payload(type: .cyclingRoad, year: 2025)])
        let id = vm.allActivities[0].id
        await vm.updateNotes(id: id, notes: "Belle sortie")
        XCTAssertEqual(vm.allActivities[0].notes, "Belle sortie")
    }

    func testUpdateTypePersists() async throws {
        try await seed([payload(type: .cyclingRoad, year: 2025)])
        let id = vm.allActivities[0].id
        await vm.updateType(id: id, type: .hiking)
        XCTAssertEqual(vm.allActivities[0].activityType, .hiking)

        await vm.reload()
        XCTAssertEqual(vm.allActivities[0].activityType, .hiking)
    }
}
