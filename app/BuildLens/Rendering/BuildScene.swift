import Foundation
import RealityKit
import simd

/// Owns the RealityKit entities for one build and shows any step of it.
///
/// `root` is what views put in their scene (an AR anchor or the 3D viewer). AR gestures
/// move/rotate/scale `root`; `content` inside it is offset so whatever is being built sits
/// centred on y = 0, which keeps the model resting on the table / floor.
@MainActor
final class BuildScene {
    enum Look: String { case normal, highlight, dimmed }

    let model: BuildModel
    let root: ModelEntity
    private let turntable: Entity       // spins around the model's vertical axis
    private let content: Entity
    private var arrows: [Entity] = []   // arrows showing how the new pieces go in (up to 8)
    private var entities: [ModelEntity] = []
    private var meshes: [Int: MeshResource] = [:]
    private var materialCache: [String: RealityKit.Material] = [:]
    private var shownStep = -2          // -1 = finished model
    private var token = 0               // invalidates pending animations when the step changes
    private struct Waiting {
        let hover: Transform                    // where the piece is held, off its place
        let order: Int                          // pieces with the same order are pushed in together
    }
    private var waiting: [Int: Waiting] = [:]   // new pieces of the shown step
    private static let slotTime = 0.9           // long enough to watch the piece travel and seat
    private static let betweenSlots = 0.15

    /// Show earlier pieces faded so the new ones stand out.
    var dimPrevious = false

    /// Centre and radius of what is on screen, in `root` space. The 3D viewer aims its camera at it.
    private(set) var framingCentre: SIMD3<Float> = .zero
    private(set) var framingRadius: Float = 0.1
    /// Centre, radius, and whether the camera should glide there (false = cut).
    var onFramingChange: ((SIMD3<Float>, Float, Bool) -> Void)?

    init(model: BuildModel) {
        self.model = model
        root = ModelEntity()
        turntable = Entity()
        content = Entity()
        root.name = "BuildRoot"
        root.addChild(turntable)
        turntable.addChild(content)
        buildArrows()
    }

    /// Creates meshes and one entity per piece. Yields now and then so a progress bar can update.
    func prepare(progress: (Double) -> Void) async throws {
        let instances = model.package.instances
        entities.reserveCapacity(instances.count)
        for (i, inst) in instances.enumerated() {
            let entity = ModelEntity(mesh: try mesh(forPart: inst.part), materials: materials(for: inst, look: .normal))
            entity.name = "piece-\(i)"
            entity.isEnabled = false
            #if os(iOS)
            entity.components.set(GroundingShadowComponent(castsShadow: true))
            #endif
            content.addChild(entity)
            entities.append(entity)
            if i % 6 == 0 {
                progress(Double(i) / Double(max(instances.count, 1)))
                await Task.yield()
            }
        }
        // A collision box around the finished model lets the AR gestures grab it.
        let (lo, hi) = model.finishedBounds
        let size = pointwiseMax(hi - lo, SIMD3<Float>(repeating: 0.01))
        root.collision = CollisionComponent(shapes: [ShapeResource.generateBox(size: size).offsetBy(translation: [0, size.y / 2, 0])])
        progress(1)
    }

    var stepCount: Int { model.steps.count }

    // MARK: showing steps

    /// Shows a step the way you would do it by hand: the new pieces wait just off their
    /// place with an arrow showing which way to press. Moving on to the next step first
    /// clicks the waiting pieces home, then brings in the next ones.
    func show(step index: Int, animated: Bool, force: Bool = false) {
        guard index >= 0, index < model.steps.count else { return }
        if index == shownStep && !force { return }
        let previous = shownStep
        shownStep = index
        token += 1
        turntable.stopAllAnimations()
        turntable.transform = Transform()
        let info = model.steps[index]
        let local = model.assemblyMatrices[info.assembly.id].inverse
        let added = Set(info.added)
        let visible = Set(info.visible)

        // Pieces still waiting from the step before are pushed home first.
        var slotting: [Int: Waiting] = [:]
        if animated, previous >= 0, previous == index - 1,
           model.steps[previous].assembly.id == info.assembly.id {
            slotting = waiting
        }
        waiting.removeAll()

        for (i, entity) in entities.enumerated() where !visible.contains(i) {
            entity.stopAllAnimations()
            entity.isEnabled = false
        }
        for i in info.visible {
            let entity = entities[i]
            entity.stopAllAnimations()
            let look: Look = added.contains(i) ? .highlight : (dimPrevious ? .dimmed : .normal)
            entity.model?.materials = materials(for: model.package.instances[i], look: look)
            if slotting[i] == nil { entity.transform = Transform(matrix: local * model.instanceMatrices[i]) }
            entity.isEnabled = true
        }
        let wait = slotIn(slotting) { Transform(matrix: local * self.model.instanceMatrices[$0]) }
        let sameAssembly = previous >= 0 && model.steps[previous].assembly.id == info.assembly.id
        frame(step: info, glide: animated && sameAssembly)
        let moves = insertionMoves(for: info, local: local)
        bringIn(moves, local: local, animated: animated, after: wait)
        let arrival = moves.map(\.delay).max().map { wait + $0 + 0.55 } ?? 0
        placeArrows(for: moves, local: local, after: animated ? arrival : 0)
    }

    /// Pushes waiting pieces home so you see them travel and seat: one group after another,
    /// in the order you would do it by hand. Returns how long the whole thing takes.
    @discardableResult
    private func slotIn(_ pieces: [Int: Waiting], seated: (Int) -> Transform) -> Double {
        guard !pieces.isEmpty else { return 0 }
        let current = token
        let orders = Set(pieces.values.map(\.order)).sorted()
        let stride = Self.slotTime + Self.betweenSlots
        for (i, held) in pieces {
            let entity = entities[i]
            entity.transform = held.hover
            let target = seated(i)
            let delay = Double(orders.firstIndex(of: held.order) ?? 0) * stride
            Task { @MainActor [weak self, weak entity] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard let self, let entity, self.token == current else { return }
                _ = entity.move(to: target, relativeTo: entity.parent, duration: Self.slotTime, timingFunction: .easeInOut)
            }
        }
        return Double(orders.count) * stride
    }

    /// Pushes the waiting pieces home without moving on (used before a "well done" moment).
    /// Returns how long it takes.
    @discardableResult
    func seatWaiting() -> Double {
        guard shownStep >= 0, !waiting.isEmpty else { return 0 }
        token += 1
        let local = model.assemblyMatrices[model.steps[shownStep].assembly.id].inverse
        for i in waiting.keys {
            entities[i].stopAllAnimations()
            entities[i].model?.materials = materials(for: model.package.instances[i], look: .normal)
        }
        let time = slotIn(waiting) { Transform(matrix: local * self.model.instanceMatrices[$0]) }
        waiting.removeAll()
        for a in arrows { a.stopAllAnimations(); a.isEnabled = false }
        return time
    }

    /// The whole finished model, every piece in its final place.
    @discardableResult
    func showFinished(animated: Bool) -> Double {
        let shownWasMainModel = shownStep >= 0 && !model.steps[shownStep].isSubAssembly
        shownStep = -1
        token += 1
        let slotting = animated && shownWasMainModel ? waiting : [:]
        waiting.removeAll()
        for (i, entity) in entities.enumerated() {
            entity.stopAllAnimations()
            entity.model?.materials = materials(for: model.package.instances[i], look: .normal)
            if slotting[i] == nil { entity.transform = Transform(matrix: model.instanceMatrices[i]) }
            entity.isEnabled = true
        }
        // The last pieces are pushed home before anything else happens.
        let wait = slotIn(slotting) { Transform(matrix: self.model.instanceMatrices[$0]) }
        for a in arrows { a.stopAllAnimations(); a.isEnabled = false }
        frame(assembly: model.package.assemblies[0])
        turntable.stopAllAnimations()
        turntable.transform = Transform()
        if animated, wait == 0 {
            turntable.transform = Transform(scale: .one, rotation: simd_quatf(angle: -.pi * 0.6, axis: [0, 1, 0]), translation: .zero)
            _ = turntable.move(to: Transform(), relativeTo: root, duration: 1.0, timingFunction: .easeOut)
        }
        return wait
    }

    /// Re-applies the current step (for example after toggling dimming).
    func refresh() {
        if shownStep >= 0 { show(step: shownStep, animated: false, force: true) }
    }

    // MARK: internals

    private func contentOffset(for a: BuildPackage.Assembly) -> SIMD3<Float> {
        let (lo, hi) = BuildModel.bounds(a.bounds)
        let centre = (lo + hi) / 2
        return SIMD3(-centre.x, -lo.y, -centre.z)
    }

    private func frame(assembly a: BuildPackage.Assembly) {
        let (lo, hi) = BuildModel.bounds(a.bounds)
        content.position = contentOffset(for: a)
        framingCentre = SIMD3(0, (hi.y - lo.y) / 2, 0)
        framingRadius = max(simd_length(hi - lo) / 2, 0.01)
        onFramingChange?(framingCentre, framingRadius, true)
    }

    /// Like a CAD assembly, the grounded part stays put: the view only changes when the
    /// build has outgrown it, not at every step.
    private func frame(step info: BuildModel.StepInfo, glide: Bool) {
        content.position = contentOffset(for: info.assembly)
        let view = stepFraming[info.index]
        let changed = simd_distance(view.centre, framingCentre) > 1e-5 || abs(view.radius - framingRadius) > 1e-5
        framingCentre = view.centre
        framingRadius = view.radius
        if changed { onFramingChange?(view.centre, view.radius, glide) }
    }

    /// One view per run of steps: each run ends when the build is nearly twice the size it
    /// was at the run's start, and the whole run is framed on how it looks at its end.
    private lazy var stepFraming: [(centre: SIMD3<Float>, radius: Float)] = {
        let (flo, fhi) = model.finishedBounds
        let whole = max(simd_length(fhi - flo) / 2, 0.01)
        var result = [(centre: SIMD3<Float>, radius: Float)](repeating: (.zero, whole), count: model.steps.count)
        var byAssembly: [Int: [Int]] = [:]
        for (k, step) in model.steps.enumerated() { byAssembly[step.assembly.id, default: []].append(k) }
        for (assembly, stepIDs) in byAssembly {
            let local = model.assemblyMatrices[assembly].inverse
            let offset = contentOffset(for: model.package.assemblies[assembly])
            let boxes: [(SIMD3<Float>, SIMD3<Float>)] = stepIDs.map { k in
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for i in model.steps[k].visible {
                    let (plo, phi) = pieceBounds(i, local)
                    lo = pointwiseMin(lo, plo)
                    hi = pointwiseMax(hi, phi)
                }
                return (lo, hi)
            }
            func radius(_ n: Int) -> Float { simd_length(boxes[n].1 - boxes[n].0) / 2 }
            var start = 0
            while start < stepIDs.count {
                let limit = max(radius(start), whole * 0.3) * 1.8
                var end = start
                while end + 1 < stepIDs.count, radius(end + 1) <= limit { end += 1 }
                let view = (centre: (boxes[end].0 + boxes[end].1) / 2 + offset,
                            radius: max(radius(end) + waitingGap * 1.4, whole * 0.45))
                for n in start ... end { result[stepIDs[n]] = view }
                start = end + 1
            }
        }
        return result
    }()

    private func pieceBounds(_ i: Int, _ local: simd_float4x4) -> (SIMD3<Float>, SIMD3<Float>) {
        let (plo, phi) = BuildModel.bounds(model.package.parts[model.package.instances[i].part].bounds)
        let m = local * model.instanceMatrices[i]
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for x in [plo.x, phi.x] { for y in [plo.y, phi.y] { for z in [plo.z, phi.z] {
            let p = m.transformPoint(SIMD3(x, y, z))
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        } } }
        return (lo, hi)
    }

    private func pieceCentre(_ i: Int, _ local: simd_float4x4) -> SIMD3<Float> {
        let (lo, hi) = pieceBounds(i, local)
        return (lo + hi) / 2
    }

    // MARK: how pieces arrive

    /// The way printed instructions show a piece going on: pins and axles slide in along
    /// their shaft, wheels push onto their axle, a finished sub-build is lowered on as one
    /// unit, and other pieces come from outside the model.
    private struct Move {
        let piece: Int
        let direction: SIMD3<Float>     // unit vector, from the final position out to where it starts
        let distance: Float             // where it flies in from
        let gap: Float                  // where it waits until the next step
        let delay: Double
        let group: Int                  // pieces with the same group share one arrow
        let order: Int                  // pieces with the same order are pushed in together
        let still: Bool                 // simply there waiting, instead of gliding in
    }

    private enum PieceKind { case shaft, wheel, block }

    private func kind(of i: Int) -> PieceKind {
        let name = model.package.parts[model.package.instances[i].part].name.lowercased()
        if name.contains("wheel") || name.contains("tyre") || name.contains("tire") { return .wheel }
        let housings = ["connector", "block", "beam", "panel", "brick", "plate", "liftarm", "frame"]
        let shaft = (name.contains("pin") || name.contains("axle")) && !housings.contains(where: name.contains)
        return shaft ? .shaft : .block
    }

    /// Pieces that were put together in a sub-build step; when they show up again in the
    /// main model they arrive as one unit.
    private lazy var subBuilt: Set<Int> = Set(model.steps.filter(\.isSubAssembly).flatMap(\.added))

    /// How far off its place a new piece waits: enough for a pin to be clear of its hole
    /// (a pin goes 8 mm deep).
    private var waitingGap: Float {
        let (lo, hi) = model.finishedBounds
        return max(simd_length(hi - lo) / 2 * 0.28, 0.012)
    }

    private func insertionMoves(for step: BuildModel.StepInfo, local: simd_float4x4) -> [Move] {
        let ids = step.added
        let newIDs = Set(ids)
        let before = step.visible.filter { !newIDs.contains($0) }
        var centreBefore = SIMD3<Float>.zero
        if !before.isEmpty {
            centreBefore = before.reduce(SIMD3<Float>.zero) { $0 + pieceCentre($1, local) } / Float(before.count)
        }
        let gap = waitingGap
        let far = max(framingRadius * 0.9, gap * 2.5)
        let up = SIMD3<Float>(0, 1, 0)

        // The package says exactly how each piece goes on. Pieces it doesn't mention are
        // the grounded base of the step: they are simply there.
        if !step.moves.isEmpty {
            var moves: [Move] = []
            for (group, authored) in step.moves.enumerated() where authored.push.count == 3 {
                let push = SIMD3<Float>(authored.push[0], authored.push[1], authored.push[2])
                guard simd_length(push) > 1e-5 else { continue }
                let order = authored.order ?? group
                for i in authored.pieces where newIDs.contains(i) {
                    moves.append(Move(piece: i, direction: -simd_normalize(push), distance: far, gap: gap,
                                      delay: 0.1 + Double(min(order, 10)) * 0.4, group: group + 1,
                                      order: order, still: authored.still ?? false))
                }
            }
            return moves
        }

        // A sub-build being attached: everything comes down together.
        if !step.isSubAssembly, ids.count > 1, ids.contains(where: subBuilt.contains) {
            return ids.map { Move(piece: $0, direction: up, distance: far, gap: gap, delay: 0.15, group: 0, order: 0, still: false) }
        }

        var moves: [Move] = []
        var order = 0
        // Housings first, then the pins and axles that go into them.
        for pass in [PieceKind.block, .wheel, .shaft] {
            for i in ids where kind(of: i) == pass {
                let m = local * model.instanceMatrices[i]
                let away = pieceCentre(i, local) - centreBefore
                var direction = up
                var distance = far
                switch pass {
                case .shaft, .wheel:
                    let column = pass == .shaft ? m.columns.0 : m.columns.2
                    var axis = simd_normalize(SIMD3(column.x, column.y, column.z))
                    let side = before.isEmpty ? simd_dot(axis, up) : simd_dot(axis, away)
                    if side < 0 || (abs(side) < 1e-4 && axis.y < 0) { axis = -axis }
                    direction = axis
                    distance = far * 0.8
                case .block:
                    if !before.isEmpty, simd_length(away) > 1e-5 {
                        let u = simd_normalize(away)
                        direction = u.y < -0.6 ? -up : up       // always square to the model
                    }
                }
                // The first piece of a build is the base: it just sits there, nothing to press it into.
                let isBase = before.isEmpty && pass == .block
                moves.append(Move(piece: i, direction: direction, distance: distance, gap: isBase ? 0 : gap,
                                  delay: 0.12 + Double(min(order, 10)) * 0.4, group: moves.count + 1,
                                  order: order, still: false))
                order += 1
            }
        }
        return moves
    }

    /// New pieces glide in and stop just off their place. They then stay still: only the
    /// arrow moves, so the eye goes to where the piece has to be pushed.
    private func bringIn(_ moves: [Move], local: simd_float4x4, animated: Bool, after wait: Double) {
        let current = token
        for move in moves {
            let entity = entities[move.piece]
            let seated = Transform(matrix: local * model.instanceMatrices[move.piece])
            var hover = seated
            hover.translation += move.direction * move.gap
            if move.gap > 0 { waiting[move.piece] = Waiting(hover: hover, order: move.order) }
            guard animated, !move.still else {
                entity.transform = hover
                continue
            }
            var start = seated
            start.translation += move.direction * move.distance
            entity.transform = start
            let delay = wait + move.delay
            Task { @MainActor [weak self, weak entity] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, let entity, self.token == current else { return }
                _ = entity.move(to: hover, relativeTo: entity.parent, duration: 0.5, timingFunction: .easeOut)
            }
        }
    }

    private func buildArrows() {
        let material = UnlitMaterial(color: PlatformColor(red: 0.86, green: 0.12, blue: 0.15, alpha: 1))
        let coneMesh = MeshResource.generateCone(height: 0.6, radius: 0.32)
        let shaftMesh = MeshResource.generateCylinder(height: 0.7, radius: 0.11)
        for _ in 0 ..< 8 {
            // Unit-sized arrow with its tip at the entity origin and its tail along +Y.
            let arrow = Entity()
            let cone = ModelEntity(mesh: coneMesh, materials: [material])
            cone.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
            cone.position = [0, 0.3, 0]
            let shaft = ModelEntity(mesh: shaftMesh, materials: [material])
            shaft.position = [0, 0.95, 0]
            arrow.addChild(cone)
            arrow.addChild(shaft)
            arrow.isEnabled = false
            content.addChild(arrow)
            arrows.append(arrow)
        }
    }

    /// Puts an arrow beside each new piece (or one over a sub-build), pointing the way it goes in.
    private func placeArrows(for moves: [Move], local: simd_float4x4, after delay: Double) {
        let size = max(framingRadius * 0.09, 0.004)
        var spots: [(tip: SIMD3<Float>, direction: SIMD3<Float>)] = []
        for (_, members) in Dictionary(grouping: moves.filter { $0.gap > 0 }, by: \.group).sorted(by: { $0.key < $1.key }) {
            guard let direction = members.first?.direction else { continue }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for move in members {
                let (plo, phi) = pieceBounds(move.piece, local)
                lo = pointwiseMin(lo, plo)
                hi = pointwiseMax(hi, phi)
            }
            let gap = members.first?.gap ?? 0
            let reach = simd_dot(simd_abs(direction), (hi - lo) / 2)
            // Keep the whole bounce clear of the piece: the tip never comes closer than
            // half an arrow-length to it.
            let tip = (lo + hi) / 2 + direction * (gap + reach + size * 1.0)
            if !spots.contains(where: { simd_distance($0.tip, tip) < size * 1.5 }) { spots.append((tip, direction)) }
        }
        for (k, arrow) in arrows.enumerated() {
            arrow.stopAllAnimations()
            guard k < spots.count else { arrow.isEnabled = false; continue }
            let direction = spots[k].direction
            let rotation = direction.y < -0.999
                ? simd_quatf(angle: .pi, axis: [1, 0, 0])
                : simd_quatf(from: [0, 1, 0], to: direction)
            let base = Transform(scale: SIMD3(repeating: size), rotation: rotation, translation: spots[k].tip)
            arrow.transform = base
            arrow.isEnabled = delay <= 0
            var pressed = base
            pressed.translation -= direction * size * 0.4
            let bob = FromToByAnimation<Transform>(
                name: "bob",
                from: base,
                to: pressed,
                duration: 0.75,
                timing: .easeInOut,
                isAdditive: false,
                bindTarget: .transform,
                repeatMode: .autoReverse
            )
            if let resource = try? AnimationResource.generate(with: bob) {
                _ = arrow.playAnimation(resource.repeat())
            }
        }
        guard delay > 0 else { return }
        let current = token
        let shown = spots.count
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.token == current else { return }
            for arrow in self.arrows.prefix(shown) { arrow.isEnabled = true }
        }
    }

    private func mesh(forPart index: Int) throws -> MeshResource {
        if let cached = meshes[index] { return cached }
        let part = model.package.parts[index]
        var descriptors: [MeshDescriptor] = []
        for (gi, g) in part.groups.enumerated() {
            var d = MeshDescriptor(name: "part\(index)-\(gi)")
            d.positions = MeshBuffers.Positions(model.vectors(at: g.positions, count: g.vertexCount))
            d.normals = MeshBuffers.Normals(model.vectors(at: g.normals, count: g.vertexCount))
            d.primitives = .triangles(model.indices(at: g.indices, count: g.indexCount))
            d.materials = .allFaces(UInt32(gi))
            descriptors.append(d)
        }
        let mesh = try MeshResource.generate(from: descriptors)
        meshes[index] = mesh
        return mesh
    }

    private func materials(for inst: BuildPackage.Instance, look: Look) -> [RealityKit.Material] {
        model.package.parts[inst.part].groups.map { g in
            material(code: g.colour == 16 ? inst.colour : g.colour, look: look)
        }
    }

    private func material(code: Int, look: Look) -> RealityKit.Material {
        let key = "\(code)-\(look.rawValue)"
        if let cached = materialCache[key] { return cached }
        let c = model.colour(code)
        var rgb = SIMD3<Float>(c.rgba[0], c.rgba[1], c.rgba[2])
        var alpha: Float = c.rgba.count > 3 ? c.rgba[3] : 1
        if look == .dimmed {
            rgb += (SIMD3<Float>(repeating: 1) - rgb) * 0.55
            alpha = min(alpha, 0.35)
        }
        let color = PlatformColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        let metallic = c.finish == "chrome" || c.finish == "metal"
        m.metallic = .init(floatLiteral: metallic ? 0.9 : 0.0)
        m.roughness = .init(floatLiteral: c.finish == "rubber" ? 0.85 : 0.32)
        if c.finish != "rubber" {
            m.clearcoat = .init(floatLiteral: 0.5)
            m.clearcoatRoughness = .init(floatLiteral: 0.2)
        }
        if alpha < 0.99 {
            m.blending = .transparent(opacity: .init(floatLiteral: alpha))
        }
        if look == .highlight {
            m.emissiveColor = .init(color: color)
            m.emissiveIntensity = 0.4
        }
        materialCache[key] = m
        return m
    }
}
