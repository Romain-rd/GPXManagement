import SwiftUI
import GPXCore

public extension SlopeCategory {
    public var color: Color {
        switch self {
        case .gentle:   return .green
        case .moderate: return .yellow
        case .steep:    return .orange
        case .veryStep: return .red
        case .descent:  return .blue
        }
    }
}
