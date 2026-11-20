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
    private let arrow: Entity
    private var entities: [ModelEntity] = []
    private var meshes: [Int: MeshResource] = [:]
    private var materialCache: [String: RealityKit.Material] = [:]
    private var shownStep = -2          // -1 = finished model
    private var token = 0               // invalidates pending animations when the step changes

    /// Show earlier pieces faded so the new ones stand out.
    var dimPrevious = false

    /// Centre and radius of what is on screen, in `root` space. The 3D viewer aims its camera at it.
    private(set) var framingCentre: SIMD3<Float> = .zero
    private(set) var framingRadius: Float = 0.1
    var onFramingChange: ((SIMD3<Float>, Float) -> Void)?

    init(model: BuildModel) {
        self.model = model
        root = ModelEntity()
        turntable = Entity()
        content = Entity()
        arrow = Entity()
        root.name = "BuildRoot"
        root.addChild(turntable)
        turntable.addChild(content)
        content.addChild(arrow)
        buildArrow()
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

    func show(step index: Int, animated: Bool, force: Bool = false) {
        guard index >= 0, index < model.steps.count else { return }
        if index == shownStep && !force { return }
        shownStep = index
        token += 1
        turntable.stopAllAnimations()
        turntable.transform = Transform()
        let info = model.steps[index]
        let local = model.assemblyMatrices[info.assembly.id].inverse
        let added = Set(info.added)
        let visible = Set(info.visible)

        for (i, entity) in entities.enumerated() where !visible.contains(i) {
            entity.stopAllAnimations()
            entity.isEnabled = false
        }
        for i in info.visible {
            let entity = entities[i]
            entity.stopAllAnimations()
            let look: Look = added.contains(i) ? .highlight : (dimPrevious ? .dimmed : .normal)
            entity.model?.materials = materials(for: model.package.instances[i], look: look)
            entity.transform = Transform(matrix: local * model.instanceMatrices[i])
            entity.isEnabled = true
        }
        frame(assembly: info.assembly)
        if animated { animateIn(info.added, step: info, local: local) }
        placeArrow(over: info.added, local: local)
    }

    /// The whole finished model, every piece in its final place.
    func showFinished(animated: Bool) {
        shownStep = -1
        token += 1
        for (i, entity) in entities.enumerated() {
            entity.stopAllAnimations()
            entity.model?.materials = materials(for: model.package.instances[i], look: .normal)
            entity.transform = Transform(matrix: model.instanceMatrices[i])
            entity.isEnabled = true
        }
        arrow.stopAllAnimations()
        arrow.isEnabled = false
        frame(assembly: model.package.assemblies[0])
        turntable.stopAllAnimations()
        turntable.transform = Transform()
        if animated {
            turntable.transform = Transform(scale: .one, rotation: simd_quatf(angle: -.pi * 0.6, axis: [0, 1, 0]), translation: .zero)
            _ = turntable.move(to: Transform(), relativeTo: root, duration: 1.0, timingFunction: .easeOut)
        }
    }

    /// Re-applies the current step (for example after toggling dimming).
    func refresh() {
        if shownStep >= 0 { show(step: shownStep, animated: false, force: true) }
    }

    // MARK: internals

    private func frame(assembly a: BuildPackage.Assembly) {
        let (lo, hi) = BuildModel.bounds(a.bounds)
        let centre = (lo + hi) / 2
        content.position = SIMD3(-centre.x, -lo.y, -centre.z)
        framingCentre = SIMD3(0, (hi.y - lo.y) / 2, 0)
        framingRadius = max(simd_length(hi - lo) / 2, 0.01)
        onFramingChange?(framingCentre, framingRadius)
    }

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

    /// New pieces fly in from outside the model (from above for pieces on top,
    /// from the side for wheels and side panels, from below for pieces underneath).
    private func animateIn(_ ids: [Int], step: BuildModel.StepInfo, local: simd_float4x4) {
        let newIDs = Set(ids)
        let before = step.visible.filter { !newIDs.contains($0) }
        var centreBefore = SIMD3<Float>.zero
        if !before.isEmpty {
            centreBefore = before.reduce(SIMD3<Float>.zero) { $0 + pieceCentre($1, local) } / Float(before.count)
        }
        let distance = max(framingRadius * 0.7, 0.03)
        let current = token
        for (n, i) in ids.enumerated() {
            let entity = entities[i]
            let endTransform = Transform(matrix: local * model.instanceMatrices[i])
            var dir = SIMD3<Float>(0, 1, 0)
            if !before.isEmpty {
                let d = pieceCentre(i, local) - centreBefore
                if simd_length(d) > 1e-5 {
                    let u = simd_normalize(d)
                    dir = u.y < -0.6 ? SIMD3(0, -1, 0) : simd_normalize(SIMD3(u.x, max(u.y, 0) + 0.6, u.z))
                }
            }
            var start = endTransform
            start.translation += dir * distance
            entity.transform = start
            let delay = 0.12 + Double(min(n, 12)) * 0.07
            Task { @MainActor [weak self, weak entity] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, let entity, self.token == current else { return }
                _ = entity.move(to: endTransform, relativeTo: entity.parent, duration: 0.55, timingFunction: .easeOut)
            }
        }
    }

    private func buildArrow() {
        let material = UnlitMaterial(color: PlatformColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 1))
        // Unit-sized arrow pointing down (-Y) with its tip at the entity origin.
        let cone = ModelEntity(mesh: .generateCone(height: 0.6, radius: 0.32), materials: [material])
        cone.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
        cone.position = [0, 0.3, 0]
        let shaft = ModelEntity(mesh: .generateCylinder(height: 0.7, radius: 0.11), materials: [material])
        shaft.position = [0, 0.95, 0]
        arrow.addChild(cone)
        arrow.addChild(shaft)
        arrow.isEnabled = false
    }

    private func placeArrow(over ids: [Int], local: simd_float4x4) {
        arrow.stopAllAnimations()
        guard !ids.isEmpty else { arrow.isEnabled = false; return }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in ids {
            let (a, b) = pieceBounds(i, local)
            lo = pointwiseMin(lo, a)
            hi = pointwiseMax(hi, b)
        }
        let size = max(framingRadius * 0.11, 0.004)
        let tip = SIMD3<Float>((lo.x + hi.x) / 2, hi.y + size * 0.4, (lo.z + hi.z) / 2)
        let base = Transform(scale: SIMD3(repeating: size), rotation: simd_quatf(angle: 0, axis: [0, 1, 0]), translation: tip)
        arrow.transform = base
        arrow.isEnabled = true
        var up = base
        up.translation += SIMD3(0, size * 0.6, 0)
        let bob = FromToByAnimation<Transform>(
            name: "bob",
            from: base,
            to: up,
            duration: 0.55,
            timing: .easeInOut,
            isAdditive: false,
            bindTarget: .transform,
            repeatMode: .autoReverse
        )
        if let resource = try? AnimationResource.generate(with: bob) {
            _ = arrow.playAnimation(resource.repeat())
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
