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
            placeWhenTracking = false
            placeInFront()
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
        if g.state == .began { root.stopAllAnimations(); pinchStart = root.scale.x }
        let wanted = pinchStart * Float(g.scale)
        root.scale = SIMD3(repeating: min(max(wanted, baseScale * 0.15), baseScale * 6))
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let root = app.scene?.root, anchor != nil, app.arPhase != .scanning else { return }
        if g.state == .began { root.stopAllAnimations(); twistStart = root.orientation }
        let turn = Float(g.translation(in: g.view).x) * 0.008
        root.orientation = simd_quatf(angle: turn, axis: [0, 1, 0]) * twistStart
    }

    @objc private func twisted(_ g: UIRotationGestureRecognizer) {
        guard let root = app.scene?.root, anchor != nil else { return }
        if g.state == .began { root.stopAllAnimations(); twistStart = root.orientation }
        root.orientation = simd_quatf(angle: -Float(g.rotation), axis: [0, 1, 0]) * twistStart
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
        guard let view, let root = app.scene?.root, self.anchor != nil else { return }
        let point = freeCentre(of: view)
        // A surface ARKit has actually mapped, not a guess: that is what keeps it grounded.
        guard let hit = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? view.raycast(from: point, allowing: .existingPlaneInfinite, alignment: .horizontal).first else { return }
        let keep = (root.scale, root.orientation)
        self.anchor?.removeFromParent()
        // Tied to the surface ARKit is tracking, so it follows as ARKit refines the surface.
        let pinned = AnchorEntity(raycastResult: hit)
        view.scene.addAnchor(pinned)
        self.anchor = pinned
        pinned.addChild(root)
        root.stopAllAnimations()
        root.transform = Transform(scale: keep.0, rotation: keep.1, translation: .zero)
        app.placingOnSurface = false
        Haptics.success()
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
