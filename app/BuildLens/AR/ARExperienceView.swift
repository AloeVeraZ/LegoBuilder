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
    private var placeWhenTracking = false

    // Where the model is pinned. Kept here (not read back from the anchor entity, which
    // RealityKit only updates a frame later).
    private var anchorOrigin = SIMD3<Float>.zero
    private var anchorTurn = simd_quatf(angle: 0, axis: [0, 1, 0])

    // How the model stands when left alone: the step's pieces over `restGround`, turned
    // `restOrientation`, and sized so they fill a sphere of `fitRadius` metres.
    private var restGround = SIMD3<Float>.zero
    private var restOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var fitRadius: Float = 0.1
    private var userZoom: Float = 1              // pinched bigger or smaller than that
    private var tumbled = false                  // turned by hand since it last settled
    private var lastStep = -1
    private var lastFraming = SIMD4<Float>.zero  // centre and radius the model was settled for

    private var pivot = SIMD3<Float>.zero        // the point that stays still while turning or resizing
    private var pinchStart: Float = 1
    private var lastDrag = CGSize.zero
    private var lastTwist: CGFloat = 0
    private var glide: Glide?                    // a move in progress
    private weak var coaching: ARCoachingOverlayView?

    /// A smooth move to a new view, about the middle of the step's pieces.
    private struct Glide {
        var fromTurn: simd_quatf, toTurn: simd_quatf
        var fromScale: Float, toScale: Float
        var fromCentre: SIMD3<Float>, toCentre: SIMD3<Float>
        var start: TimeInterval = 0
        var duration: TimeInterval
        var endsAtRest: Bool
    }

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
        self.coaching = coaching
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        app.viewCube.onDrag = { [weak self] moved, began in self?.cubeDragged(moved, began: began) }
        app.viewCube.onLook = { [weak self] direction, up in self?.look(from: direction, up: up) }
        app.viewCube.onHome = { [weak self] in self?.goHome() }

        // Coming back from the 3D view mid-build: put the model in front of the camera.
        placeWhenTracking = app.arPhase != .scanning
        if placeWhenTracking {
            // Scan the table first, before anything else: the step panel stays away and
            // "Move iPhone to start" is up until there is a surface to stand the model on.
            app.arFindingSurface = true
            coaching.setActive(true, animated: false)
        }
    }

    func stop() {
        app.arFindingSurface = false
        view?.session.pause()
    }

    /// Start over: hide the model and look for the box again.
    func rescan() {
        anchor?.removeFromParent()
        anchor = nil
        glide = nil
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
        // Turning, resizing and the cube go on whatever the camera's tracking is doing.
        settleIfStepChanged()
        advanceGlide(at: frame.timestamp)
        updateCube()
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
            } else if frame.timestamp - trackingSince > 10 {
                placeWhenTracking = false
                placeInFront()
            }
            return
        }
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
        let fit = fitScale(zoom: 1)
        root.scale = SIMD3(repeating: min(max(pinchStart * Float(g.scale), fit * 0.25), fit * 8))
        holdPivot(root, onGround: !tumbled)
        userZoom = root.scale.x / fit
    }

    /// The camera's own right, up and towards-me directions, in the anchor's space.
    private func cameraAxes() -> (right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>)? {
        guard let view else { return nil }
        let turn = anchorTurn.inverse * view.cameraTransform.rotation
        return (turn.act([1, 0, 0]), turn.act([0, 1, 0]), turn.act([0, 0, 1]))
    }

    /// Turns the model as if it were a ball under the finger: across turns it left and
    /// right as you see it, up and down rolls it towards or away from you, from any angle.
    private func roll(_ root: Entity, across: CGFloat, down: CGFloat, perPoint: Float) {
        guard let axes = cameraAxes() else { return }
        let turn = simd_quatf(angle: Float(across) * perPoint, axis: axes.up)
        let tip = simd_quatf(angle: Float(down) * perPoint, axis: axes.right)
        root.orientation = simd_normalize(turn * tip * root.orientation)
        holdPivot(root, onGround: false)
        tumbled = true
    }

    /// One finger on the screen turns the model freely, in whatever direction it moves.
    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let root = app.scene?.root, anchor != nil, app.arPhase != .scanning else { return }
        let moved = g.translation(in: g.view)
        if g.state == .began { beginPivot(root, onGround: false); lastDrag = .zero }
        roll(root, across: moved.x - lastDrag.width, down: moved.y - lastDrag.height, perPoint: 0.008)
        lastDrag = CGSize(width: moved.x, height: moved.y)
    }

    /// Two fingers twisting spin it like a dial, facing you.
    @objc private func twisted(_ g: UIRotationGestureRecognizer) {
        guard let root = app.scene?.root, anchor != nil, let axes = cameraAxes() else { return }
        if g.state == .began { beginPivot(root, onGround: false); lastTwist = 0 }
        root.orientation = simd_normalize(simd_quatf(angle: -Float(g.rotation - lastTwist), axis: axes.back) * root.orientation)
        lastTwist = g.rotation
        holdPivot(root, onGround: false)
        tumbled = true
    }

    // MARK: the view cube

    /// Dragging the cube turns the model with it, the same way a finger on the model does.
    private func cubeDragged(_ moved: CGSize, began: Bool) {
        guard anchor != nil, let root = app.scene?.root else { return }
        if began { beginPivot(root, onGround: false); lastDrag = .zero }
        roll(root, across: moved.width - lastDrag.width, down: moved.height - lastDrag.height, perPoint: 0.03)
        lastDrag = moved
    }

    /// Tapping the cube turns the model so that side (or edge, or corner) looks straight
    /// into the phone, however the phone is held.
    private func look(from direction: SIMD3<Float>, up: SIMD3<Float>) {
        guard let view, anchor != nil, let root = app.scene?.root else { return }
        beginPivot(root, onGround: false)
        // The model's own axes that should end up as the screen's right, up and towards-me.
        let z = simd_normalize(direction)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        let toScreen = simd_quatf(simd_float3x3(columns: (x, y, z))).inverse
        let wanted = simd_normalize(anchorTurn.inverse * view.cameraTransform.rotation * toScreen)
        glide = Glide(fromTurn: root.orientation, toTurn: wanted, fromScale: root.scale.x, toScale: root.scale.x,
                      fromCentre: pivot, toCentre: pivot, duration: 0.6, endsAtRest: false)
        tumbled = true
    }

    /// The home button: back to how the step is meant to be seen, at its normal size.
    private func goHome() {
        userZoom = 1
        settle(duration: 0.7)
    }

    // MARK: settling into the step's own view

    /// The size at which the step's pieces fill the space chosen for them.
    private func fitScale(zoom: Float? = nil) -> Float {
        let radius = max(app.scene?.framingRadius ?? 0.1, 0.005)
        return fitRadius / radius * (zoom ?? userZoom)
    }

    /// Chooses how big the step's pieces should be in the room so that, from where the
    /// phone is now, they take up about half the width of the screen: the same on a desk
    /// at arm's length as on the floor across the room.
    private func chooseSize(lookingAt point: SIMD3<Float>) {
        guard let view else { return }
        let distance = simd_distance(view.cameraTransform.translation, point)
        var halfWidthPerMetre: Float = 0.33
        if let camera = view.session.currentFrame?.camera, view.bounds.height > 0 {
            // Upright, the screen's height shows the camera image's long side.
            let long = Float(max(camera.imageResolution.width, camera.imageResolution.height))
            let focal = camera.intrinsics[0][0]
            if focal > 0 { halfWidthPerMetre = long / 2 / focal * Float(view.bounds.width / view.bounds.height) }
        }
        fitRadius = min(max(distance * halfWidthPerMetre * 0.5, 0.02), 0.5)
        userZoom = 1
    }

    /// The way the model should be turned for this step: the side the 3D view would show
    /// (where the new pieces go on), facing wherever the phone is now.
    private func stepTurn() -> simd_quatf {
        guard let view else { return restOrientation }
        var towards = view.cameraTransform.translation - (anchorOrigin + anchorTurn.act(restGround))
        towards.y = 0
        guard simd_length(towards) > 0.01 else { return restOrientation }
        let side = BuildModel.viewYaws[app.userView ?? app.currentStep?.view ?? 0]
        let facing = simd_quatf(angle: atan2(towards.x, towards.z) - side, axis: [0, 1, 0])
        return simd_normalize(anchorTurn.inverse * facing)
    }

    private func angle(between a: simd_quatf, and b: simd_quatf) -> Float {
        2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
    }

    /// Where the middle of the step's pieces is when the model is at rest at this size.
    private func restCentre(scale: Float) -> SIMD3<Float> {
        restGround + SIMD3(0, stepCentre(onGround: false).y * scale, 0)
    }

    /// A new step (or one that needs more room): turn to its side, resize to fit and
    /// stand its pieces on the spot, as the 3D view does with its camera.
    private func settleIfStepChanged() {
        guard anchor != nil, let scene = app.scene else { return }
        let framing = SIMD4<Float>(scene.framingCentre, scene.framingRadius)
        guard app.step != lastStep || simd_distance(framing, lastFraming) > 1e-5 else { return }
        let newStep = app.step != lastStep
        lastStep = app.step
        lastFraming = framing
        if newStep {
            // Only turn when it is worth it: a small difference is not a reason to move.
            let wanted = stepTurn()
            if angle(between: wanted, and: restOrientation) > 0.35 { restOrientation = wanted }
        }
        settle(duration: 0.7)
    }

    /// Glides from however the model is now to its rest.
    private func settle(duration: TimeInterval) {
        guard anchor != nil, let root = app.scene?.root else { return }
        let scale = fitScale()
        let centre = root.position + root.orientation.act(stepCentre(onGround: false) * root.scale.x)
        let target = restCentre(scale: scale)
        let still = angle(between: root.orientation, and: restOrientation) < 0.005
            && abs(root.scale.x / scale - 1) < 0.005 && simd_distance(centre, target) < 0.001
        if still { glide = nil; tumbled = false; return }
        glide = Glide(fromTurn: root.orientation, toTurn: restOrientation, fromScale: root.scale.x, toScale: scale,
                      fromCentre: centre, toCentre: target, duration: duration, endsAtRest: true)
    }

    private func apply(_ g: Glide, eased: Float, to root: Entity) {
        root.orientation = simd_slerp(g.fromTurn, g.toTurn, eased)
        root.scale = SIMD3(repeating: g.fromScale * pow(g.toScale / g.fromScale, eased))
        let centre = g.fromCentre + (g.toCentre - g.fromCentre) * eased
        root.position = centre - root.orientation.act(stepCentre(onGround: false) * root.scale.x)
    }

    private func advanceGlide(at time: TimeInterval) {
        guard var g = glide, let root = app.scene?.root, anchor != nil else { glide = nil; return }
        if g.start == 0 { g.start = time; glide = g }
        let t = Float(min(1, max(0, (time - g.start) / g.duration)))
        apply(g, eased: t * t * (3 - 2 * t), to: root)
        if t >= 1 {
            glide = nil
            if g.endsAtRest { tumbled = false }
        }
    }

    /// Keeps the cube turned the way the model looks from where the camera is now.
    private func updateCube() {
        guard let view, anchor != nil, let root = app.scene?.root else { return }
        let seen = simd_normalize(view.cameraTransform.rotation.inverse * anchorTurn * root.orientation)
        let cube = app.viewCube
        if abs(simd_dot(seen.vector, cube.rotation.vector)) < 0.99998 { cube.rotation = seen }
        let turned = (tumbled || abs(userZoom - 1) > 0.05) && !(glide?.endsAtRest ?? false)
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
        pin(to: hit)
        app.placingOnSurface = false
        Haptics.success()
    }

    /// Ties the model to the surface ARKit is tracking, so it follows as ARKit refines it,
    /// with the middle of what is being built over the point that was hit.
    private func pin(to hit: ARRaycastResult) {
        guard let view, let scene = app.scene else { return }
        let root = scene.root
        let growing = glide != nil && root.scale.x < fitScale() * 0.5
        self.anchor?.removeFromParent()
        let pinned = AnchorEntity(raycastResult: hit)
        view.scene.addAnchor(pinned)
        self.anchor = pinned
        pinned.addChild(root)
        anchorOrigin = hit.worldTransform.translation
        anchorTurn = simd_normalize(simd_quatf(hit.worldTransform))
        stand(root, growing: growing)
    }

    /// Puts the model at rest on its anchor, sized and turned for where the phone is:
    /// growing in with a spin when it first appears, otherwise straight there.
    private func stand(_ root: Entity, growing: Bool) {
        // "Move iPhone to start" is only for finding the table the first time. Once the
        // model is down it must never come back over the build.
        coaching?.activatesAutomatically = false
        coaching?.setActive(false, animated: false)      // gone the moment the model can stand
        if app.arFindingSurface {
            app.arFindingSurface = false
            Haptics.success()
        }
        restGround = .zero
        chooseSize(lookingAt: anchorOrigin)
        restOrientation = stepTurn()
        tumbled = false
        lastStep = app.step
        if let scene = app.scene { lastFraming = SIMD4(scene.framingCentre, scene.framingRadius) }
        let scale = fitScale()
        let arrive = Glide(
            fromTurn: restOrientation * simd_quatf(angle: -.pi * 0.9, axis: [0, 1, 0]), toTurn: restOrientation,
            fromScale: scale * 0.02, toScale: scale,
            fromCentre: restGround, toCentre: restCentre(scale: scale),
            duration: 0.9, endsAtRest: true
        )
        if growing {
            glide = arrive
            apply(arrive, eased: 0, to: root)
        } else {
            glide = nil
            apply(arrive, eased: 1, to: root)
        }
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
        glide = nil
        pivot = root.position + root.orientation.act(stepCentre(onGround: onGround) * root.scale.x)
    }

    private func holdPivot(_ root: Entity, onGround: Bool) {
        root.position = pivot - root.orientation.act(stepCentre(onGround: onGround) * root.scale.x)
    }

    private func place(at position: SIMD3<Float>, found: Bool) {
        guard let view, let scene = app.scene else { return }
        self.anchor?.removeFromParent()
        let anchor = AnchorEntity(world: position)
        view.scene.addAnchor(anchor)
        self.anchor = anchor
        anchor.addChild(scene.root)
        anchorOrigin = position
        anchorTurn = simd_quatf(angle: 0, axis: [0, 1, 0])
        stand(scene.root, growing: true)

        if !gesturesInstalled {
            gesturesInstalled = true
            // The model stays where it was put: no dragging it around the room. One finger
            // turns it, spreading two fingers anywhere makes it bigger, pinching smaller,
            // and a two-finger twist spins it facing you.
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
            view.addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(twisted(_:))))
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
