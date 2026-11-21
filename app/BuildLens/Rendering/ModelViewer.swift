import SwiftUI
import RealityKit

/// The non-AR 3D view (iPhone and Mac): a studio floor, soft lights and an orbit camera.
/// iPhone: drag to orbit, pinch to zoom, double-tap to reset.
/// Mac: drag to orbit, pinch on the trackpad (or the +/- buttons) to zoom, double-click to reset.
struct ModelViewer: View {
    let scene: BuildScene
    let controller: OrbitController

    var body: some View {
        ModelViewerRepresentable(controller: controller)
    }
}

@MainActor
final class OrbitController: NSObject {
    let scene: BuildScene
    private let anchor: AnchorEntity
    private let camera: PerspectiveCamera
    private weak var view: ARView?
    private var yaw: Float = 0.65
    private var pitch: Float = 0.42
    private var distance: Float = 0.5
    private var target: SIMD3<Float> = .zero
    private var radius: Float = 0.1
    private var startYaw: Float = 0
    private var startPitch: Float = 0
    private var startDistance: Float = 0
    /// The distance the step was framed at: zoom 1. Pinching in makes the zoom bigger.
    private var fittedDistance: Float = 0.5

    /// The user turned or zoomed the model by hand: (spin in degrees, the model's own turn as
    /// seen, 0 = front towards you; zoom, 1 = as framed). Shared with the glasses and Mac.
    /// The third value is the lean, in degrees seen from above (the camera's height).
    var onUserTurn: ((Double, Double, Double) -> Void)?

    /// Turned or zoomed on the glasses (or Mac): show it the same here, without echoing it back.
    func apply(spin: Double, zoom: Double?, tilt: Double?) {
        cameraGlide?.cancel()
        // The camera going round to the right turns the model the other way as seen.
        yaw = -Float(spin * .pi / 180)
        if let tilt { pitch = min(max(Float(tilt * .pi / 180), -0.15), 1.45) }
        if let zoom, zoom > 0 { distance = clampDistance(fittedDistance / Float(zoom)) }
        update()
    }

    private func reportTurn() {
        let spin = -Double(yaw) * 180 / .pi
        onUserTurn?(spin, Double(fittedDistance / max(distance, 1e-4)), Double(pitch) * 180 / .pi)
    }
    private var didSetUpScene = false
    private var cameraGlide: Task<Void, Never>?

    /// How far above the middle of the view the model is shown, as a fraction of half the
    /// view's height. On iPhone the step controls cover the lower part of the screen.
    #if os(iOS)
    var verticalBias: Float = 0.3 { didSet { update() } }
    #else
    var verticalBias: Float = 0 { didSet { update() } }
    #endif

    static let background = PlatformColor(red: 0.925, green: 0.933, blue: 0.95, alpha: 1)

    init(scene: BuildScene) {
        self.scene = scene
        anchor = AnchorEntity(world: .zero)
        camera = PerspectiveCamera()
        super.init()
        camera.camera.fieldOfViewInDegrees = 38
    }

    func makeView() -> ARView {
        #if os(iOS)
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        #else
        let view = ARView(frame: .zero)
        #endif
        attach(view)
        return view
    }

    private func attach(_ view: ARView) {
        self.view = view
        view.environment.background = .color(Self.background)
        if !didSetUpScene {
            didSetUpScene = true
            anchor.addChild(camera)
            addLights()
            addFloor()
        }
        view.scene.addAnchor(anchor)
        anchor.addChild(scene.root)
        scene.root.transform = Transform()
        scene.onFramingChange = { [weak self] centre, radius, yaw, glide in
            self?.frame(centre: centre, radius: radius, yaw: yaw, animated: glide)
        }
        frame(centre: scene.framingCentre, radius: scene.framingRadius)
        installInput(on: view)
        // Re-aim once the view has its real size (aspect ratio affects the fit).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.frame(centre: self.target, radius: self.radius)
        }
    }

    // MARK: camera

    func zoom(by factor: Float) {
        distance = clampDistance(distance * factor)
        update()
        reportTurn()
    }

    @objc func resetView() {
        yaw = 0.65
        pitch = 0.42
        frame(centre: target, radius: radius)
    }

    /// Called when the user has turned the model by hand, with the nearest of the four views.
    var onUserView: ((Int) -> Void)?

    private var reduceMotion: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    /// Aims the camera at a sphere, optionally from a given side. Step changes glide there
    /// instead of jumping. A turn to another side is slow and eased, never a whip-round,
    /// and with Reduce Motion on the camera simply cuts.
    private func frame(centre: SIMD3<Float>, radius r: Float, yaw newYaw: Float? = nil, animated: Bool = false) {
        radius = r
        let vfov = camera.camera.fieldOfViewInDegrees * .pi / 180
        var aspect: Float = 0.6
        if let size = view?.bounds.size, size.width > 1, size.height > 1 {
            aspect = Float(size.width / size.height)
        }
        let hfov = 2 * atan(tan(vfov / 2) * aspect)
        // Fit into the part of the view that is left above the controls.
        let fitted = r * 1.2 / sin(min(vfov * (1 - verticalBias), hfov) / 2)
        // The short way round to the new side.
        var turn: Float = 0
        if let newYaw { turn = atan2(sin(newYaw - yaw), cos(newYaw - yaw)) }
        cameraGlide?.cancel()
        let moved = simd_distance(centre, target) > 1e-5 || abs(fitted - distance) > 1e-5 || abs(turn) > 1e-3
        fittedDistance = fitted
        guard animated, moved, !reduceMotion else {
            target = centre
            distance = fitted
            yaw += turn
            update()
            return
        }
        let (fromTarget, fromDistance, fromYaw) = (target, distance, yaw)
        // About a quarter turn a second at most.
        let duration = max(0.6, Double(abs(turn)) / (.pi / 2) * 1.0)
        let start = Date()
        cameraGlide = Task { @MainActor [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                let t = Float(min(Date().timeIntervalSince(start) / duration, 1))
                let eased = t * t * (3 - 2 * t)
                self.target = fromTarget + (centre - fromTarget) * eased
                self.distance = fromDistance + (fitted - fromDistance) * eased
                self.yaw = fromYaw + turn * eased
                self.update()
                if t >= 1 { return }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    /// The zoom range, the same as the glasses' (GhostView.MIN_SIZE, MAX_SIZE): out no further
    /// than the step as it was framed (1), in up to 8 times closer.
    static let minZoom: Float = 1, maxZoom: Float = 8

    private func clampDistance(_ d: Float) -> Float {
        min(max(d, fittedDistance / Self.maxZoom), fittedDistance / Self.minZoom)
    }

    private func update() {
        let offset = SIMD3<Float>(
            distance * cos(pitch) * sin(yaw),
            distance * sin(pitch),
            distance * cos(pitch) * cos(yaw)
        )
        camera.camera.near = max(distance / 200, 0.0005)
        camera.camera.far = distance * 40
        // Slide the whole camera down so the model appears higher in the view.
        let forward = simd_normalize(-offset)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let cameraUp = simd_cross(right, forward)
        let vfov = camera.camera.fieldOfViewInDegrees * .pi / 180
        let shift = cameraUp * (verticalBias * distance * tan(vfov / 2))
        camera.look(at: target - shift, from: target + offset - shift, relativeTo: anchor)
    }

    private func addLights() {
        let key = DirectionalLight()
        key.light.intensity = 3200
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 2, depthBias: 1)
        key.look(at: .zero, from: [-0.5, 1.0, 0.7], relativeTo: nil)
        anchor.addChild(key)

        let fill = DirectionalLight()
        fill.light.intensity = 1100
        fill.look(at: .zero, from: [0.9, 0.5, -0.6], relativeTo: nil)
        anchor.addChild(fill)
    }

    private func addFloor() {
        var floorMaterial = PhysicallyBasedMaterial()
        floorMaterial.baseColor = .init(tint: Self.background)
        floorMaterial.roughness = .init(floatLiteral: 1)
        let floor = ModelEntity(mesh: .generatePlane(width: 6, depth: 6), materials: [floorMaterial])
        floor.position = [0, -0.0004, 0]
        anchor.addChild(floor)
    }

    // MARK: input

    #if os(iOS)
    private func installInput(on view: ARView) {
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetView))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { startYaw = yaw; startPitch = pitch; cameraGlide?.cancel() }
        if g.state == .ended { onUserView?(BuildModel.view(nearest: yaw)) }
        let t = g.translation(in: g.view)
        yaw = startYaw - Float(t.x) * 0.016
        pitch = min(max(startPitch + Float(t.y) * 0.016, -0.15), 1.45)
        update()
        reportTurn()
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { startDistance = distance }
        distance = clampDistance(startDistance / Float(max(g.scale, 0.05)))
        update()
        reportTurn()
    }
    #else
    private func installInput(on view: ARView) {
        view.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        view.addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(magnify(_:))))
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(resetView))
        doubleClick.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClick)
    }

    @objc private func pan(_ g: NSPanGestureRecognizer) {
        if g.state == .began { startYaw = yaw; startPitch = pitch; cameraGlide?.cancel() }
        if g.state == .ended { onUserView?(BuildModel.view(nearest: yaw)) }
        let t = g.translation(in: g.view)
        yaw = startYaw - Float(t.x) * 0.016
        pitch = min(max(startPitch - Float(t.y) * 0.016, -0.15), 1.45)
        update()
        reportTurn()
    }

    @objc private func magnify(_ g: NSMagnificationGestureRecognizer) {
        if g.state == .began { startDistance = distance }
        distance = clampDistance(startDistance / Float(max(1 + g.magnification, 0.05)))
        update()
        reportTurn()
    }
    #endif
}

#if os(iOS)
private struct ModelViewerRepresentable: UIViewRepresentable {
    let controller: OrbitController
    func makeUIView(context: Context) -> ARView { controller.makeView() }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
#else
private struct ModelViewerRepresentable: NSViewRepresentable {
    let controller: OrbitController
    func makeNSView(context: Context) -> ARView { controller.makeView() }
    func updateNSView(_ nsView: ARView, context: Context) {}
}
#endif
