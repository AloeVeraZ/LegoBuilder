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
    var onHome: (() -> Void)?
}

/// The cube in the corner, as in a CAD program: drag it to turn the model any way, tap a
/// face to look straight at that side, and the home button puts everything back. Spread
/// two fingers on it (or hold it) and it grows; then the edges and corners of each face
/// can be tapped too, for the views in between.
struct ViewCube: View {
    let model: ViewCubeModel

    @State private var dragging = false
    @State private var pinching = false
    @State private var expanded = false
    @State private var touchBegan: Date?

    private var side: CGFloat { expanded ? 196 : 92 }
    private var half: CGFloat { side * 0.28 }
    /// Beyond this far from a face's middle, a tap means the edge or corner.
    private let rim: CGFloat = 0.5

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
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
            .animation(.spring(duration: 0.3), value: expanded)
            .accessibilityElement()
            .accessibilityLabel("View cube")
            .accessibilityHint("Drag to turn the model. Tap a side to look at it. Hold to make the cube bigger.")

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
        for face in visibleFaces(side: size.width) {
            var path = Path()
            path.addLines(face.corners)
            path.closeSubpath()
            context.fill(path, with: .color(Theme.Palette.surface.opacity(0.92)))
            context.fill(path, with: .color(.white.opacity(0.04 + 0.16 * face.facing)))
            context.stroke(path, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

            if big {
                // The middle of each face is the face; the band around it is its edges and corners.
                var middle = Path()
                middle.addLines([(-rim, -rim), (rim, -rim), (rim, rim), (-rim, rim)].map { a, b in
                    CGPoint(x: face.centre.x + a * face.u.dx + b * face.v.dx, y: face.centre.y + a * face.u.dy + b * face.v.dy)
                })
                middle.closeSubpath()
                context.stroke(middle, with: .color(.white.opacity(0.22)), lineWidth: 1)
            }

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
                    .font(.system(size: big ? 13 : 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary),
                at: .zero
            )
        }
    }

    /// Where a tap asks to look from: straight at a face, or (on the bigger cube) over the
    /// edge or corner of the face nearest the tap.
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
            if expanded {
                if abs(a) > rim { direction += axes.right * (a > 0 ? 1 : -1) }
                if abs(b) > rim { direction -= axes.up * (b > 0 ? 1 : -1) }
            }
            direction = simd_normalize(direction)
            // Keep the model the right way up, except looking straight down or up at it.
            let up: SIMD3<Float> = abs(direction.y) > 0.99 ? axes.up : [0, 1, 0]
            return (direction, up)
        }
        return nil
    }
}
