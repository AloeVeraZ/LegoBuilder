import AVFoundation
import CoreImage
import Observation
import Vision
import simd

/// Finds the table marker (a QR code shown on the phone's screen) in a camera's picture and
/// works out where it is in space. That marker is the landmark everything else hangs on:
/// the build stands at a fixed spot beside it, so a ghost of the next piece can be drawn
/// exactly where it goes on the real one.
///
/// On the Mac the built-in camera stands in for the camera on the glasses.
@MainActor
@Observable
final class MarkerTracker: NSObject {
    /// What the marker says. Any other QR code is ignored.
    nonisolated static let payload = "BUILDLENS-TABLE"
    /// How wide the marker is on the phone's screen, in metres.
    nonisolated static let side: Float = 0.05

    enum State: Equatable { case off, starting, noCamera, looking, tracking }

    private(set) var state: State = .off
    /// The latest camera picture.
    private(set) var image: CGImage?
    /// Where the marker is, as the camera sees it (camera axes: x right, y down, z forward).
    private(set) var pose: simd_float4x4?
    /// The camera picture's size and focal length, in pixels.
    private(set) var imageSize = CGSize(width: 1280, height: 720)
    private(set) var focal: Float = 1060

    @ObservationIgnored private let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "buildlens.marker")
    @ObservationIgnored private let context = CIContext()
    @ObservationIgnored private var lastSeen = Date.distantPast
    @ObservationIgnored private var configured = false

    func start() {
        guard state == .off || state == .noCamera else { return }
        state = .starting
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                guard granted, self.configure() else { self.state = .noCamera; return }
                self.state = .looking
                self.queue.async { [session = self.session] in session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
        state = .off
        pose = nil
        image = nil
    }

    private func configure() -> Bool {
        if configured { return true }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
        return true
    }

    /// Called with each picture's result, back on the main thread.
    private func took(_ picture: CGImage?, size: CGSize, corners: [CGPoint]?) {
        guard state == .looking || state == .tracking else { return }
        image = picture
        imageSize = size
        // No lens data from a plain webcam: assume an ordinary 62 degree wide view. The same
        // number is used to find the marker and to draw on it, so the two agree on the marker.
        focal = Float(size.width) / (2 * tan(62 * .pi / 360))
        if let corners, let found = Self.pose(corners: corners, size: size, focal: focal) {
            lastSeen = Date()
            // Smooth it a little, so the ghost does not shiver with every pixel of noise.
            if let old = pose {
                let turn = simd_slerp(simd_quatf(old), simd_quatf(found), 0.5)
                var mixed = simd_float4x4(turn)
                mixed.columns.3 = old.columns.3 + (found.columns.3 - old.columns.3) * 0.5
                pose = mixed
            } else {
                pose = found
            }
            state = .tracking
        } else if Date().timeIntervalSince(lastSeen) > 0.6 {
            pose = nil
            state = .looking
        }
    }

    // MARK: where the marker is

    /// The marker's place in space from its four corners in the picture (top-left, top-right,
    /// bottom-right, bottom-left, in pixels with y down). Marker axes: x to its right, y to
    /// its top, z out of the screen towards whoever is looking at it.
    nonisolated static func pose(corners: [CGPoint], size: CGSize, focal f: Float) -> simd_float4x4? {
        let half = Double(side) / 2
        let flat: [(Double, Double)] = [(-half, half), (half, half), (half, -half), (-half, -half)]
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2, f = Double(f)
        // Rays through the corners (the picture with the lens taken out of it).
        let rays = corners.map { ((Double($0.x) - cx) / f, (Double($0.y) - cy) / f) }
        // The flat-to-picture mapping h (8 unknowns) from the four corner pairs.
        var rows: [[Double]] = []
        for ((x, y), (u, v)) in zip(flat, rays) {
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        guard let h = solve(rows) else { return nil }
        var r1 = SIMD3(h[0], h[3], h[6]), r2 = SIMD3(h[1], h[4], h[7]), t = SIMD3(h[2], h[5], 1.0)
        let scale = 2 / (simd_length(r1) + simd_length(r2))
        r1 *= scale; r2 *= scale; t *= scale
        if t.z < 0 { r1 = -r1; r2 = -r2; t = -t }           // the marker is in front of the camera
        // Square the two directions up with each other.
        r1 = simd_normalize(r1)
        r2 = simd_normalize(r2 - r1 * simd_dot(r1, r2))
        let r3 = simd_cross(r1, r2)
        guard r1.x.isFinite, r2.x.isFinite, t.z.isFinite, t.z > 0.02 else { return nil }
        return simd_float4x4(columns: (
            SIMD4(Float(r1.x), Float(r1.y), Float(r1.z), 0),
            SIMD4(Float(r2.x), Float(r2.y), Float(r2.z), 0),
            SIMD4(Float(r3.x), Float(r3.y), Float(r3.z), 0),
            SIMD4(Float(t.x), Float(t.y), Float(t.z), 1)
        ))
    }

    /// Solves rows of [a1 ... an | b] by elimination.
    private nonisolated static func solve(_ input: [[Double]]) -> [Double]? {
        var m = input
        let n = m.count
        for col in 0 ..< n {
            guard let pivot = (col ..< n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for row in 0 ..< n where row != col {
                let k = m[row][col] / m[col][col]
                if k != 0 { for c in col ... n { m[row][c] -= k * m[col][c] } }
            }
        }
        return (0 ..< n).map { m[$0][n] / m[$0][$0] }
    }
}

extension MarkerTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CGFloat(CVPixelBufferGetWidth(buffer)), height = CGFloat(CVPixelBufferGetHeight(buffer))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        let code = request.results?.first { $0.payloadStringValue == MarkerTracker.payload }
        // Vision measures from the bottom-left, 0...1; the rest of this works in pixels from the top-left.
        let corners = code.map { c in
            [c.topLeft, c.topRight, c.bottomRight, c.bottomLeft].map { CGPoint(x: $0.x * width, y: (1 - $0.y) * height) }
        }
        let picture = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height))
        Task { @MainActor in
            self.took(picture, size: CGSize(width: width, height: height), corners: corners)
        }
    }
}

/// The marker itself, as a picture.
enum MarkerImage {
    static func make(pixels: CGFloat = 1024) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(MarkerTracker.payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let scale = (pixels / code.extent.width).rounded(.down)
        let big = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(big, from: big.extent)
    }
}
