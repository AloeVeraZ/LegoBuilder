#if os(iOS)
import SwiftUI
import RealityKit
import ARKit
import Vision

/// Camera view for scanning the box and building in AR.
///
/// While scanning, it reads text from the camera (every ~0.4 s) and looks for the set number
/// printed on the box or booklet. If a photo of the box front is bundled (BoxFront.jpg) ARKit
/// also recognises the artwork. Nothing else starts the build: there is no way to place the
/// model by hand, so a different set, or no set, gets no instructions.
struct ARExperienceView: UIViewRepresentable {
    let app: AppModel

    func makeCoordinator() -> ARCoordinator { ARCoordinator(app: app) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ARCoordinator) {
        coordinator.stop()
    }
}

@MainActor
final class ARCoordinator: NSObject, ARSessionDelegate {
    private let app: AppModel
    private weak var view: ARView?
    private var anchor: AnchorEntity?
    private var lastScan: TimeInterval = 0
    private var readingText = false
    private var gesturesInstalled = false
    private var trackingSince: TimeInterval = 0
    private var restOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])   // upright, as placed
    private var restPosition = SIMD3<Float>.zero                          // where it stands, as placed
    private var glide: Glide?                                             // a turn in progress

    /// A smooth turn to a new view, about the middle of the step's pieces.
    private struct Glide {
        var fromTurn: simd_quatf, toTurn: simd_quatf
        var fromCentre: SIMD3<Float>, toCentre: SIMD3<Float>
        var start: TimeInterval = 0
        var duration: TimeInterval
        var endsAtRest: Bool
    }
    private var lastStep = -1
    private var tumbled = false                                           // turned by hand since the last step
    private var pivot = SIMD3<Float>.zero       // the point that stays still while turning or resizing
    private var baseScale: Float = 1
    private var pinchStart: Float = 1
    private var twistStart = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var placeWhenTracking = false

    init(app: AppModel) {
        self.app = app
    }

    func attach(_ view: ARView) {
        self.view = view
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            // Lets your hands appear in front of the virtual model while you build.
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        if let reference = Self.boxReferenceImage() {
            config.detectionImages = [reference]
            config.maximumNumberOfTrackedImages = 1
        }
        view.session.delegate = self
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        app.viewCube.onDrag = { [weak self] moved, began in self?.cubeDragged(moved, began: began) }
        app.viewCube.onFace = { [weak self] face in self?.look(at: face) }
        app.viewCube.onHome = { [weak self] in self?.returnToRest() }

        // Coming back from the 3D view mid-build: put the model in front of the camera.
        placeWhenTracking = app.arPhase != .scanning
    }

    func stop() {
        view?.session.pause()
    }

    /// Start over: hide the model and look for the box again.
    func rescan() {
        anchor?.removeFromParent()
        anchor = nil
    }

    // MARK: ARSessionDelegate (ARKit calls these on the main queue)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.handle(frame) }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            guard self.app.arPhase == .scanning else { return }
            if let image = anchors.compactMap({ $0 as? ARImageAnchor }).first {
                self.place(at: image.transform.translation, found: true)
            }
        }
    }

    // MARK: scanning

    private func handle(_ frame: ARFrame) {
        guard let view else { return }
        guard case .normal = frame.camera.trackingState else { return }

        if placeWhenTracking {
            // Straight into AR: first find the table (the "move iPhone" coaching is up while
            // this happens), then the step appears standing on it. If no surface turns up
            // in a few seconds, the model goes in front of the camera instead of nothing.
            if trackingSince == 0 { trackingSince = frame.timestamp }
            let point = freeCentre(of: view)
            if let hit = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first {
                placeWhenTracking = false
                place(at: hit.worldTransform.translation, found: false)
                pin(to: hit)
            } else if frame.timestamp - trackingSince > 6 {
                placeWhenTracking = false
                placeInFront()
            }
            return
        }
        if app.step != lastStep {
            lastStep = app.step
            returnToRest()
        }
        advanceGlide(at: frame.timestamp)
        updateCube()
        if app.placingOnSurface, app.arPhase != .scanning { placeOnSurface() }
        if app.arPhase == .scanning, app.needsRescan {
            app.needsRescan = false
            rescan()
        }
        guard app.arPhase == .scanning, !readingText, frame.timestamp - lastScan > 0.4 else { return }
        lastScan = frame.timestamp
        readingText = true

        let buffer = frame.capturedImage
        let viewport = view.bounds.size
        let portrait = (view.window?.windowScene?.interfaceOrientation ?? .portrait) == .portrait
        let display = frame.displayTransform(for: .portrait, viewportSize: viewport)
        let number = BuildConfig.setNumber

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hit = SetNumberReader.find(number, in: buffer)
            Task { @MainActor in
                guard let self else { return }
                self.readingText = false
                guard let hit, self.app.arPhase == .scanning else { return }
                var screen = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
                if portrait {
                    // Vision point (upright portrait image, origin top-left) -> camera image -> view.
                    let imagePoint = CGPoint(x: hit.y, y: 1 - hit.x)
                    let normalized = imagePoint.applying(display)
                    screen = CGPoint(x: normalized.x * viewport.width, y: normalized.y * viewport.height)
                }
                self.place(atScreenPoint: screen, found: true)
            }
        }
    }

    // MARK: resizing and turning in place

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let root = app.scene?.root, anchor != nil else { return }
        if g.state == .began { beginPivot(root, onGround: !tumbled); pinchStart = root.scale.x }
        let wanted = pinchStart * Float(g.scale)
        root.scale = SIMD3(repeating: min(max(wanted, baseScale * 0.25), baseScale * 8))
        holdPivot(root, onGround: !tumbled)
        if !tumbled { restPosition = root.position }
    }

    /// One finger across the screen turns the model left and right on the spot. Tipping it
    /// over is the view cube's job, so a stray finger never leaves it at an odd angle.
    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let root = app.scene?.root, anchor != nil, app.arPhase != .scanning else { return }
        if g.state == .began { beginPivot(root, onGround: false); twistStart = root.orientation }
        root.orientation = simd_quatf(angle: Float(g.translation(in: g.view).x) * 0.008, axis: [0, 1, 0]) * twistStart
        holdPivot(root, onGround: false)
        tumbled = true
    }

    @objc private func twisted(_ g: UIRotationGestureRecognizer) {
        guard let root = app.scene?.root, anchor != nil else { return }
        if g.state == .began { beginPivot(root, onGround: false); twistStart = root.orientation }
        root.orientation = simd_quatf(angle: -Float(g.rotation), axis: [0, 1, 0]) * twistStart
        holdPivot(root, onGround: false)
        tumbled = true
    }

    // MARK: the view cube

    /// Dragging the cube turns the model with it, any way up: across turns it left and
    /// right, up and down tips it towards or away from you.
    private func cubeDragged(_ moved: CGSize, began: Bool) {
        guard let view, let anchor, let root = app.scene?.root else { return }
        if began { beginPivot(root, onGround: false); twistStart = root.orientation }
        let inAnchor = anchor.orientation(relativeTo: nil).inverse
        let flat = view.cameraTransform.rotation.act(SIMD3<Float>(1, 0, 0)) * SIMD3<Float>(1, 0, 1)
        let across = inAnchor.act(simd_length(flat) > 0.01 ? simd_normalize(flat) : SIMD3<Float>(1, 0, 0))
        let turn = simd_quatf(angle: Float(moved.width) * 0.022, axis: [0, 1, 0])
        let tip = simd_quatf(angle: Float(moved.height) * 0.022, axis: across)
        root.orientation = simd_normalize(tip * turn * twistStart)
        holdPivot(root, onGround: false)
        tumbled = true
    }

    /// Tapping a side of the cube turns that side of the model squarely towards you.
    private func look(at face: ViewCubeModel.Face) {
        guard let view, let anchor, let root = app.scene?.root else { return }
        beginPivot(root, onGround: false)
        let centre = anchor.convert(position: pivot, to: nil)
        var towards = view.cameraTransform.translation - centre
        towards.y = 0
        guard simd_length(towards) > 0.01 else { return }
        towards = simd_normalize(towards)
        let facingMe = simd_quatf(angle: atan2(towards.x, towards.z), axis: [0, 1, 0])
        let wanted = simd_normalize(anchor.orientation(relativeTo: nil).inverse * facingMe * face.toFront)
        glide = Glide(fromTurn: root.orientation, toTurn: wanted, fromCentre: pivot, toCentre: pivot, duration: 0.6, endsAtRest: false)
        tumbled = true
    }

    private func advanceGlide(at time: TimeInterval) {
        guard var g = glide, let root = app.scene?.root, anchor != nil else { glide = nil; return }
        if g.start == 0 { g.start = time; glide = g }
        let t = Float(min(1, max(0, (time - g.start) / g.duration)))
        let eased = t * t * (3 - 2 * t)
        root.orientation = simd_slerp(g.fromTurn, g.toTurn, eased)
        let centre = g.fromCentre + (g.toCentre - g.fromCentre) * eased
        root.position = centre - root.orientation.act(stepCentre(onGround: false) * root.scale.x)
        if t >= 1 {
            glide = nil
            if g.endsAtRest { tumbled = false }
        }
    }

    /// Keeps the cube turned the way the model looks from where the camera is now.
    private func updateCube() {
        guard let view, anchor != nil, let root = app.scene?.root else { return }
        let seen = simd_normalize(view.cameraTransform.rotation.inverse * root.orientation(relativeTo: nil))
        let cube = app.viewCube
        if abs(simd_dot(seen.vector, cube.rotation.vector)) < 0.99998 { cube.rotation = seen }
        let turned = tumbled && !(glide?.endsAtRest ?? false)
        if cube.turned != turned { cube.turned = turned }
    }

    // MARK: placing the model

    private func place(atScreenPoint point: CGPoint, found: Bool) {
        guard let view else { return }
        if let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
            place(at: hit.worldTransform.translation, found: found)
        } else {
            placeInFront(found: found)
        }
    }

    /// Where the model's base goes on screen so that the model fills the part the controls
    /// leave free (below the top buttons, above the step panel, which covers roughly the
    /// lower 45% of the screen). The model stands on this point and rises from it, so the
    /// point is near the bottom of that free area, not its middle.
    private func freeCentre(of view: ARView) -> CGPoint {
        CGPoint(x: view.bounds.midX, y: view.bounds.height * 0.48)
    }

    private func placeInFront(found: Bool = false) {
        guard let view else { return }
        let centre = freeCentre(of: view)
        if let hit = view.raycast(from: centre, allowing: .estimatedPlane, alignment: .horizontal).first {
            place(at: hit.worldTransform.translation, found: found)
            return
        }
        // No table found yet: put it along the line of sight through that same point,
        // far enough away for the enlarged model to fit in view.
        if let ray = view.ray(through: centre) {
            place(at: ray.origin + simd_normalize(ray.direction) * 1.4, found: found)
            return
        }
        let camera = view.cameraTransform
        place(at: camera.translation + camera.rotation.act(SIMD3<Float>(0, 0, -1)) * 1.4, found: found)
    }

    /// Stands the model on the real flat surface the camera is pointed at (a table top, the
    /// floor), and pins it to that surface so it stays there as you move around. Its size
    /// and the way it is turned are kept. Tries again every frame until a surface is seen.
    private func placeOnSurface() {
        guard let view, app.scene != nil, self.anchor != nil else { return }
        let point = freeCentre(of: view)
        // A surface ARKit has actually mapped, not a guess: that is what keeps it grounded.
        guard let hit = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? view.raycast(from: point, allowing: .existingPlaneInfinite, alignment: .horizontal).first else { return }
        app.scene?.root.stopAllAnimations()
        pin(to: hit)
        app.placingOnSurface = false
        Haptics.success()
    }

    /// Ties the model to the surface ARKit is tracking, so it follows as ARKit refines it,
    /// with the middle of what is being built over the point that was hit.
    private func pin(to hit: ARRaycastResult) {
        guard let view, let scene = app.scene else { return }
        let root = scene.root
        // If the model was still growing in, finish that now: it must not drift afterwards.
        root.stopAllAnimations()
        if root.scale.x < baseScale * 0.15 { root.scale = SIMD3(repeating: baseScale) }
        self.anchor?.removeFromParent()
        let pinned = AnchorEntity(raycastResult: hit)
        view.scene.addAnchor(pinned)
        self.anchor = pinned
        pinned.addChild(root)
        root.position = -root.orientation.act(stepCentre(onGround: true) * root.scale.x)
        rememberRest(root)
    }

    /// The middle of the pieces on screen for this step, in the model's own space:
    /// on the ground under them, or at their real height.
    private func stepCentre(onGround: Bool) -> SIMD3<Float> {
        guard let c = app.scene?.framingCentre else { return .zero }
        return SIMD3(c.x, onGround ? 0 : c.y, c.z)
    }

    /// Turning and resizing happen around the middle of the pieces on screen for this
    /// step, not around the middle of the whole truck, so what you are building stays
    /// where it is while it turns or grows.
    private func beginPivot(_ root: Entity, onGround: Bool) {
        root.stopAllAnimations()
        glide = nil
        pivot = root.position + root.orientation.act(stepCentre(onGround: onGround) * root.scale.x)
    }

    private func holdPivot(_ root: Entity, onGround: Bool) {
        root.position = pivot - root.orientation.act(stepCentre(onGround: onGround) * root.scale.x)
    }

    /// Remembers how the model stands (upright, where it was put), to come back to.
    private func rememberRest(_ root: Entity) {
        restOrientation = root.orientation
        restPosition = root.position
        glide = nil
        tumbled = false
    }

    /// Glides the model back to how it stood when it was placed: on a new step, so the
    /// step is seen the way it is meant to be, and from the cube's home button.
    private func returnToRest() {
        guard tumbled, let root = app.scene?.root, anchor != nil else { return }
        root.stopAllAnimations()
        let centre = stepCentre(onGround: false) * root.scale.x
        glide = Glide(
            fromTurn: root.orientation, toTurn: restOrientation,
            fromCentre: root.position + root.orientation.act(centre),
            toCentre: restPosition + restOrientation.act(centre),
            duration: 0.7, endsAtRest: true
        )
    }

    private func place(at position: SIMD3<Float>, found: Bool) {
        guard let view, let scene = app.scene else { return }
        let anchor: AnchorEntity
        if let existing = self.anchor {
            anchor = existing
        } else {
            anchor = AnchorEntity(world: position)
            view.scene.addAnchor(anchor)
            self.anchor = anchor
        }
        anchor.position = position
        anchor.addChild(scene.root)

        // Face the camera, at a comfortable size, growing in with a spin.
        let toCamera = view.cameraTransform.translation - position
        let yaw = atan2(toCamera.x, toCamera.z)
        let (lo, hi) = scene.model.finishedBounds
        let longest = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 0.001)
        let scale = max(1, BuildConfig.arTargetSize / longest)
        let finalTransform = Transform(scale: SIMD3(repeating: scale), rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: .zero)
        scene.root.stopAllAnimations()
        scene.root.transform = Transform(scale: SIMD3(repeating: scale * 0.02), rotation: simd_quatf(angle: yaw - .pi * 0.9, axis: [0, 1, 0]), translation: .zero)
        _ = scene.root.move(to: finalTransform, relativeTo: anchor, duration: 0.9, timingFunction: .easeOut)
        restOrientation = finalTransform.rotation
        restPosition = .zero
        glide = nil
        tumbled = false

        baseScale = scale
        if !gesturesInstalled {
            gesturesInstalled = true
            // The model stays where it was put: no dragging it around the room. Spreading
            // two fingers anywhere on the screen makes it bigger, pinching makes it smaller,
            // and a two-finger twist turns it on the spot.
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
            view.addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(twisted(_:))))
            // One finger across the screen turns the model, to look at it from any side.
            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
            drag.maximumNumberOfTouches = 1
            view.addGestureRecognizer(drag)
        }
        if app.arPhase == .scanning {
            app.didPlaceModel(found: found)
        }
    }

    private static func boxReferenceImage() -> ARReferenceImage? {
        let url = Bundle.main.url(forResource: BuildConfig.boxImageName, withExtension: "jpg")
            ?? Bundle.main.url(forResource: BuildConfig.boxImageName, withExtension: "png")
        guard let url, let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let reference = ARReferenceImage(image, orientation: .up, physicalWidth: BuildConfig.boxImageWidthMeters)
        reference.name = "box"
        return reference
    }
}
#endif
