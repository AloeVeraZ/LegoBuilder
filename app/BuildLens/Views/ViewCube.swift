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

        /// The turn that brings this face to where the front is.
        var toFront: simd_quatf {
            switch self {
            case .front: simd_quatf(angle: 0, axis: [0, 1, 0])
            case .back: simd_quatf(angle: .pi, axis: [0, 1, 0])
            case .right: simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
            case .left: simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            case .top: simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            case .bottom: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            }
        }
    }

    /// How the model is turned, as the camera sees it.
    var rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
    /// The model has been turned away from how it started.
    var turned = false

    var onDrag: ((CGSize, Bool) -> Void)?     // finger movement so far; true on the first call
    var onFace: ((Face) -> Void)?
    var onHome: (() -> Void)?
}

/// The cube in the corner, as in a CAD program: drag it to turn the model any way, tap a
/// face to look straight at that side, and the home button puts everything back.
struct ViewCube: View {
    let model: ViewCubeModel

    @State private var dragging = false

    private let side: CGFloat = 84
    private let half: CGFloat = 23

    var body: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let moved = hypot(value.translation.width, value.translation.height)
                        guard dragging || moved > 6 else { return }
                        model.onDrag?(value.translation, !dragging)
                        dragging = true
                    }
                    .onEnded { value in
                        if !dragging, let face = face(at: value.location) {
                            Haptics.tap()
                            model.onFace?(face)
                        }
                        dragging = false
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("View cube")
            .accessibilityHint("Drag to turn the model. Tap a side to look at it.")

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
    private func visibleFaces() -> [Projected] {
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
        for face in visibleFaces() {
            var path = Path()
            path.addLines(face.corners)
            path.closeSubpath()
            context.fill(path, with: .color(Theme.Palette.surface.opacity(0.92)))
            context.fill(path, with: .color(.white.opacity(0.04 + 0.16 * face.facing)))
            context.stroke(path, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))

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
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary),
                at: .zero
            )
        }
    }

    /// The face under a touch, if any.
    private func face(at point: CGPoint) -> ViewCubeModel.Face? {
        visibleFaces().first { face in
            // Solve point = centre + a*u + b*v; inside when both are within one half-side.
            let det = face.u.dx * face.v.dy - face.u.dy * face.v.dx
            guard abs(det) > 0.001 else { return false }
            let px = point.x - face.centre.x, py = point.y - face.centre.y
            let a = (px * face.v.dy - py * face.v.dx) / det
            let b = (face.u.dx * py - face.u.dy * px) / det
            return abs(a) <= 1 && abs(b) <= 1
        }?.face
    }
}
