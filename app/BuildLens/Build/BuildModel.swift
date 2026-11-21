import Foundation
import simd

/// The JSON written by pipeline/ldraw2build.py (format "buildlens.build/1").
struct BuildPackage: Decodable {
    struct SetInfo: Decodable {
        let id: String
        let name: String
        let theme: String
        let pieces: Int
    }

    struct Colour: Decodable {
        let code: Int
        let name: String
        let rgba: [Float]
        let finish: String
    }

    struct Group: Decodable {
        let colour: Int        // 16 = "use the piece's own colour"
        let vertexCount: Int
        let indexCount: Int
        let positions: Int     // byte offsets into geometry.bin
        let normals: Int
        let indices: Int
    }

    struct Part: Decodable {
        let key: String
        let number: String
        let name: String
        let mirrored: Bool
        let bounds: [[Float]]
        let groups: [Group]
    }

    struct Instance: Decodable {
        let part: Int
        let colour: Int
        let matrix: [Float]    // column-major, metres, +Y up
    }

    struct Assembly: Decodable {
        let id: Int
        let name: String
        let parent: Int
        let uses: Int
        let matrix: [Float]
        let bounds: [[Float]]
    }

    struct Step: Decodable {
        let assembly: Int
        let added: [Int]
        /// How the new pieces are pushed home (missing in packages made before this existed).
        let moves: [Move]?
        /// Which of the four sides the step is looked at from (see `BuildModel.viewYaws`).
        let view: Int?
    }

    /// Pieces that go on together, and the direction they are pushed, in the shown
    /// assembly's own axes (+Y up). Always square to the model.
    struct Move: Decodable {
        let pieces: [Int]
        let push: [Float]
        /// Moves with the same order happen together; lower orders first.
        let order: Int?
        /// The pieces are simply there waiting instead of gliding in.
        let still: Bool?
        /// How far off their place the pieces wait, in metres, when it differs from the usual.
        let gap: Float?
    }

    let setInfo: SetInfo
    let geometry: String
    let colours: [Colour]
    let parts: [Part]
    let instances: [Instance]
    let assemblies: [Assembly]
    let steps: [Step]

    enum CodingKeys: String, CodingKey {
        case setInfo = "set"
        case geometry, colours, parts, instances, assemblies, steps
    }
}

enum BuildModelError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "\(name) is missing from the app bundle. Run pipeline/make_package.sh and rebuild."
        }
    }
}

/// A loaded build: the package plus everything the app derives from it.
final class BuildModel {
    struct PartLine: Identifiable, Hashable {
        let part: Int
        let colour: Int
        let count: Int
        let name: String
        let colourName: String
        var id: String { "\(part)-\(colour)" }
    }

    struct StepInfo {
        let index: Int
        let assembly: BuildPackage.Assembly
        let added: [Int]
        let moves: [BuildPackage.Move]
        /// The side this step is looked at from: 0 front-right, 1 front-left, 2 back-right, 3 back-left.
        let view: Int
        /// Sub-builds that go onto the model in this step. When there are any, the step is
        /// "attach what you just built", not "add these loose pieces".
        let attaches: [BuildPackage.Assembly]
        /// Everything on screen for this step (pieces added so far in the same assembly).
        let visible: [Int]
        let parts: [PartLine]
        var isSubAssembly: Bool { assembly.id != 0 }
    }

    let package: BuildPackage
    let geometry: Data
    let instanceMatrices: [simd_float4x4]
    let assemblyMatrices: [simd_float4x4]
    private(set) var steps: [StepInfo] = []
    private let coloursByCode: [Int: BuildPackage.Colour]
    private let bundle: Bundle

    var name: String { package.setInfo.name }
    var pieceCount: Int { package.setInfo.pieces }
    var finishedBounds: (min: SIMD3<Float>, max: SIMD3<Float>) { Self.bounds(package.assemblies[0].bounds) }

    init(package: BuildPackage, geometry: Data, bundle: Bundle) {
        self.package = package
        self.geometry = geometry
        self.bundle = bundle
        instanceMatrices = package.instances.map { simd_float4x4(columnMajor: $0.matrix) }
        assemblyMatrices = package.assemblies.map { simd_float4x4(columnMajor: $0.matrix) }
        coloursByCode = Dictionary(package.colours.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

        // The pieces each sub-build is made of, from its own steps.
        var builtInSub: [Int: Set<Int>] = [:]
        for step in package.steps where step.assembly != 0 {
            builtInSub[step.assembly, default: []].formUnion(step.added)
        }
        var visibleByAssembly: [Int: [Int]] = [:]
        var built: [StepInfo] = []
        for (index, step) in package.steps.enumerated() {
            var visible = visibleByAssembly[step.assembly] ?? []
            visible.append(contentsOf: step.added)
            visibleByAssembly[step.assembly] = visible
            // A step that brings in every piece of a sub-build is attaching that sub-build.
            let added = Set(step.added)
            let attaches = builtInSub.keys.sorted()
                .filter { $0 != step.assembly && builtInSub[$0]!.isSubset(of: added) }
                .map { package.assemblies[$0] }
            var loose = added
            for sub in attaches {
                // All copies of the sub-build come in together; none of their pieces are loose.
                let size = builtInSub[sub.id]!.count * max(sub.uses, 1)
                loose = size >= added.count ? [] : loose.subtracting(builtInSub[sub.id]!)
            }
            built.append(StepInfo(
                index: index,
                assembly: package.assemblies[step.assembly],
                added: step.added,
                moves: step.moves ?? [],
                view: min(max(step.view ?? 0, 0), 3),
                attaches: attaches,
                visible: visible,
                parts: partLines(for: step.added.filter(loose.contains))
            ))
        }
        steps = built
    }

    static func loadBundled(bundle: Bundle = .main) throws -> BuildModel {
        guard let jsonURL = resource("build", "json", in: bundle) else {
            throw BuildModelError.missingResource("build.json")
        }
        let package = try JSONDecoder().decode(BuildPackage.self, from: Data(contentsOf: jsonURL))
        let geoName = (package.geometry as NSString).deletingPathExtension
        let geoExt = (package.geometry as NSString).pathExtension
        guard let geoURL = resource(geoName, geoExt, in: bundle) else {
            throw BuildModelError.missingResource(package.geometry)
        }
        let geometry = try Data(contentsOf: geoURL, options: .mappedIfSafe)
        return BuildModel(package: package, geometry: geometry, bundle: bundle)
    }

    /// Xcode may copy the BuildData folder flat or keep sub-folders, so look in both.
    static func resource(_ name: String, _ ext: String, in bundle: Bundle) -> URL? {
        let folders: [String?] = [nil, "BuildData", "thumbs", "hud", "BuildData/thumbs", "BuildData/hud",
                                  "Resources/BuildData", "Resources/BuildData/thumbs", "Resources/BuildData/hud"]
        for dir in folders {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: dir) { return url }
        }
        return nil
    }

    // MARK: geometry access

    func floats(at offset: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            _ = geometry.copyBytes(to: buffer, from: offset ..< offset + count * MemoryLayout<Float>.size)
        }
        return out
    }

    func vectors(at offset: Int, count: Int) -> [SIMD3<Float>] {
        let f = floats(at: offset, count: count * 3)
        var out = [SIMD3<Float>]()
        out.reserveCapacity(count)
        for i in 0 ..< count {
            out.append(SIMD3(f[3 * i], f[3 * i + 1], f[3 * i + 2]))
        }
        return out
    }

    func indices(at offset: Int, count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            _ = geometry.copyBytes(to: buffer, from: offset ..< offset + count * MemoryLayout<UInt32>.size)
        }
        return out
    }

    // MARK: lookups

    func colour(_ code: Int) -> BuildPackage.Colour {
        coloursByCode[code] ?? BuildPackage.Colour(code: code, name: "Colour \(code)", rgba: [0.6, 0.6, 0.6, 1], finish: "plastic")
    }

    func partName(_ index: Int) -> String {
        Self.cleanName(package.parts[index].name)
    }

    static func cleanName(_ raw: String) -> String {
        var s = raw
        while let first = s.first, "~_=|".contains(first) { s.removeFirst() }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func bounds(_ b: [[Float]]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        (SIMD3(b[0][0], b[0][1], b[0][2]), SIMD3(b[1][0], b[1][1], b[1][2]))
    }

    func thumbnailURL(part: Int, colour: Int) -> URL? {
        Self.resource("thumb-\(part)-\(colour)", "png", in: bundle)
    }

    /// The camera's angle round the model for each of the four views (0 = straight in
    /// front, positive = towards the right). The same numbers are in pipeline/render.
    static let viewYaws: [Float] = [0.65, -0.65, .pi - 0.65, -(.pi - 0.65)]

    /// The view whose angle is nearest to `yaw`.
    static func view(nearest yaw: Float) -> Int {
        func gap(_ a: Float, _ b: Float) -> Float { abs(atan2(sin(a - b), cos(a - b))) }
        return viewYaws.indices.min { gap(viewYaws[$0], yaw) < gap(viewYaws[$1], yaw) } ?? 0
    }

    /// The glasses frames of a step from one of the four sides: the piece waiting with its
    /// arrow (""), the arrow at the bottom of its bounce ("-w"), part-way in ("-a"), seated ("-b").
    func glassesFrameURL(step: Int, view: Int, variant: String = "") -> URL? {
        Self.resource(String(format: "hud-step-%03d-q%d", step + 1, view) + variant, "png", in: bundle)
    }

    /// The finished step turning towards the next step's side, frames 1...4. Only exists
    /// where the next step is looked at from another side.
    func glassesTurnURL(step: Int, frame: Int) -> URL? {
        Self.resource(String(format: "hud-step-%03d-r%d", step + 1, frame), "png", in: bundle)
    }

    /// The finished model turning once round, frames 1...24 (24 is back where it began).
    static let glassesFinishFrames = 24
    func glassesFinishURL(frame: Int) -> URL? {
        Self.resource(String(format: "hud-finish-%02d", frame), "png", in: bundle)
    }

    var heroImageURL: URL? { Self.resource("build-hero", "png", in: bundle) }

    var estimatedMinutes: Int { max(1, Int((Double(steps.count) * BuildConfig.minutesPerStep).rounded())) }

    private func partLines(for ids: [Int]) -> [PartLine] {
        var counts: [String: (part: Int, colour: Int, count: Int)] = [:]
        var order: [String] = []
        for id in ids {
            let inst = package.instances[id]
            let key = "\(inst.part)-\(inst.colour)"
            if let existing = counts[key] {
                counts[key] = (existing.part, existing.colour, existing.count + 1)
            } else {
                counts[key] = (inst.part, inst.colour, 1)
                order.append(key)
            }
        }
        return order.compactMap { counts[$0] }.map { entry in
            PartLine(part: entry.part, colour: entry.colour, count: entry.count,
                     name: partName(entry.part), colourName: colour(entry.colour).name)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// What the app says when "read steps aloud" is on.
    func spokenSummary(for index: Int) -> String {
        guard index >= 0, index < steps.count else { return "" }
        let step = steps[index]
        var text = "Step \(index + 1) of \(steps.count). "
        if step.isSubAssembly {
            text += "Build the \(step.assembly.name)"
            text += step.assembly.uses > 1 ? ", you need \(step.assembly.uses) of these. " : ". "
        }
        for sub in step.attaches {
            text += sub.uses > 1 ? "Attach both \(sub.name) sub-builds. " : "Attach the \(sub.name). "
        }
        let lines = step.parts.prefix(4).map { line -> String in
            let name = line.name.replacingOccurrences(of: " x ", with: " by ")
            return "\(line.count) \(line.colourName.lowercased()) \(name.lowercased())"
        }
        if !lines.isEmpty { text += "Add " + lines.joined(separator: ", ") + "." }
        if step.parts.count > 4 { text += " And \(step.parts.count - 4) more." }
        return text
    }
}
