import CoreGraphics

/// Everything specific to the set we demo. Change these when the model changes.
enum BuildConfig {
    /// Number printed on the box and on the instruction booklet. The scanner reads text
    /// through the camera and starts only when it sees exactly this number; no other set works.
    static let setNumber = "42233"

    /// The barcode on the box (printed 6 73419 42442 4: UPC-A, or the same as EAN-13 with a
    /// leading 0) and the LEGO item number printed above it. Any of these, or the set number,
    /// counts as this set when the box is scanned at the start (BoxScanView, and the glasses).
    static let boxBarcodes: Set<String> = ["673419424424", "0673419424424"]
    static let itemNumber = "6588582"

    /// True if a scanned barcode is this set's box.
    static func isThisSet(barcode: String) -> Bool {
        boxBarcodes.contains(barcode.filter(\.isNumber))
    }

    /// True if read text names this set: the set or item number standing on its own.
    static func namesThisSet(text: String) -> Bool {
        text.split(whereSeparator: { !$0.isNumber }).contains { $0 == setNumber || $0 == itemNumber }
    }

    /// Optional: add a straight-on photo of the box front to the app as `BoxFront.jpg`
    /// (any folder inside BuildLens/) and ARKit will also recognise the box artwork.
    static let boxImageName = "BoxFront"

    /// Real width of the area shown in BoxFront.jpg, in metres. Measure your box.
    static let boxImageWidthMeters: CGFloat = 0.19


    /// Rough minutes per step, for the "about N minutes" estimate.
    static let minutesPerStep: Double = 0.6
}
