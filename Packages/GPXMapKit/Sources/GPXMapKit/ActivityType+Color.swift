import Foundation
import AppKit
import GPXCore

public extension ActivityType {
    var trackColor: NSColor {
        switch self {
        case .cyclingRoad, .virtualRide:       return NSColor(hex: 0x1E88E5)
        case .cyclingMTB, .cyclingGravel:      return NSColor(hex: 0x43A047)
        case .eBike, .eMountainBike:           return NSColor(hex: 0x00897B)
        case .velomobile, .handcycle:          return NSColor(hex: 0x1565C0)
        case .motorcycle:                      return NSColor(hex: 0xE53935)
        case .walking:                         return NSColor(hex: 0xFB8C00)
        case .hiking:                          return NSColor(hex: 0x6D4C41)
        case .running, .trailRunning, .virtualRun: return NSColor(hex: 0xEF6C00)
        case .mountaineering:                  return NSColor(hex: 0x546E7A)
        case .skiingAlpine:                    return NSColor(hex: 0x00ACC1)
        case .skiingNordic:                    return NSColor(hex: 0x5E35B1)
        case .skiingTouring:                   return NSColor(hex: 0x3949AB)
        case .skiingFreeride:                  return NSColor(hex: 0x8E24AA)
        case .rollerSki:                       return NSColor(hex: 0x7E57C2)
        case .snowboard:                       return NSColor(hex: 0x5C6BC0)
        case .snowshoe:                        return NSColor(hex: 0x90A4AE)
        case .iceSkate, .inlineSkate, .skateboard: return NSColor(hex: 0xAB47BC)
        case .swimming:                        return NSColor(hex: 0x26C6DA)
        case .rowing, .virtualRow:             return NSColor(hex: 0x9CCC65)
        case .canoeing, .kayaking, .standUpPaddling: return NSColor(hex: 0x00ACC1)
        case .surfing, .kitesurf, .windsurf:   return NSColor(hex: 0x26A69A)
        case .sailing:                         return NSColor(hex: 0x0277BD)
        case .climbing:                        return NSColor(hex: 0xF4511E)
        case .strengthTraining, .crossfit, .hiit, .elliptical, .stairStepper,
             .pilates, .yoga, .workout:        return NSColor(hex: 0x8D6E63)
        case .golf:                            return NSColor(hex: 0x7CB342)
        case .wheelchair:                      return NSColor(hex: 0x5E35B1)
        case .badminton, .tennis, .tableTennis, .pickleball, .racquetball, .squash, .soccer:
            return NSColor(hex: 0xD81B60)
        case .other:                           return NSColor(hex: 0x9E9E9E)
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
