import Foundation

public enum GPXWriter {
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func write(name: String, activityType: ActivityType?, points: [TrackPoint]) throws -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"GPXManagement\""
        xml += " xmlns=\"http://www.topografix.com/GPX/1/1\""
        xml += " xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\">\n"
        xml += "  <trk>\n"
        xml += "    <name>\(escape(name))</name>\n"
        if let type = activityType {
            xml += "    <type>\(escape(type.rawValue))</type>\n"
        }
        xml += "    <trkseg>\n"
        for point in points {
            xml += writeTrkpt(point)
        }
        xml += "    </trkseg>\n"
        xml += "  </trk>\n"
        xml += "</gpx>\n"

        guard let data = xml.data(using: .utf8) else {
            throw GPXWriteError.encodingFailed
        }
        return data
    }

    private static func writeTrkpt(_ point: TrackPoint) -> String {
        var s = "      <trkpt lat=\"\(formatCoord(point.latitude))\" lon=\"\(formatCoord(point.longitude))\">"
        var inner = ""
        if let alt = point.altitude {
            inner += "<ele>\(formatNumber(alt))</ele>"
        }
        if let time = point.timestamp {
            inner += "<time>\(iso8601.string(from: time))</time>"
        }
        if point.heartRate != nil || point.cadence != nil || point.power != nil {
            inner += "<extensions><gpxtpx:TrackPointExtension>"
            if let hr = point.heartRate {
                inner += "<gpxtpx:hr>\(Int(hr.rounded()))</gpxtpx:hr>"
            }
            if let cad = point.cadence {
                inner += "<gpxtpx:cad>\(Int(cad.rounded()))</gpxtpx:cad>"
            }
            if let pw = point.power {
                inner += "<gpxtpx:power>\(Int(pw.rounded()))</gpxtpx:power>"
            }
            inner += "</gpxtpx:TrackPointExtension></extensions>"
        }
        if !inner.isEmpty {
            s += inner
        }
        s += "</trkpt>\n"
        return s
    }

    private static func formatCoord(_ v: Double) -> String {
        String(format: "%.7f", v)
    }

    private static func formatNumber(_ v: Double) -> String {
        if v == v.rounded() {
            return String(format: "%.1f", v)
        }
        return String(format: "%.2f", v)
    }

    private static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}

public enum GPXWriteError: Error, Equatable {
    case encodingFailed
}
