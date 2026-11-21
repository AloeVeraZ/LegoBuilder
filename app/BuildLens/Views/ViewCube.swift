import SwiftUI
import simd

/// What the corner view cube shows and asks for. The AR view keeps `rotation` current and
/// answers the requests; the cube itself knows nothing about AR.
@MainActor
@Observable
final class ViewCubeModel {
    enum Face: Int, CaseIterable {
        case front, back, right, left, top, bottom

        var label: String {
            switch self {
            case .front: "Front"
            case .back: "Back"
            case .right: "Right"
            case .left: "Left"
            case .top: "Top"
            case .bottom: "Bottom"
            }
        }

        /// Which way the face points, and which ways are "right" and "up" for its label.
        var axes: (normal: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
            switch self {
            case .front: ([0, 0, 1], [1, 0, 0], [0, 1, 0])
            case .back: ([0, 0, -1], [-1, 0, 0], [0, 1, 0])
            case .right: ([1, 0, 0], [0, 0, -1], [0, 1, 0])
            case .left: ([-1, 0, 0], [0, 0, 1], [0, 1, 0])
            case .top: ([0, 1, 0], [1, 0, 0], [0, 0, -1])
            case .bottom: ([0, -1, 0], [1, 0, 0], [0, 0, 1])
            }
        }
    }

    /// How the model is turned, as the camera sees it.
    var rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
    /// The model has been turned away from how it started.
    var turned = false

    var onDrag: ((CGSize, Bool) -> Void)?     // finger movement so far; true on the first call
    /// Look at the model from this direction (in the model's own axes), this way up.
    var onLook: ((SIMD3<Float>, SIMD3<Float>) -> Void)?
    /// Turn a step in a direction: (1, 0) right, (-1, 0) left, (0, 1) down, (0, -1) up.
    var onNudge: ((Int, Int) -> Void)?
    var onHome: (() -> Void)?
}

/// The cube in the corner, as in a CAD program. Drag it to turn the model any way. Tap the
/// middle of a face to look straight at that side, the strip along an edge to look over
/// that edge, or a corner to look from that corner. The arrows around it turn the model a
/// step at a time, and the home button puts everything back. Hold it (or spread two
/// fingers on it) to make it bigger.
struct ViewCube: View {
    let model: ViewCubeModel

    @State private var dragging = false
    @State private var pinching = false
    @State private var expanded = false
    @State private var touchBegan: Date?

    private var side: CGFloat { expanded ? 196 : 112 }
    /// Beyond this far from a face's middle, a tap means the edge or corner.
    private let rim: CGFloat = 0.6
    private let arrow: CGFloat = 26

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ZStack {
                cube
                nudge("chevron.compact.up", 0, -1).offset(y: -(side + arrow) / 2 + 6)
                nudge("chevron.compact.down", 0, 1).offset(y: (side + arrow) / 2 - 6)
                nudge("chevron.compact.left", -1, 0).offset(x: -(side + arrow) / 2 + 6)
                nudge("chevron.compact.right", 1, 0).offset(x: (side + arrow) / 2 - 6)
            }
            .frame(width: side + arrow * 2 - 12, height: side + arrow * 2 - 12)
            .animation(.spring(duration: 0.3), value: expanded)

            Button {
                Haptics.tap()
                model.onHome?()
            } label: {
                Image(systemName: "house.fill")
            }
            .buttonStyle(CircleButtonStyle(surface: .glass))
            .opacity(model.turned ? 1 : 0)
            .allowsHitTesting(model.turned)
            .animation(.easeOut(duration: 0.2), value: model.turned)
            .accessibilityLabel("Original view")
        }
    }

    private func nudge(_ symbol: String, _ dx: Int, _ dy: Int) -> some View {
        Button {
            Haptics.tap()
            model.onNudge?(dx, dy)
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .frame(width: arrow + 8, height: arrow + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dx > 0 ? "Turn right" : dx < 0 ? "Turn left" : dy > 0 ? "Turn down" : "Turn up")
    }

    private var cube: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if touchBegan == nil { touchBegan = value.time }
                    guard !pinching else { return }
                    let moved = hypot(value.translation.width, value.translation.height)
                    guard dragging || moved > 10 else { return }
                    // Turn by how far the finger went across the cube, whatever its size.
                    let scale = 46 / side
                    model.onDrag?(CGSize(width: value.translation.width * scale, height: value.translation.height * scale), !dragging)
                    dragging = true
                }
                .onEnded { value in
                    let held = value.time.timeIntervalSince(touchBegan ?? value.time)
                    if !dragging && !pinching {
                        if held > 0.4 {
                            Haptics.tap()
                            expanded.toggle()
                        } else if let look = look(at: value.location) {
                            Haptics.tap()
                            model.onLook?(look.direction, look.up)
                        }
                    }
                    dragging = false
                    pinching = false
                    touchBegan = nil
                }
                .simultaneously(with: MagnifyGesture()
                    .onChanged { value in
                        pinching = true
                        if value.magnification > 1.2 { expanded = true }
                        if value.magnification < 0.8 { expanded = false }
                    }
                )
        )
        .accessibilityElement()
        .accessibilityLabel("View cube")
        .accessibilityHint("Drag to turn the model. Tap a side, edge or corner to look from there. Hold to make the cube bigger.")
    }

    // MARK: drawing

    private struct Projected {
        let face: ViewCubeModel.Face
        let centre: CGPoint
        let u: CGVector          // screen direction of the label's "right", half a side long
        let v: CGVector          // screen direction of the label's "down", half a side long
        let facing: CGFloat      // 1 = straight at the viewer, 0 = edge on

        var corners: [CGPoint] {
            [CGPoint(x: centre.x - u.dx - v.dx, y: centre.y - u.dy - v.dy),
             CGPoint(x: centre.x + u.dx - v.dx, y: centre.y + u.dy - v.dy),
             CGPoint(x: centre.x + u.dx + v.dx, y: centre.y + u.dy + v.dy),
             CGPoint(x: centre.x - u.dx + v.dx, y: centre.y - u.dy + v.dy)]
        }
    }

    /// The faces turned towards the viewer, flattened onto the screen.
    private func visibleFaces(side: CGFloat) -> [Projected] {
        let half = side * 0.28
        let mid = CGPoint(x: side / 2, y: side / 2)
        return ViewCubeModel.Face.allCases.compactMap { face in
            let axes = face.axes
            let n = model.rotation.act(axes.normal)
            guard n.z > 0.02 else { return nil }
            let r = model.rotation.act(axes.right)
            let d = model.rotation.act(-axes.up)
            return Projected(
                face: face,
                centre: CGPoint(x: mid.x + CGFloat(n.x) * half, y: mid.y - CGFloat(n.y) * half),
                u: CGVector(dx: CGFloat(r.x) * half, dy: -CGFloat(r.y) * half),
                v: CGVector(dx: CGFloat(d.x) * half, dy: -CGFloat(d.y) * half),
                facing: CGFloat(n.z)
            )
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let half = size.width * 0.28
        let big = size.width > 140
        let cuts: [CGFloat] = [-1, -rim, rim, 1]
        for face in visibleFaces(side: size.width) {
            func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
                CGPoint(x: face.centre.x + a * face.u.dx + b * face.v.dx, y: face.centre.y + a * face.u.dy + b * face.v.dy)
            }
            // Each face is a middle (the face itself) inside a bevel: four edge strips
            // and four corners, shaded apart so each reads as its own thing to tap.
            for i in 0 ..< 3 {
                for j in 0 ..< 3 {
                    var cell = Path()
                    cell.addLines([point(cuts[i], cuts[j]), point(cuts[i + 1], cuts[j]),
                                   point(cuts[i + 1], cuts[j + 1]), point(cuts[i], cuts[j + 1])])
                    cell.closeSubpath()
                    let isMiddle = i == 1 && j == 1, isCorner = i != 1 && j != 1
                    context.fill(cell, with: .color(Theme.Palette.surface.opacity(0.94)))
                    let light = isMiddle ? 0.10 + 0.16 * face.facing : isCorner ? 0.0 : 0.04 + 0.05 * face.facing
                    context.fill(cell, with: .color(.white.opacity(light)))
                    context.stroke(cell, with: .color(.white.opacity(0.16)), lineWidth: 0.75)
                }
            }
            var outline = Path()
            outline.addLines(face.corners)
            outline.closeSubpath()
            context.stroke(outline, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

            // The label lies on the face, so it leans and squashes with it.
            guard face.facing > 0.3 else { continue }
            var label = context
            label.opacity = Double(min(1, (face.facing - 0.3) * 2.5))
            label.concatenate(CGAffineTransform(
                a: face.u.dx / half, b: face.u.dy / half,
                c: face.v.dx / half, d: face.v.dy / half,
                tx: face.centre.x, ty: face.centre.y
            ))
            label.draw(
                Text(face.face.label.uppercased())
                    .font(.system(size: big ? 14 : 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary),
                at: .zero
            )
        }
    }

    /// Where a tap asks to look from: straight at a face, or over the edge or corner of
    /// the face nearest the tap.
    private func look(at point: CGPoint) -> (direction: SIMD3<Float>, up: SIMD3<Float>)? {
        for face in visibleFaces(side: side) {
            // Solve point = centre + a*u + b*v; inside when both are within one half-side.
            let det = face.u.dx * face.v.dy - face.u.dy * face.v.dx
            guard abs(det) > 0.001 else { continue }
            let px = point.x - face.centre.x, py = point.y - face.centre.y
            let a = (px * face.v.dy - py * face.v.dx) / det
            let b = (face.u.dx * py - face.u.dy * px) / det
            guard abs(a) <= 1, abs(b) <= 1 else { continue }
            let axes = face.face.axes
            var direction = axes.normal
            if abs(a) > rim { direction += axes.right * (a > 0 ? 1 : -1) }
            if abs(b) > rim { direction -= axes.up * (b > 0 ? 1 : -1) }
            direction = simd_normalize(direction)
            // Keep the model the right way up, except looking straight down or up at it.
            let up: SIMD3<Float> = abs(direction.y) > 0.99 ? axes.up : [0, 1, 0]
            return (direction, up)
        }
        return nil
    }
}
