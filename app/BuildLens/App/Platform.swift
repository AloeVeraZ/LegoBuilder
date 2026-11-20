import SwiftUI
import simd
#if os(iOS)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Small in-memory cache for the bundled thumbnails and glasses frames.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var cache: [URL: PlatformImage] = [:]

    func image(at url: URL) -> PlatformImage? {
        if let hit = cache[url] { return hit }
        #if os(iOS)
        let image = UIImage(contentsOfFile: url.path)
        #else
        let image = NSImage(contentsOf: url)
        #endif
        if let image { cache[url] = image }
        return image
    }
}

extension simd_float4x4 {
    /// Builds a matrix from 16 column-major floats (the layout build.json uses).
    init(columnMajor m: [Float]) {
        precondition(m.count == 16, "matrix needs 16 values")
        self.init(columns: (
            SIMD4(m[0], m[1], m[2], m[3]),
            SIMD4(m[4], m[5], m[6], m[7]),
            SIMD4(m[8], m[9], m[10], m[11]),
            SIMD4(m[12], m[13], m[14], m[15])
        ))
    }

    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }

    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4(p.x, p.y, p.z, 1)
        return SIMD3(r.x, r.y, r.z)
    }
}

enum Haptics {
    @MainActor static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    @MainActor static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
