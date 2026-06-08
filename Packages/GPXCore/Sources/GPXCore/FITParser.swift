import Foundation

public enum FITParseError: Error, Equatable {
    case headerTooShort
    case invalidSignature
    case truncated
    case undefinedLocalMessageType(UInt8)
    case unsupportedBaseType(UInt8)
}

public struct FITParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> ParsedTrack {
        var decoder = FITDecoder(data: data)
        try decoder.readHeader()

        var points: [TrackPoint] = []
        let trackName: String? = nil // FIT n'a pas de nom de séance ; le titre est dérivé du fichier à l'import
        var activityHint: String?
        var manufacturerId: UInt32?
        var productName: String?
        var definitions: [UInt8: FITDefinition] = [:]
        var pendingSport: UInt8?
        var pendingSubSport: UInt8?
        var sessionStart: Date?
        var sessionDuration: Double?
        var sessionDistance: Double?
        var sessionAvgSpeed: Double?
        var sessionMaxSpeed: Double?
        var sessionAvgHR: Double?
        var sessionMaxHR: Double?
        var sessionAscent: Double?
        var sessionDescent: Double?

        while decoder.hasMoreRecords {
            let header = try decoder.readUInt8()

            if header & 0x80 != 0 {
                let localType = (header >> 5) & 0x03
                let timeOffset = header & 0x1F
                guard let def = definitions[localType] else { throw FITParseError.undefinedLocalMessageType(localType) }
                let fields = try decoder.readDataFields(def)
                if def.globalMessageNumber == 20 {
                    if let point = Self.buildTrackPoint(from: fields, def: def, compressedTimeOffset: timeOffset, previousTimestamp: decoder.lastTimestamp) {
                        points.append(point)
                        if let ts = point.timestamp { decoder.lastTimestamp = ts }
                    }
                }
            } else if header & 0x40 != 0 {
                let localType = header & 0x0F
                let hasDeveloperData = (header & 0x20) != 0
                let def = try decoder.readDefinition(hasDeveloperData: hasDeveloperData)
                definitions[localType] = def
            } else {
                let localType = header & 0x0F
                guard let def = definitions[localType] else { throw FITParseError.undefinedLocalMessageType(localType) }
                let fields = try decoder.readDataFields(def)

                switch def.globalMessageNumber {
                case 20:
                    if let point = Self.buildTrackPoint(from: fields, def: def, compressedTimeOffset: nil, previousTimestamp: decoder.lastTimestamp) {
                        points.append(point)
                        if let ts = point.timestamp { decoder.lastTimestamp = ts }
                    }
                case 18, 12:
                    if let sport = fields[5]?.uint8Value { pendingSport = sport }
                    if let sub = fields[6]?.uint8Value { pendingSubSport = sub }
                    if def.globalMessageNumber == 18 {
                        if let st = fields[2]?.uint32Value { sessionStart = Self.fitEpoch.addingTimeInterval(TimeInterval(st)) }
                        if let el = fields[7]?.doubleValue { sessionDuration = el / 1000.0 }
                        if let di = fields[9]?.doubleValue { sessionDistance = di / 100.0 }
                        if let v = fields[14]?.doubleValue { sessionAvgSpeed = v / 1000.0 } // avg_speed (mm/s → m/s)
                        if let v = fields[15]?.doubleValue { sessionMaxSpeed = v / 1000.0 } // max_speed
                        if let v = fields[16]?.doubleValue { sessionAvgHR = v }             // avg_heart_rate (bpm)
                        if let v = fields[17]?.doubleValue { sessionMaxHR = v }             // max_heart_rate
                        if let v = fields[22]?.doubleValue { sessionAscent = v }            // total_ascent (m)
                        if let v = fields[23]?.doubleValue { sessionDescent = v }           // total_descent (m)
                    }
                case 34:
                    if let sport = fields[4]?.uint8Value, pendingSport == nil { pendingSport = sport }
                case 0:
                    if let manufacturer = fields[1]?.uint32Value { manufacturerId = manufacturer }
                    // product_name = appli/appareil (ex. « Watch6,18 », « Redpoint… ») : sert au creator/source,
                    // mais ne doit PAS servir de titre d'activité (le titre retombe sur le nom de fichier).
                    if let nameField = fields[8]?.stringValue { productName = nameField }
                default:
                    break
                }
            }
        }

        if let sport = pendingSport {
            activityHint = Self.sportName(sport: sport, subSport: pendingSubSport)
        }

        let creator = manufacturerId.flatMap(Self.manufacturerName) ?? productName

        let timestamps = points.compactMap(\.timestamp)
        let summary: ParsedTrack.Summary?
        if sessionStart != nil || sessionDuration != nil || sessionDistance != nil {
            summary = ParsedTrack.Summary(
                startDate: sessionStart, duration: sessionDuration, distance: sessionDistance,
                avgSpeed: sessionAvgSpeed, maxSpeed: sessionMaxSpeed,
                avgHeartRate: sessionAvgHR, maxHeartRate: sessionMaxHR,
                elevationGain: sessionAscent, elevationLoss: sessionDescent
            )
        } else {
            summary = nil
        }
        return ParsedTrack(
            name: trackName,
            activityHint: activityHint,
            startDate: timestamps.first,
            endDate: timestamps.last,
            points: points,
            summary: summary,
            creator: creator
        )
    }

    /// Sous-ensemble des identifiants de fabricant FIT les plus courants. Les autres retombent sur
    /// le `product_name` du message file_id.
    private static func manufacturerName(_ id: UInt32) -> String? {
        switch id {
        case 1, 15:  return "Garmin"
        case 23:     return "Suunto"
        case 32:     return "Wahoo"
        case 70:     return "Sigma"
        case 89:     return "TomTom"
        case 95:     return "Stryd"
        case 260:    return "Zwift"
        case 267:    return "Bryton"
        case 282:    return "Hammerhead"
        default:     return nil
        }
    }

    public func parse(url: URL) throws -> ParsedTrack {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    private static let fitEpoch = Date(timeIntervalSince1970: 631_065_600)

    private static func buildTrackPoint(from fields: [UInt8: FITValue], def: FITDefinition, compressedTimeOffset: UInt8?, previousTimestamp: Date?) -> TrackPoint? {
        let lat = fields[0]?.semicircleValue
        let lon = fields[1]?.semicircleValue
        guard let lat, let lon else { return nil }

        // Altitude : champ 2 (altitude) ou, à défaut, champ 78 (enhanced_altitude, utilisé par beaucoup
        // d'appareils récents — Apple Watch / Redpoint…). Même échelle (×5, offset 500 m).
        let altitude: Double?
        if let raw = fields[2]?.doubleValue ?? fields[78]?.doubleValue {
            altitude = (raw / 5.0) - 500.0
        } else {
            altitude = nil
        }

        let timestamp: Date?
        if let raw = fields[253]?.uint32Value {
            timestamp = fitEpoch.addingTimeInterval(TimeInterval(raw))
        } else if let offset = compressedTimeOffset, let prev = previousTimestamp {
            let prevSec = UInt32(prev.timeIntervalSince(fitEpoch))
            let prevOffset = UInt8(prevSec & 0x1F)
            var delta = Int(offset) - Int(prevOffset)
            if delta < 0 { delta += 32 }
            timestamp = prev.addingTimeInterval(TimeInterval(delta))
        } else {
            timestamp = nil
        }

        let hr = fields[3]?.doubleValue
        let cadence = fields[4]?.doubleValue
        let power = fields[7]?.doubleValue

        return TrackPoint(
            latitude: lat,
            longitude: lon,
            altitude: altitude,
            timestamp: timestamp,
            heartRate: hr,
            cadence: cadence,
            power: power
        )
    }

    private static func sportName(sport: UInt8, subSport: UInt8?) -> String {
        let main: String
        switch sport {
        case 1: main = "running"
        case 2: main = "cycling"
        case 4: main = "fitness_equipment"
        case 5: main = "swimming"
        case 10: main = "training"
        case 11: main = "walking"
        case 12: main = "cross_country_skiing"
        case 13: main = "alpine_skiing"
        case 15: main = "rowing"
        case 16: main = "mountaineering"
        case 17: main = "hiking"
        case 22: main = "motorcycling"
        case 31: main = "rock_climbing"
        case 38: main = "surfing"
        case 48: main = "floor_climbing"
        default: main = "sport_\(sport)"
        }
        if sport == 2, let sub = subSport {
            switch sub {
            case 5: return "cycling"
            case 6: return "mountain_biking"
            case 30: return "gravel_cycling"
            default: return main
            }
        }
        if sport == 13, let sub = subSport, sub == 41 {
            return "backcountry_skiing"
        }
        return main
    }
}

struct FITFieldDefinition: Sendable {
    let fieldNumber: UInt8
    let size: UInt8
    let baseType: UInt8
}

struct FITDefinition: Sendable {
    let globalMessageNumber: UInt16
    let bigEndian: Bool
    let fields: [FITFieldDefinition]
    let developerFields: [FITFieldDefinition]

    var totalDataSize: Int {
        fields.reduce(0) { $0 + Int($1.size) } + developerFields.reduce(0) { $0 + Int($1.size) }
    }
}

enum FITValue: Sendable {
    case integer(Int64)
    case unsigned(UInt64)
    case real(Double)
    case string(String)
    case raw(Data)

    var uint8Value: UInt8? {
        if case let .unsigned(v) = self, v <= UInt8.max { return UInt8(v) }
        return nil
    }
    var uint32Value: UInt32? {
        if case let .unsigned(v) = self, v <= UInt32.max { return UInt32(v) }
        return nil
    }
    var doubleValue: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .unsigned(let v): return Double(v)
        case .real(let v): return v
        default: return nil
        }
    }
    var semicircleValue: Double? {
        guard let v = self.integerOptional else { return nil }
        return Double(v) * (180.0 / 2147483648.0)
    }
    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }
    private var integerOptional: Int64? {
        switch self {
        case .integer(let v): return v
        case .unsigned(let v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        default: return nil
        }
    }
}

struct FITDecoder {
    let data: Data
    var offset: Int = 0
    var dataEndOffset: Int = 0
    var lastTimestamp: Date?

    init(data: Data) { self.data = data }

    var hasMoreRecords: Bool { offset < dataEndOffset }

    mutating func readHeader() throws {
        guard data.count >= 12 else { throw FITParseError.headerTooShort }
        let headerSize = Int(data[0])
        guard headerSize == 12 || headerSize == 14 else { throw FITParseError.invalidSignature }
        let sigBytes = Array(data[8..<12])
        guard sigBytes == [0x2E, 0x46, 0x49, 0x54] else { throw FITParseError.invalidSignature }
        let dataSize = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        offset = headerSize
        dataEndOffset = headerSize + Int(dataSize)
        guard dataEndOffset <= data.count else { throw FITParseError.truncated }
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < dataEndOffset else { throw FITParseError.truncated }
        let v = data[offset]
        offset += 1
        return v
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= dataEndOffset else { throw FITParseError.truncated }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func readDefinition(hasDeveloperData: Bool) throws -> FITDefinition {
        _ = try readUInt8()
        let architecture = try readUInt8()
        let bigEndian = architecture == 1
        let gnumLo = try readUInt8()
        let gnumHi = try readUInt8()
        let globalMessageNumber = bigEndian
            ? (UInt16(gnumLo) << 8) | UInt16(gnumHi)
            : UInt16(gnumLo) | (UInt16(gnumHi) << 8)
        let fieldCount = try readUInt8()
        var fields: [FITFieldDefinition] = []
        fields.reserveCapacity(Int(fieldCount))
        for _ in 0..<fieldCount {
            let num = try readUInt8()
            let size = try readUInt8()
            let baseType = try readUInt8()
            fields.append(FITFieldDefinition(fieldNumber: num, size: size, baseType: baseType))
        }

        var devFields: [FITFieldDefinition] = []
        if hasDeveloperData {
            let devCount = try readUInt8()
            for _ in 0..<devCount {
                let num = try readUInt8()
                let size = try readUInt8()
                let devIdx = try readUInt8()
                devFields.append(FITFieldDefinition(fieldNumber: num, size: size, baseType: devIdx))
            }
        }

        return FITDefinition(globalMessageNumber: globalMessageNumber, bigEndian: bigEndian, fields: fields, developerFields: devFields)
    }

    mutating func readDataFields(_ def: FITDefinition) throws -> [UInt8: FITValue] {
        var result: [UInt8: FITValue] = [:]
        for field in def.fields {
            let bytes = try readBytes(Int(field.size))
            if let value = Self.parseValue(bytes: bytes, baseType: field.baseType, bigEndian: def.bigEndian) {
                result[field.fieldNumber] = value
            }
        }
        for field in def.developerFields {
            _ = try readBytes(Int(field.size))
        }
        return result
    }

    private static func parseValue(bytes: Data, baseType: UInt8, bigEndian: Bool) -> FITValue? {
        let type = baseType & 0x1F
        switch type {
        case 0x00:
            guard let b = bytes.first, b != 0xFF else { return nil }
            return .unsigned(UInt64(b))
        case 0x01:
            guard let b = bytes.first, b != 0x7F else { return nil }
            return .integer(Int64(Int8(bitPattern: b)))
        case 0x02, 0x0A:
            guard let b = bytes.first else { return nil }
            let invalid: UInt8 = (type == 0x0A) ? 0x00 : 0xFF
            if b == invalid { return nil }
            return .unsigned(UInt64(b))
        case 0x03:
            guard let v = readInt16(bytes, bigEndian: bigEndian), v != Int16.max else { return nil }
            return .integer(Int64(v))
        case 0x04, 0x0B:
            guard let v = readUInt16(bytes, bigEndian: bigEndian) else { return nil }
            let invalid: UInt16 = (type == 0x0B) ? 0x0000 : 0xFFFF
            if v == invalid { return nil }
            return .unsigned(UInt64(v))
        case 0x05:
            guard let v = readInt32(bytes, bigEndian: bigEndian), v != Int32.max else { return nil }
            return .integer(Int64(v))
        case 0x06, 0x0C:
            guard let v = readUInt32(bytes, bigEndian: bigEndian) else { return nil }
            let invalid: UInt32 = (type == 0x0C) ? 0x00000000 : 0xFFFFFFFF
            if v == invalid { return nil }
            return .unsigned(UInt64(v))
        case 0x07:
            let trimmed = bytes.split(separator: 0).first.map { Data($0) } ?? Data()
            return .string(String(data: trimmed, encoding: .utf8) ?? "")
        case 0x08:
            guard bytes.count >= 4 else { return nil }
            let raw = readUInt32(bytes, bigEndian: bigEndian) ?? 0
            return .real(Double(Float(bitPattern: raw)))
        case 0x09:
            guard bytes.count >= 8 else { return nil }
            let raw = readUInt64(bytes, bigEndian: bigEndian) ?? 0
            return .real(Double(bitPattern: raw))
        case 0x0E:
            guard let v = readUInt64(bytes, bigEndian: bigEndian) else { return nil }
            return .integer(Int64(bitPattern: v))
        case 0x0F, 0x10:
            guard let v = readUInt64(bytes, bigEndian: bigEndian) else { return nil }
            return .unsigned(v)
        default:
            return .raw(bytes)
        }
    }

    private static func readUInt16(_ d: Data, bigEndian: Bool) -> UInt16? {
        guard d.count >= 2 else { return nil }
        let a = UInt16(d[d.startIndex])
        let b = UInt16(d[d.startIndex + 1])
        return bigEndian ? (a << 8) | b : a | (b << 8)
    }
    private static func readInt16(_ d: Data, bigEndian: Bool) -> Int16? {
        guard let u = readUInt16(d, bigEndian: bigEndian) else { return nil }
        return Int16(bitPattern: u)
    }
    private static func readUInt32(_ d: Data, bigEndian: Bool) -> UInt32? {
        guard d.count >= 4 else { return nil }
        let a = UInt32(d[d.startIndex])
        let b = UInt32(d[d.startIndex + 1])
        let c = UInt32(d[d.startIndex + 2])
        let e = UInt32(d[d.startIndex + 3])
        return bigEndian ? (a << 24) | (b << 16) | (c << 8) | e : a | (b << 8) | (c << 16) | (e << 24)
    }
    private static func readInt32(_ d: Data, bigEndian: Bool) -> Int32? {
        guard let u = readUInt32(d, bigEndian: bigEndian) else { return nil }
        return Int32(bitPattern: u)
    }
    private static func readUInt64(_ d: Data, bigEndian: Bool) -> UInt64? {
        guard d.count >= 8 else { return nil }
        var v: UInt64 = 0
        if bigEndian {
            for i in 0..<8 { v = (v << 8) | UInt64(d[d.startIndex + i]) }
        } else {
            for i in 0..<8 { v |= UInt64(d[d.startIndex + i]) << (8 * i) }
        }
        return v
    }
}
