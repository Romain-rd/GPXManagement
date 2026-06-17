import SwiftUI
import AVKit
import MapKit
import Photos
import GPXCore
import GPXMapKit
import GPXRender
import GPXVideo

// MARK: - Éditeur de disposition vidéo

struct VideoLayoutEditor: View {
    static let space = "videoEditor"
    let aspect: Double
    @Binding var layout: VideoLayout
    let tracePoints: [CGPoint]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.16))
                ZoneBox(zone: $layout.trace, canvas: geo.size, color: .blue, label: "Trace") {
                    TracePreview(points: tracePoints).padding(5)
                }
                ZoneBox(zone: $layout.media, canvas: geo.size, color: .orange, label: "Photo / Vidéo") {
                    Image(systemName: "photo").foregroundStyle(.orange.opacity(0.7))
                }
                if layout.profile != nil {
                    ZoneBox(zone: Binding(get: { layout.profile ?? LayoutZone(x: 0.6, y: 0.74, w: 0.38, h: 0.22) },
                                          set: { layout.profile = $0 }),
                            canvas: geo.size, color: .teal, label: "Profil") {
                        Image(systemName: "chart.xyaxis.line").foregroundStyle(.teal.opacity(0.7))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
            .coordinateSpace(name: Self.space)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: 480, maxHeight: 360)
    }
}

private struct ZoneBox<Content: View>: View {
    @Binding var zone: LayoutZone
    let canvas: CGSize
    let color: Color
    let label: String
    @ViewBuilder var content: Content
    @State private var startZone: LayoutZone?

    var body: some View {
        let rw = zone.w * canvas.width
        let rh = zone.h * canvas.height
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.14))
            content.frame(width: rw, height: rh).clipped()
            RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: 2)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(color.opacity(0.85)).foregroundStyle(.white).clipShape(Capsule())
                .padding(3)
        }
        .frame(width: rw, height: rh)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(color)
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: "arrow.down.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                .offset(x: 7, y: 7)
                .highPriorityGesture(
                    // Le coin suit la position absolue du curseur (repère du canevas) → pas de rétroaction.
                    DragGesture(coordinateSpace: .named(VideoLayoutEditor.space))
                        .onChanged { v in
                            let nw = Swift.min(Swift.max(0.12, Double(v.location.x) / Double(canvas.width) - zone.x), 1 - zone.x)
                            let nh = Swift.min(Swift.max(0.10, Double(v.location.y) / Double(canvas.height) - zone.y), 1 - zone.y)
                            zone.w = nw; zone.h = nh
                        }
                )
        }
        .offset(x: zone.x * canvas.width, y: zone.y * canvas.height)
        .gesture(
            DragGesture()
                .onChanged { v in
                    let s = startZone ?? zone; if startZone == nil { startZone = s }
                    let nx = Swift.min(Swift.max(0, s.x + Double(v.translation.width) / Double(canvas.width)), 1 - zone.w)
                    let ny = Swift.min(Swift.max(0, s.y + Double(v.translation.height) / Double(canvas.height)), 1 - zone.h)
                    zone.x = nx; zone.y = ny
                }
                .onEnded { _ in startZone = nil }
        )
    }
}

private struct TracePreview: View {
    let points: [CGPoint]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard points.count > 1 else { return }
                let maxX = points.map(\.x).max() ?? 1, maxY = points.map(\.y).max() ?? 1
                let sc = Swift.min(geo.size.width / Swift.max(0.01, maxX), geo.size.height / Swift.max(0.01, maxY))
                let ox = (geo.size.width - maxX * sc) / 2, oy = (geo.size.height - maxY * sc) / 2
                func pt(_ q: CGPoint) -> CGPoint { CGPoint(x: ox + q.x * sc, y: oy + q.y * sc) }
                path.move(to: pt(points[0]))
                for q in points.dropFirst() { path.addLine(to: pt(q)) }
            }
            .stroke(Color.red, lineWidth: 2)
        }
    }
}

