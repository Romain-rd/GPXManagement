import Foundation

/// Un échantillon de capteurs horodaté, sans position. Sert aux séances enregistrées sans GPS
/// (ex. Apple Watch « sur place ») dont on veut quand même tracer la fréquence cardiaque, etc.
public struct SensorSample: Sendable, Equatable {
    public let time: Date
    public let heartRate: Double?
    public let altitude: Double?
    public let cadence: Double?
    public let power: Double?

    public init(time: Date, heartRate: Double? = nil, altitude: Double? = nil, cadence: Double? = nil, power: Double? = nil) {
        self.time = time
        self.heartRate = heartRate
        self.altitude = altitude
        self.cadence = cadence
        self.power = power
    }

    public var hasData: Bool { heartRate != nil || altitude != nil || cadence != nil || power != nil }
}

/// Série de capteurs stockée (attribut Core Data `sensorData`). Canaux alignés sur `t` ; un canal
/// entièrement absent n'est pas encodé. Valeur manquante d'un échantillon = `null` dans le canal.
public struct SensorSeries: Codable, Sendable, Equatable {
    public var t: [Double]            // timeIntervalSince1970
    public var hr: [Double?]?
    public var alt: [Double?]?
    public var cad: [Double?]?
    public var pw: [Double?]?

    public init(t: [Double], hr: [Double?]? = nil, alt: [Double?]? = nil, cad: [Double?]? = nil, pw: [Double?]? = nil) {
        self.t = t; self.hr = hr; self.alt = alt; self.cad = cad; self.pw = pw
    }

    public init(samples: [SensorSample]) {
        t = samples.map { $0.time.timeIntervalSince1970 }
        hr  = samples.contains { $0.heartRate != nil } ? samples.map(\.heartRate) : nil
        alt = samples.contains { $0.altitude != nil }  ? samples.map(\.altitude)  : nil
        cad = samples.contains { $0.cadence != nil }   ? samples.map(\.cadence)   : nil
        pw  = samples.contains { $0.power != nil }      ? samples.map(\.power)     : nil
    }

    public var isEmpty: Bool { t.isEmpty }
    public var hasHeartRate: Bool { (hr?.contains { $0 != nil }) ?? false }

    /// Points (date, valeur) non nuls d'un canal, pour le tracé.
    public func channel(_ values: [Double?]?) -> [(date: Date, value: Double)] {
        guard let values else { return [] }
        var out: [(Date, Double)] = []
        out.reserveCapacity(t.count)
        for (i, v) in values.enumerated() where v != nil && i < t.count {
            out.append((Date(timeIntervalSince1970: t[i]), v!))
        }
        return out
    }

    public var heartRatePoints: [(date: Date, value: Double)] { channel(hr) }
    public var altitudePoints: [(date: Date, value: Double)] { channel(alt) }

    private func stats(_ values: [Double?]?) -> (avg: Double, max: Double)? {
        let vals = (values ?? []).compactMap { $0 }
        guard !vals.isEmpty else { return nil }
        return (vals.reduce(0, +) / Double(vals.count), vals.max() ?? 0)
    }
    public var heartRateStats: (avg: Double, max: Double)? { stats(hr) }
}

public enum SensorSeriesCodec {
    public static func encode(_ series: SensorSeries) -> Data? {
        guard !series.isEmpty else { return nil }
        return try? JSONEncoder().encode(series)
    }
    public static func decode(_ data: Data?) -> SensorSeries? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(SensorSeries.self, from: data)
    }
}
