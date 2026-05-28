import Foundation
import AppKit
import GPXCore

public extension ActivityType {
    var trackColor: NSColor {
        switch self {
        case .cyclingRoad:     return NSColor(hex: 0x1E88E5)
        case .cyclingMTB:      return NSColor(hex: 0x43A047)
        case .cyclingGravel:   return NSColor(hex: 0x43A047)
        case .motorcycle:      return NSColor(hex: 0xE53935)
        case .walking:         return NSColor(hex: 0xFB8C00)
        case .hiking:          return NSColor(hex: 0x6D4C41)
        case .skiingAlpine:    return NSColor(hex: 0x00ACC1)
        case .skiingNordic:    return NSColor(hex: 0x5E35B1)
        case .skiingTouring:   return NSColor(hex: 0x3949AB)
        case .skiingFreeride:  return NSColor(hex: 0x8E24AA)
        }
    }
}

/// Palette de 4 couleurs très contrastées pour distinguer des traces superposées.
public enum MapTrackPalette {
    public static let colors: [NSColor] = [
        NSColor(hex: 0x1E88E5), // bleu
        NSColor(hex: 0xE53935), // rouge
        NSColor(hex: 0x43A047), // vert
        NSColor(hex: 0xFB8C00)  // orange
    ]

    public static func color(at index: Int) -> NSColor {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
