#if os(iOS)
import Vision
import CoreVideo
import CoreGraphics

/// Reads text in a camera frame and looks for the set number.
enum SetNumberReader {
    /// Returns the centre of the matching text in the upright (portrait) image,
    /// normalised with the origin at the top-left, or nil if the number isn't visible.
    static func find(_ number: String, in buffer: CVPixelBuffer) -> CGPoint? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                let digits = candidate.string.filter(\.isNumber)
                if digits.contains(number) {
                    let box = observation.boundingBox
                    return CGPoint(x: box.midX, y: 1 - box.midY)
                }
            }
        }
        return nil
    }
}
#endif
