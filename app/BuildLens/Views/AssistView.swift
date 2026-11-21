import SwiftUI
import simd

/// The live view for the glasses: the camera's picture with the current step drawn onto
/// the real table. The phone lies on the table showing the marker, the build stands at a
/// fixed spot beside it, and the next piece is drawn in green going into the place it
/// belongs on the real one. On the glasses themselves only the green would be shown (the
/// real world is seen through the lens); here the camera picture stands in for that.
struct AssistView: View {
    @Environment(AppModel.self) private var app
    let tracker: MarkerTracker

    @State private var ghosts = GhostCache()
    @State private var began = Date()

    /// The build stands this far to the right of the marker's middle, clear of the phone.
    static let buildOffset: Float = 0.11

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, time: timeline.date.timeIntervalSince(began))
            }
        }
        .overlay(alignment: .bottom) {
            if tracker.state != .tracking {
                Label(tracker.state == .noCamera ? "No camera" : "Find the phone", systemImage: tracker.state == .noCamera ? "video.slash" : "iphone")
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(Theme.Palette.hud)
                    .shadow(color: .black, radius: 3)
                    .padding(Theme.Spacing.md)
            }
        }
        .onChange(of: app.step) { began = Date() }
        .accessibilityLabel("Live view with the next piece drawn in place")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let picture = tracker.imageSize
        // The camera picture fills the display; the same mapping places everything drawn on it.
        let scale = max(size.width / picture.width, size.height / picture.height)
        let origin = CGPoint(x: (size.width - picture.width * scale) / 2, y: (size.height - picture.height * scale) / 2)
        if let image = tracker.image {
            var world = context
            world.opacity = 0.8
            world.draw(Image(decorative: image, scale: 1),
                       in: CGRect(x: origin.x, y: origin.y, width: picture.width * scale, height: picture.height * scale))
        }
        guard let pose = tracker.pose, let model = app.model, let step = app.currentStep else { return }
        let ghost = ghosts.ghost(for: step, in: model)

        // Model space (+Y up, standing on its own ground) onto the table beside the marker:
        // the model's up is out of the phone's screen.
        let onTable = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(Self.buildOffset, 0, 0, 1)
        ))
        let toCamera = pose * onTable
        let f = CGFloat(tracker.focal), cx = picture.width / 2, cy = picture.height / 2
        func project(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: origin.x + (CGFloat(p.x / p.z) * f + cx) * scale, y: origin.y + (CGFloat(p.y / p.z) * f + cy) * scale)
        }
        func inCamera(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let v = toCamera * SIMD4(p, 1)
            return SIMD3(v.x, v.y, v.z)
        }
        let green = Theme.Palette.hud

        // Where the build stands: a ring on the table.
        var ring = Path()
        for k in 0 ... 48 {
            let a = Float(k) / 48 * 2 * .pi
            let p = inCamera(SIMD3(cos(a), 0, sin(a)) * ghost.radius)
            guard p.z > 0.01 else { return }
            if k == 0 { ring.move(to: project(p)) } else { ring.addLine(to: project(p)) }
        }
        context.stroke(ring, with: .color(green.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))

        // What is already built, faintly: the real pieces go on top of this.
        if !ghost.built.isEmpty {
            var shape = Path()
            var i = 0
            while i + 2 < ghost.built.count {
                let a = inCamera(ghost.built[i]), b = inCamera(ghost.built[i + 1]), c = inCamera(ghost.built[i + 2])
                i += 3
                guard a.z > 0.01, b.z > 0.01, c.z > 0.01, simd_dot(simd_cross(b - a, c - a), a) < 0 else { continue }
                shape.move(to: project(a)); shape.addLine(to: project(b)); shape.addLine(to: project(c)); shape.closeSubpath()
            }
            context.fill(shape, with: .color(green.opacity(0.16)))
        }

        // The new pieces, one after another: each waits off its place, goes in, and stays
        // while the next one takes its turn. Then the whole thing plays again.
        let turn = 1.1, hold = 0.9
        let loop = Double(ghost.turns) * turn + hold
        let t = time.truncatingRemainder(dividingBy: loop)
        var faces: [(depth: Float, a: CGPoint, b: CGPoint, c: CGPoint, light: Double)] = []
        for piece in ghost.fresh {
            let since = t - Double(piece.turn) * turn
            guard since >= 0 else { continue }               // not its turn yet
            let travel = min(max((since - 0.35) / 0.55, 0), 1)
            let eased = Float(travel * travel * (3 - 2 * travel))
            let shift = -piece.push * piece.gap * (1 - eased)
            var i = 0
            while i + 2 < piece.triangles.count {
                let a = inCamera(piece.triangles[i] + shift), b = inCamera(piece.triangles[i + 1] + shift), c = inCamera(piece.triangles[i + 2] + shift)
                i += 3
                guard a.z > 0.01, b.z > 0.01, c.z > 0.01 else { continue }
                let normal = simd_cross(b - a, c - a)
                guard simd_dot(normal, a) < 0 else { continue }      // facing away
                let facing = abs(simd_normalize(normal).z)
                faces.append(((a.z + b.z + c.z) / 3, project(a), project(b), project(c), 0.35 + 0.65 * Double(facing)))
            }
        }
        faces.sort { $0.depth > $1.depth }                       // far ones first
        for face in faces {
            var triangle = Path()
            triangle.move(to: face.a); triangle.addLine(to: face.b); triangle.addLine(to: face.c); triangle.closeSubpath()
            context.fill(triangle, with: .color(green.opacity(face.light)))
        }
    }
}

/// The pieces of one step as loose triangles, standing where the build stands.
struct Ghost {
    struct Piece {
        var triangles: [SIMD3<Float>]
        var push: SIMD3<Float>
        var gap: Float
        var turn: Int
    }

    var fresh: [Piece] = []
    var built: [SIMD3<Float>] = []
    var turns = 1
    var radius: Float = 0.04
}

/// Builds each step's ghost once and keeps it.
final class GhostCache {
    private var step = -1
    private var current = Ghost()
    private var parts: [Int: [SIMD3<Float>]] = [:]

    func ghost(for step: BuildModel.StepInfo, in model: BuildModel) -> Ghost {
        if step.index != self.step {
            self.step = step.index
            current = make(step, model)
        }
        return current
    }

    private func triangles(ofPart index: Int, _ model: BuildModel) -> [SIMD3<Float>] {
        if let known = parts[index] { return known }
        var out: [SIMD3<Float>] = []
        for group in model.package.parts[index].groups {
            let points = model.vectors(at: group.positions, count: group.vertexCount)
            for i in model.indices(at: group.indices, count: group.indexCount) { out.append(points[Int(i)]) }
        }
        parts[index] = out
        return out
    }

    private func make(_ step: BuildModel.StepInfo, _ model: BuildModel) -> Ghost {
        // The same placing as the 3D view: the assembly in its own axes, centred, on the ground.
        let (lo, hi) = BuildModel.bounds(step.assembly.bounds)
        let centre = (lo + hi) / 2
        var place = matrix_identity_float4x4
        place.columns.3 = SIMD4(-centre.x, -lo.y, -centre.z, 1)
        let local = place * model.assemblyMatrices[step.assembly.id].inverse
        func piece(_ id: Int) -> [SIMD3<Float>] {
            let m = local * model.instanceMatrices[id]
            return triangles(ofPart: model.package.instances[id].part, model).map { p in
                let v = m * SIMD4(p, 1)
                return SIMD3(v.x, v.y, v.z)
            }
        }

        var ghost = Ghost()
        ghost.radius = max(simd_length(SIMD2(hi.x - lo.x, hi.z - lo.z)) / 2 * 1.15, 0.03)
        let (flo, fhi) = model.finishedBounds
        let usualGap = max(simd_length(fhi - flo) / 2 * 0.28, 0.012)
        let added = Set(step.added)
        for id in step.visible where !added.contains(id) { ghost.built.append(contentsOf: piece(id)) }

        // Pieces that share an order number go in together; the rest one after another.
        var turnOf: [String: Int] = [:]
        var moved = Set<Int>()
        for (index, move) in step.moves.enumerated() where move.push.count == 3 {
            let key = move.order.map { "order \($0)" } ?? "move \(index)"
            let turn = turnOf[key] ?? turnOf.count
            turnOf[key] = turn
            let push = simd_normalize(SIMD3(move.push[0], move.push[1], move.push[2]))
            for id in move.pieces where added.contains(id) {
                moved.insert(id)
                ghost.fresh.append(Ghost.Piece(triangles: piece(id), push: push, gap: move.gap ?? usualGap, turn: turn))
            }
        }
        // A piece with no direction is the one everything else goes onto: it is simply shown in place.
        for id in step.added where !moved.contains(id) {
            ghost.fresh.append(Ghost.Piece(triangles: piece(id), push: [0, 1, 0], gap: 0, turn: 0))
        }
        ghost.turns = max(turnOf.count, 1)
        return ghost
    }
}

#if os(iOS)
/// The table marker, full screen on the phone. The phone lies on the table with this up,
/// and the glasses' camera finds it.
struct MarkerCard: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.ignoresSafeArea()
            if let code = MarkerImage.make() {
                Image(decorative: code, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    // 50 mm across on an iPhone screen (about 153 points to the inch).
                    .frame(width: 302, height: 302)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleButtonStyle(surface: .muted))
            .padding(Theme.Spacing.md)
            .accessibilityLabel("Close")
        }
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
#endif
