import SwiftUI

/// What the smart-glasses display will show for the current step: a 640x480 green-on-black
/// frame (new pieces bright, earlier pieces as outlines) plus the parts as text.
/// Until we have the glasses, this runs on the phone (sheet) or the Mac (separate window).
struct GlassesPreview: View {
    @Environment(AppModel.self) private var app
    private let hudGreen = Color(red: 0.36, green: 1.0, blue: 0.5)

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                Color.black
                if let model = app.model, let url = model.glassesFrameURL(step: app.step),
                   let image = ImageCache.shared.image(at: url), !app.showingFinished {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                }
                overlay
                    .padding(14)
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.4)))

            Text("Glasses preview · 640×480 · same frames the glasses app will show")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            if app.showingFinished {
                Text("DONE ✓")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
            } else {
                Text("STEP \(app.step + 1)/\(app.stepCount)")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                if let step = app.currentStep {
                    if step.isSubAssembly {
                        Text("SUB: \(step.assembly.name.uppercased())\(step.assembly.uses > 1 ? " ×\(step.assembly.uses)" : "")")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    Spacer(minLength: 0)
                    ForEach(step.parts.prefix(4)) { line in
                        Text("+\(line.count) \(line.colourName.uppercased()) \(line.name.uppercased())")
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                    }
                    if step.parts.count > 4 {
                        Text("+\(step.parts.count - 4) MORE")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
        .foregroundStyle(hudGreen)
        .shadow(color: .black, radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
