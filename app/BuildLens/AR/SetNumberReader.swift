#if os(iOS)
import Vision
import CoreVideo
import CoreGraphics

/// Reads text in a camera frame and looks for the one set number the app has instructions for.
enum SetNumberReader {
    /// Returns the centre of the matching text in the upright (portrait) image,
    /// normalised with the origin at the top-left, or nil if the number isn't visible.
    static func find(_ number: String, in buffer: CVPixelBuffer) -> CGPoint? {
        // The box's barcode counts too (BuildConfig), as at the start: the side of the box
        // with the barcode doesn't have the set number on it.
        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.ean13, .upce, .ean8]
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        do {
            try handler.perform([barcodes, request])
        } catch {
            return nil
        }
        if let code = barcodes.results?.first(where: { BuildConfig.isThisSet(barcode: $0.payloadStringValue ?? "") }) {
            let box = code.boundingBox
            return CGPoint(x: box.midX, y: 1 - box.midY)
        }
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                // The number has to stand on its own, the way it is printed on the box. A longer
                // run of digits that merely contains it (a barcode, another set's number) is not it.
                let runs = candidate.string.split(whereSeparator: { !$0.isNumber })
                if runs.contains(where: { $0 == number || $0 == BuildConfig.itemNumber }) {
                    let box = observation.boundingBox
                    return CGPoint(x: box.midX, y: 1 - box.midY)
                }
            }
        }
        return nil
    }
}
#endif
