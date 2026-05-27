import Foundation
import Compression

public enum TrackPointCodecError: Error, Equatable {
    case dataTooShort
    case badMagic
    case unsupportedVersion(UInt8)
    case compressionFailed
    case decompressionFailed
}

public enum TrackPointCodec {
    private static let magic: [UInt8] = [0x47, 0x50, 0x58, 0x50]
    private static let version: UInt8 = 1

    private struct Flags: OptionSet {
        let rawValue: UInt8
        static let hasAltitude  = Flags(rawValue: 1 << 0)
        static let hasTime      = Flags(rawValue: 1 << 1)
        static let hasHeartRate = Flags(rawValue: 1 << 2)
        static let hasCadence   = Flags(rawValue: 1 << 3)
        static let hasPower     = Flags(rawValue: 1 << 4)
    }

    public static func encode(_ points: [TrackPoint]) throws -> Data {
        var flags: Flags = []
        for p in points {
            if p.altitude  != nil { flags.insert(.hasAltitude) }
            if p.timestamp != nil { flags.insert(.hasTime) }
            if p.heartRate != nil { flags.insert(.hasHeartRate) }
            if p.cadence   != nil { flags.insert(.hasCadence) }
            if p.power     != nil { flags.insert(.hasPower) }
        }

        let perPointDoubles = 2
            + (flags.contains(.hasAltitude)  ? 1 : 0)
            + (flags.contains(.hasTime)      ? 1 : 0)
            + (flags.contains(.hasHeartRate) ? 1 : 0)
            + (flags.contains(.hasCadence)   ? 1 : 0)
            + (flags.contains(.hasPower)     ? 1 : 0)

        let headerSize = 4 + 1 + 1 + 4
        let bodySize = points.count * perPointDoubles * MemoryLayout<Double>.size
        var raw = Data(capacity: headerSize + bodySize)

        raw.append(contentsOf: magic)
        raw.append(version)
        raw.append(flags.rawValue)
        var count = UInt32(points.count).littleEndian
        withUnsafeBytes(of: &count) { raw.append(contentsOf: $0) }

        func appendDouble(_ v: Double) {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { raw.append(contentsOf: $0) }
        }

        for p in points {
            appendDouble(p.latitude)
            appendDouble(p.longitude)
            if flags.contains(.hasAltitude)  { appendDouble(p.altitude  ?? .nan) }
            if flags.contains(.hasTime)      { appendDouble(p.timestamp.map { $0.timeIntervalSince1970 } ?? .nan) }
            if flags.contains(.hasHeartRate) { appendDouble(p.heartRate ?? .nan) }
            if flags.contains(.hasCadence)   { appendDouble(p.cadence   ?? .nan) }
            if flags.contains(.hasPower)     { appendDouble(p.power     ?? .nan) }
        }

        return try compress(raw)
    }

    public static func decode(_ data: Data) throws -> [TrackPoint] {
        let raw = try decompress(data)
        guard raw.count >= 10 else { throw TrackPointCodecError.dataTooShort }

        let readMagic = Array(raw[0..<4])
        guard readMagic == magic else { throw TrackPointCodecError.badMagic }

        let v = raw[4]
        guard v == version else { throw TrackPointCodecError.unsupportedVersion(v) }

        let flags = Flags(rawValue: raw[5])
        let count = raw.withUnsafeBytes { buf -> UInt32 in
            buf.loadUnaligned(fromByteOffset: 6, as: UInt32.self).littleEndian
        }

        let perPointDoubles = 2
            + (flags.contains(.hasAltitude)  ? 1 : 0)
            + (flags.contains(.hasTime)      ? 1 : 0)
            + (flags.contains(.hasHeartRate) ? 1 : 0)
            + (flags.contains(.hasCadence)   ? 1 : 0)
            + (flags.contains(.hasPower)     ? 1 : 0)

        let bodyStart = 10
        let expectedBody = Int(count) * perPointDoubles * MemoryLayout<Double>.size
        guard raw.count >= bodyStart + expectedBody else { throw TrackPointCodecError.dataTooShort }

        var points = [TrackPoint]()
        points.reserveCapacity(Int(count))

        var offset = bodyStart
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            func readDouble() -> Double {
                let bits = buf.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
                offset += 8
                return Double(bitPattern: bits)
            }

            for _ in 0..<Int(count) {
                let lat = readDouble()
                let lon = readDouble()
                let alt = flags.contains(.hasAltitude)  ? unwrapNaN(readDouble()) : nil
                let t   = flags.contains(.hasTime)      ? unwrapNaN(readDouble()).map { Date(timeIntervalSince1970: $0) } : nil
                let hr  = flags.contains(.hasHeartRate) ? unwrapNaN(readDouble()) : nil
                let cad = flags.contains(.hasCadence)   ? unwrapNaN(readDouble()) : nil
                let pwr = flags.contains(.hasPower)     ? unwrapNaN(readDouble()) : nil
                points.append(TrackPoint(latitude: lat, longitude: lon, altitude: alt, timestamp: t, heartRate: hr, cadence: cad, power: pwr))
            }
            _ = offset
        }

        return points
    }

    private static func unwrapNaN(_ v: Double) -> Double? {
        v.isNaN ? nil : v
    }

    private static func compress(_ data: Data) throws -> Data {
        do {
            let compressed = try (data as NSData).compressed(using: .zlib)
            return compressed as Data
        } catch {
            throw TrackPointCodecError.compressionFailed
        }
    }

    private static func decompress(_ data: Data) throws -> Data {
        do {
            let raw = try (data as NSData).decompressed(using: .zlib)
            return raw as Data
        } catch {
            throw TrackPointCodecError.decompressionFailed
        }
    }
}
