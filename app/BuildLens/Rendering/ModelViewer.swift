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
        scene.onFramingChange = { [weak self] centre, radius, glide in
            self?.frame(centre: centre, radius: radius, animated: glide)
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
    }

    @objc func resetView() {
        yaw = 0.65
        pitch = 0.42
        frame(centre: target, radius: radius)
    }

    /// Aims the camera at a sphere. Step changes glide there instead of jumping.
    private func frame(centre: SIMD3<Float>, radius r: Float, animated: Bool = false) {
        radius = r
        let vfov = camera.camera.fieldOfViewInDegrees * .pi / 180
        var aspect: Float = 0.6
        if let size = view?.bounds.size, size.width > 1, size.height > 1 {
            aspect = Float(size.width / size.height)
        }
        let hfov = 2 * atan(tan(vfov / 2) * aspect)
        // Fit into the part of the view that is left above the controls.
        let fitted = r * 1.2 / sin(min(vfov * (1 - verticalBias), hfov) / 2)
        cameraGlide?.cancel()
        guard animated else {
            target = centre
            distance = fitted
            update()
            return
        }
        let (fromTarget, fromDistance) = (target, distance)
        cameraGlide = Task { @MainActor [weak self] in
            let frames = 36
            for f in 1 ... frames {
                guard let self, !Task.isCancelled else { return }
                let t = Float(f) / Float(frames)
                let eased = t * t * (3 - 2 * t)
                self.target = fromTarget + (centre - fromTarget) * eased
                self.distance = fromDistance + (fitted - fromDistance) * eased
                self.update()
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func clampDistance(_ d: Float) -> Float {
        min(max(d, radius * 0.6), radius * 12)
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
        if g.state == .began { startYaw = yaw; startPitch = pitch }
        let t = g.translation(in: g.view)
        yaw = startYaw - Float(t.x) * 0.008
        pitch = min(max(startPitch + Float(t.y) * 0.008, -0.15), 1.45)
        update()
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { startDistance = distance }
        distance = clampDistance(startDistance / Float(max(g.scale, 0.05)))
        update()
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
        if g.state == .began { startYaw = yaw; startPitch = pitch }
        let t = g.translation(in: g.view)
        yaw = startYaw - Float(t.x) * 0.008
        pitch = min(max(startPitch - Float(t.y) * 0.008, -0.15), 1.45)
        update()
    }

    @objc private func magnify(_ g: NSMagnificationGestureRecognizer) {
        if g.state == .began { startDistance = distance }
        distance = clampDistance(startDistance / Float(max(1 + g.magnification, 0.05)))
        update()
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
