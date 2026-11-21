import SwiftUI

/// What the smart-glasses display will show for the current step: a 640x480 green-on-black
/// frame (new pieces bright, earlier pieces as outlines) plus the parts as text.
/// Until we have the glasses, this runs on the phone (sheet) or the Mac (separate window).
struct GlassesPreview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.xs) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Glasses preview")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("640×480 display")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: Theme.Spacing.xs)
                StatusChip(
                    symbol: "eyeglasses",
                    text: app.glassesConnected ? "Linked" : "Not linked",
                    tint: app.glassesConnected ? Theme.Palette.green : Theme.Palette.textSecondary
                )
            }

            display
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .buildLensTheme()
        #if os(iOS)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Palette.canvas)
        #endif
    }

    /// The display itself. It stays green on black whatever the app's theme: it mimics a
    /// monochrome waveguide.
    private var display: some View {
        ZStack {
            Color.black
            if let model = app.model, let url = model.glassesFrameURL(step: app.step),
               let image = ImageCache.shared.image(at: url), !app.showingFinished {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
            GeometryReader { proxy in
                // Text is sized in the display's own 640-wide coordinates, so the preview
                // keeps the proportions of the real frame at any size.
                overlay(scale: proxy.size.width / Theme.Size.glassesDisplayWidth)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(Theme.shape(Theme.Radius.tile))
        .overlay {
            Theme.shape(Theme.Radius.tile)
                .strokeBorder(Theme.Palette.hairline, lineWidth: Theme.Size.hairline)
        }
    }

    private func hudFont(_ size: CGFloat, weight: Font.Weight = .regular, scale: CGFloat) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    private func overlay(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs * scale) {
            if app.showingFinished {
                Label("DONE", systemImage: "checkmark")
                    .font(hudFont(40, weight: .bold, scale: scale))
            } else {
                Text("STEP \(app.step + 1)/\(app.stepCount)")
                    .font(hudFont(36, weight: .bold, scale: scale))
                if let step = app.currentStep {
                    if step.isSubAssembly {
                        Text("SUB: \(step.assembly.name.uppercased())\(step.assembly.uses > 1 ? " ×\(step.assembly.uses)" : "")")
                            .font(hudFont(22, weight: .semibold, scale: scale))
                    }
                    Spacer(minLength: 0)
                    ForEach(step.parts.prefix(4)) { line in
                        Text("+\(line.count) \(line.colourName.uppercased()) \(line.name.uppercased())")
                            .font(hudFont(22, scale: scale))
                            .lineLimit(1)
                    }
                    if step.parts.count > 4 {
                        Text("+\(step.parts.count - 4) MORE")
                            .font(hudFont(22, scale: scale))
                    }
                }
            }
        }
        .foregroundStyle(Theme.Palette.hud)
        .shadow(color: .black, radius: Theme.Spacing.xxs * scale)
        .padding(Theme.Spacing.xl * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
