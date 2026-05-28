import Foundation
import Compression

public enum ArchiveError: Error, Equatable {
    case notAZipFile
    case corrupted(String)
    case unsupportedCompression(UInt16)
    case inflateFailed
}

/// Lecteur ZIP minimal, sans dépendance, compatible sandbox (pas de `Process`).
/// Parse le central directory et inflate chaque entrée via le framework Compression.
/// Ne supporte que les méthodes 0 (stored) et 8 (deflate) — suffisant pour les archives Strava.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable {
        public let path: String
        public let compressionMethod: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public func extract(_ entry: Entry) throws -> Data {
        let dataStart = try localDataOffset(for: entry)
        guard dataStart + entry.compressedSize <= data.count else {
            throw ArchiveError.corrupted("entrée tronquée: \(entry.path)")
        }
        let payload = data.subdata(in: dataStart..<(dataStart + entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try Self.inflateRawDeflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    /// L'offset des données dans le local header peut différer du central directory
    /// (le champ "extra" a souvent une longueur distincte), il faut donc relire le local header.
    private func localDataOffset(for entry: Entry) throws -> Int {
        let base = entry.localHeaderOffset
        guard base + 30 <= data.count, Self.readU32(data, base) == 0x04034b50 else {
            throw ArchiveError.corrupted("local header invalide: \(entry.path)")
        }
        let nameLen = Int(Self.readU16(data, base + 26))
        let extraLen = Int(Self.readU16(data, base + 28))
        return base + 30 + nameLen + extraLen
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ArchiveError.notAZipFile }

        guard let eocd = locateEOCD(data) else { throw ArchiveError.notAZipFile }
        let entryCount = Int(readU16(data, eocd + 10))
        var offset = Int(readU32(data, eocd + 16))

        var result: [Entry] = []
        result.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, readU32(data, offset) == 0x02014b50 else {
                throw ArchiveError.corrupted("central directory header invalide")
            }
            let method = readU16(data, offset + 10)
            let compressedSize = Int(readU32(data, offset + 20))
            let uncompressedSize = Int(readU32(data, offset + 24))
            let nameLen = Int(readU16(data, offset + 28))
            let extraLen = Int(readU16(data, offset + 30))
            let commentLen = Int(readU16(data, offset + 32))
            let localOffset = Int(readU32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count else {
                throw ArchiveError.corrupted("nom d'entrée tronqué")
            }
            let name = String(decoding: data.subdata(in: nameStart..<(nameStart + nameLen)), as: UTF8.self)

            result.append(Entry(
                path: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    private static func locateEOCD(_ data: Data) -> Int? {
        let sig: UInt32 = 0x06054b50
        let minOffset = max(0, data.count - 22 - 0xFFFF)
        var i = data.count - 22
        while i >= minOffset {
            if readU32(data, i) == sig { return i }
            i -= 1
        }
        return nil
    }

    static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        // Apple `.zlib` = DEFLATE brut (sans en-tête/trailer zlib), exactement ce que stocke un ZIP (méthode 8).
        let capacity = expectedSize > 0 ? expectedSize : max(data.count * 4, 1024)
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw ArchiveError.inflateFailed }
        dst.removeSubrange(written..<dst.count)
        return dst
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

public enum Gzip {
    /// Décompresse un flux gzip (RFC 1952) : on saute l'en-tête variable et le trailer de 8 octets,
    /// puis on inflate le DEFLATE brut via le framework Compression.
    public static func decompress(_ data: Data) throws -> Data {
        guard data.count > 18 else { throw ArchiveError.corrupted("gzip trop court") }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else {
            throw ArchiveError.corrupted("signature gzip invalide")
        }
        guard bytes[2] == 8 else { throw ArchiveError.unsupportedCompression(UInt16(bytes[2])) }

        let flags = bytes[3]
        var index = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { throw ArchiveError.corrupted("FEXTRA tronqué") }
            let xlen = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2 + xlen
        }
        if flags & 0x08 != 0 { index = try skipCString(bytes, from: index) } // FNAME
        if flags & 0x10 != 0 { index = try skipCString(bytes, from: index) } // FCOMMENT
        if flags & 0x02 != 0 { index += 2 } // FHCRC

        guard index < bytes.count - 8 else { throw ArchiveError.corrupted("payload gzip vide") }

        let isize = UInt32(bytes[bytes.count - 4])
            | (UInt32(bytes[bytes.count - 3]) << 8)
            | (UInt32(bytes[bytes.count - 2]) << 16)
            | (UInt32(bytes[bytes.count - 1]) << 24)

        let deflate = data.subdata(in: (data.startIndex + index)..<(data.endIndex - 8))
        return try ZipArchive.inflateRawDeflate(deflate, expectedSize: Int(isize))
    }

    private static func skipCString(_ bytes: [UInt8], from start: Int) throws -> Int {
        var i = start
        while i < bytes.count {
            if bytes[i] == 0 { return i + 1 }
            i += 1
        }
        throw ArchiveError.corrupted("chaîne gzip non terminée")
    }
}
