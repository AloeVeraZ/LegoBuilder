import SwiftUI

/// What the smart-glasses display will show for the current step: a 640x480 green-on-black
/// frame (new pieces bright, earlier pieces as outlines) plus the parts as text.
/// Until we have the glasses, this runs on the phone (sheet) or the Mac (separate window).
struct GlassesPreview: View {
    @Environment(AppModel.self) private var app
    /// Which picture is up right now.
    @State private var frame = (step: 0, view: 0, variant: "")
    /// The step the display last settled on, to know when we moved forward by one.
    @State private var settledStep = -1

    /// The side the display last settled on, for the slot-in frames of the step being left.
    @State private var settledView = 0

    private struct Playing: Hashable {
        let step: Int
        let finished: Bool
        let view: Int
        let milestone: Bool
    }

    /// The same timing as the glasses app (glasses/.../MainActivity.java).
    private func play() async {
        let step = app.step
        let view = app.glassesView
        let pause = { (seconds: Double) in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        if app.showingFinished || app.milestone != nil {
            // The last piece slots in and the finished picture stays up.
            let from = settledStep == step ? settledView : view
            frame = (step, from, "-a")
            await pause(0.22)
            guard !Task.isCancelled else { return }
            frame = (step, from, "-b")
            if app.showingFinished { settledStep = -1 }
            return
        }
        if settledStep >= 0, step == settledStep + 1 {
            let before = settledStep
            frame = (before, settledView, "-a")
            await pause(0.11)
            guard !Task.isCancelled else { return }
            frame = (before, settledView, "-b")
            await pause(0.32)
            guard !Task.isCancelled else { return }
            // Where the new step is seen from another side, the finished step turns round to it.
            if let model = app.model, settledView == model.steps[before].view, view != settledView {
                for n in 1 ... 4 where model.glassesTurnURL(step: before, frame: n) != nil {
                    frame = (before, 0, "r\(n)")
                    await pause(0.09)
                    guard !Task.isCancelled else { return }
                }
            }
        }
        settledStep = step
        settledView = view
        var pressed = false
        while !Task.isCancelled {
            frame = (step, view, pressed ? "-w" : "")
            pressed.toggle()
            await pause(0.45)
        }
    }

    private var frameURL: URL? {
        guard let model = app.model else { return nil }
        if frame.variant.hasPrefix("r"), let n = Int(frame.variant.dropFirst()) {
            return model.glassesTurnURL(step: frame.step, frame: n)
        }
        return model.glassesFrameURL(step: frame.step, view: frame.view, variant: frame.variant)
    }

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
                // Only the phone links to the glasses; on the Mac this window is the stand-in.
                #if os(iOS)
                StatusChip(
                    symbol: "eyeglasses",
                    text: app.glassesConnected ? "Linked" : "Not linked",
                    tint: app.glassesConnected ? Theme.Palette.green : Theme.Palette.textSecondary
                )
                #endif
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
            if let url = frameURL, let image = ImageCache.shared.image(at: url) {
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
        // Restarts whenever the step (or finished state) changes, and plays what the real
        // glasses play: the last piece slots in, then the new one waits with a bouncing arrow.
        .task(id: Playing(step: app.step, finished: app.showingFinished, view: app.glassesView,
                          milestone: app.milestone != nil)) { await play() }
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
            } else if let milestone = app.milestone {
                Text(milestone.title.uppercased())
                    .font(hudFont(36, weight: .bold, scale: scale))
                Text(milestone.detail.uppercased())
                    .font(hudFont(22, weight: .semibold, scale: scale))
            } else {
                Text("STEP \(app.step + 1)/\(app.stepCount)")
                    .font(hudFont(36, weight: .bold, scale: scale))
                if let step = app.currentStep {
                    Text(step.isSubAssembly
                         ? "SUB: \(step.assembly.name.uppercased())\(step.assembly.uses > 1 ? " ×\(step.assembly.uses)" : "")"
                         : "MAIN BUILD")
                        .font(hudFont(22, weight: .semibold, scale: scale))
                    Spacer(minLength: 0)
                    ForEach(step.attaches, id: \.id) { sub in
                        Text("ATTACH \(sub.uses > 1 ? "\(sub.uses)x" : "THE") \(sub.name.uppercased())")
                            .font(hudFont(22, scale: scale))
                            .lineLimit(1)
                    }
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
