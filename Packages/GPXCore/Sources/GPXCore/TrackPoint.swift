import Foundation

public struct TrackPoint: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let timestamp: Date?
    public let heartRate: Double?
    public let cadence: Double?
    public let power: Double?

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        timestamp: Date? = nil,
        heartRate: Double? = nil,
        cadence: Double? = nil,
        power: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.cadence = cadence
        self.power = power
    }
}
