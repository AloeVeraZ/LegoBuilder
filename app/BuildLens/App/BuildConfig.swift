import CoreGraphics

/// Everything specific to the set we demo. Change these when the model changes.
enum BuildConfig {
    /// Number printed on the box and on the instruction booklet. The scanner reads text
    /// through the camera and starts only when it sees exactly this number; no other set works.
    static let setNumber = "42233"

    /// Optional: add a straight-on photo of the box front to the app as `BoxFront.jpg`
    /// (any folder inside BuildLens/) and ARKit will also recognise the box artwork.
    static let boxImageName = "BoxFront"

    /// Real width of the area shown in BoxFront.jpg, in metres. Measure your box.
    static let boxImageWidthMeters: CGFloat = 0.19

    /// In AR the finished model is shown about this long, in metres: far bigger than the
    /// real thing (which is under 7 cm), so every piece is easy to see from where you stand.
    /// Pinch changes it afterwards.
    static let arTargetSize: Float = 0.6

    /// Rough minutes per step, for the "about N minutes" estimate.
    static let minutesPerStep: Double = 0.6
}
