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

    /// Live: the camera's picture with the step drawn onto the real table.
    @State private var live = false
    @State private var tracker = MarkerTracker()
    #if os(macOS)
    /// The real glasses' camera, while they are plugged into this Mac.
    @State private var glasses = GlassesFeed()
    #endif

    /// True while the live view shows the plugged-in glasses' camera.
    private var glassesLive: Bool {
        #if os(macOS)
        return live && glasses.plugged
        #else
        return false
        #endif
    }

    /// The live view's camera: the plugged-in glasses', else this device's own.
    private var liveCamera: any LiveCamera {
        #if os(macOS)
        if glasses.plugged { return glasses }
        #endif
        return tracker
    }

    /// Only the Mac's own camera needs starting; the glasses' runs on the glasses.
    private func updateTracker() {
        if live && !glassesLive { tracker.start() } else { tracker.stop() }
    }

    /// When the confetti went off (nil = none).
    @State private var confetti: Date?

    private struct Playing: Hashable {
        let step: Int
        let finished: Bool
        let view: Int
        let milestone: Bool
        let seating: Bool
    }

    /// The step whose piece the display already shows in place.
    @State private var seatedStep = -1

    /// The waiting piece goes into its place over four pictures: the same half second as
    /// the phone's own animation (and the glasses app, glasses/.../MainActivity.java).
    private func slotIn(_ step: Int, view: Int) async {
        guard seatedStep != step else { frame = (step, view, "-b"); return }
        seatedStep = step
        for variant in ["-c", "-a", "-d", "-b"] {
            frame = (step, view, variant)
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
        }
    }

    private func play() async {
        let step = app.step
        let view = app.glassesView
        let pause = { (seconds: Double) in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        if app.showingFinished || app.isSeating {
            // The piece clicks in as it does on the phone; the words follow once it is in.
            let from = settledStep == step ? settledView : view
            await slotIn(step, view: from)
            guard !Task.isCancelled, app.showingFinished else { return }
            settledStep = -1
            // The finish, as on the glasses: the truck spins twice, fast then slowing to a
            // stop where it began, and confetti goes off.
            let count = BuildModel.glassesFinishFrames
            guard app.model?.glassesFinishURL(frame: count) != nil else { return }
            let total = count * 2
            var elapsed = 0.0
            for k in 1 ... total {
                let at = 2.8 * (1 - pow(1 - Double(k) / Double(total), 0.25))
                await pause(at - elapsed)
                elapsed = at
                guard !Task.isCancelled else { return }
                frame = (step, from, "f\((k - 1) % count + 1)")
            }
            frame = (step, from, "-b")
            confetti = Date()
            return
        }
        confetti = nil
        if settledStep >= 0, step == settledStep + 1 {
            let before = settledStep
            let wasSeated = seatedStep == before
            await slotIn(before, view: settledView)
            guard !Task.isCancelled else { return }
            if !wasSeated { await pause(0.18) }
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
        seatedStep = -1
        var pressed = false
        while !Task.isCancelled {
            frame = (step, view, pressed ? "-w" : "")
            pressed.toggle()
            await pause(0.45)
        }
    }

    private var frameURL: URL? {
        guard let model = app.model else { return nil }
        if frame.variant.hasPrefix("f"), let n = Int(frame.variant.dropFirst()) {
            return model.glassesFinishURL(frame: n)
        }
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
                #if os(macOS)
                StatusChip(symbol: "cable.connector", text: glasses.plugged ? "Glasses plugged in" : "No glasses",
                           tint: glasses.plugged ? Theme.Palette.green : Theme.Palette.textSecondary)
                StatusChip(symbol: "iphone", text: app.syncPeers.isEmpty ? "No phone" : "Phone linked",
                           tint: app.syncPeers.isEmpty ? Theme.Palette.textSecondary : Theme.Palette.green)
                // The plugged-in glasses' camera, or the Mac's standing in for it.
                Button {
                    live.toggle()
                } label: {
                    Label("Live", systemImage: live ? "video.fill" : "video")
                }
                .buttonStyle(PillButtonStyle(kind: live ? .primary : .secondary, height: Theme.Size.hitTarget))
                .fixedSize()
                .accessibilityLabel(live ? "Stop live view" : "Live view")
                #endif
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
            if live {
                AssistView(tracker: liveCamera)
            } else if let url = frameURL, let image = ImageCache.shared.image(at: url) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
            if let confetti {
                HUDConfetti(start: confetti)
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
                          milestone: app.milestone != nil, seating: app.isSeating)) { await play() }
        .onChange(of: live) { updateTracker() }
        #if os(macOS)
        // Plugging the glasses in brings their camera up straight away.
        .onChange(of: glasses.plugged) { _, plugged in
            if plugged { live = true }
            updateTracker()
        }
        .onAppear { glasses.start() }
        .onDisappear { glasses.stop() }
        #endif
        .onDisappear { tracker.stop(); live = false }
        .clipShape(Theme.shape(Theme.Radius.tile))
        .overlay {
            Theme.shape(Theme.Radius.tile)
                .strokeBorder(Theme.Palette.hairline, lineWidth: Theme.Size.hairline)
        }
    }

    private func hudFont(_ size: CGFloat, weight: Font.Weight = .regular, scale: CGFloat) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    /// The step the text shows: the plugged-in glasses' while their camera is up, else the app's.
    private var shownStepIndex: Int {
        #if os(macOS)
        if glassesLive { return glasses.step }
        #endif
        return app.step
    }

    private var shownFinished: Bool {
        #if os(macOS)
        if glassesLive { return glasses.finished }
        #endif
        return app.showingFinished
    }

    private func overlay(scale: CGFloat) -> some View {
        let steps = app.model?.steps ?? []
        let index = min(max(shownStepIndex, 0), max(steps.count - 1, 0))
        let current = steps.isEmpty ? nil : steps[index]
        let milestone = glassesLive ? nil : app.milestone
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs * scale) {
            if shownFinished {
                Label("DONE", systemImage: "checkmark")
                    .font(hudFont(40, weight: .bold, scale: scale))
            } else if let milestone {
                Text(milestone.title.uppercased())
                    .font(hudFont(36, weight: .bold, scale: scale))
                Text(milestone.detail.uppercased())
                    .font(hudFont(22, weight: .semibold, scale: scale))
            } else {
                Text("STEP \(index + 1)/\(app.stepCount)")
                    .font(hudFont(36, weight: .bold, scale: scale))
                if let step = current {
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

/// Confetti as the glasses draw it: one colour, bursting up from the bottom and falling.
/// The same numbers as ConfettiView in glasses/.../MainActivity.java.
private struct HUDConfetti: View {
    let start: Date
    private static let duration = 2.6

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                guard t < Self.duration else { return }
                var seed: UInt64 = 42
                func random() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 33) / Double(1 << 31)
                }
                let unit = size.width / 640
                for _ in 0 ..< 70 {
                    let x0 = 320 + (random() - 0.5) * 120, vx = (random() - 0.5) * 520
                    let vy = -(420 + random() * 420), spin = random() * 12, w = 6 + random() * 8
                    let x = x0 + vx * t, y = 500 + vy * t + 520 * t * t
                    let squash = abs(cos(spin * t))
                    let rect = CGRect(x: (x - w / 2) * unit, y: (y - w * squash / 2) * unit, width: w * unit, height: max(1.5, w * squash) * unit)
                    context.fill(Path(rect), with: .color(Theme.Palette.hud.opacity(min(1, (Self.duration - t) * 2))))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
