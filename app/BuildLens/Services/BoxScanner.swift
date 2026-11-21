import AVFoundation
import CoreImage
import Observation
import Vision

/// The first thing the app does: finds the set's box in the camera picture, by its barcode,
/// its item number or its set number (BuildConfig). The phone uses its back camera, the Mac
/// its own camera.
@MainActor
@Observable
final class BoxScanner: NSObject {
    enum State: Equatable { case off, starting, noCamera, looking, found }

    private(set) var state: State = .off
    /// The latest camera picture, upright.
    private(set) var image: CGImage?

    @ObservationIgnored private let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "buildlens.box")
    @ObservationIgnored private let context = CIContext()
    @ObservationIgnored private var configured = false
    /// Text is slower to read than barcodes, so it is read on every third picture only.
    @ObservationIgnored nonisolated(unsafe) private var frame = 0

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
        if state != .found { state = .off }
        image = nil
    }

    private func configure() -> Bool {
        if configured { return true }
        #if os(iOS)
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        #else
        let camera = AVCaptureDevice.default(for: .video)
        #endif
        guard let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return false }
        session.beginConfiguration()
        // Small pictures are read fastest; the barcode only needs a few pixels a bar.
        session.sessionPreset = .hd1280x720
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        #if os(iOS)
        // Upright pictures on a phone held upright.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        #endif
        session.commitConfiguration()
        configured = true
        return true
    }

    private func took(_ picture: CGImage?, found: Bool) {
        guard state == .looking else { return }
        image = picture
        if found {
            state = .found
            queue.async { [session] in session.stopRunning() }
        }
    }
}

extension BoxScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.ean13, .upce, .ean8, .code128, .dataMatrix, .qr]
        var requests: [VNRequest] = [barcodes]
        frame += 1
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        if frame % 3 == 0 { requests.append(text) }
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform(requests)
        var found = barcodes.results?.contains { BuildConfig.isThisSet(barcode: $0.payloadStringValue ?? "") } ?? false
        if !found, frame % 3 == 0 {
            found = text.results?.contains { $0.topCandidates(2).contains { BuildConfig.namesThisSet(text: $0.string) } } ?? false
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let picture = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height))
        Task { @MainActor in self.took(picture, found: found) }
    }
}
