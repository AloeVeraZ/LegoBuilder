import SwiftUI

/// A round coloured mark with a symbol, at the top of a message card.
private struct CardMark: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.semibold))
            .foregroundStyle(Theme.Palette.ink)
            .frame(width: Theme.Size.control, height: Theme.Size.control)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Shown while the camera looks for the box: a status pill, not instructions.
struct ScanHint: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "camera.viewfinder")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.Palette.ink)
                // The pill is 2 x xs taller than this circle, so the two curves are concentric.
                .frame(width: Theme.Size.control - 2 * Theme.Spacing.xs, height: Theme.Size.control - 2 * Theme.Spacing.xs)
                .background(Theme.Palette.red, in: Circle())
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            Text("Looking for set \(BuildConfig.setNumber)")
                .font(Theme.Typography.headline)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.leading, Theme.Spacing.xs)
        .padding(.trailing, Theme.Spacing.lg)
        .frame(minHeight: Theme.Size.control)
        .glassSurface(Capsule())
    }
}

/// Shown when the box was found and the finished model popped up.
struct RevealCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let model = app.model {
                StatusChip(
                    symbol: app.foundByScan ? "checkmark.seal.fill" : "hand.tap.fill",
                    text: app.foundByScan ? "Set found" : "Model placed",
                    tint: Theme.Palette.green
                )
                VStack(spacing: Theme.Spacing.xxs) {
                    Text(model.name)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("\(model.pieceCount) pieces · \(model.steps.count) steps · about \(model.estimatedMinutes) min")
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .multilineTextAlignment(.center)

                Button {
                    app.startBuilding()
                } label: {
                    PillLabel(title: "Start building", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .frame(maxWidth: .infinity)
        .floatingCard()
    }
}

/// A moment of "well done" when one part of the build is finished and the next begins.
struct MilestoneCard: View {
    let milestone: AppModel.Milestone

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            CardMark(symbol: "checkmark", tint: Theme.Palette.green)
            VStack(spacing: Theme.Spacing.xxs) {
                Text(milestone.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(milestone.detail)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .floatingCard()
        .accessibilityElement(children: .combine)
    }
}

/// A burst of brick-coloured confetti from the bottom of the screen when the build is done.
/// Drawn in one canvas; it stops updating once every piece has fallen out of view.
struct ConfettiBurst: View {
    private struct Piece {
        let angle, speed, spin, size, delay: Double
        let colour: Color
    }

    private static let colours = [Theme.Palette.yellow, Theme.Palette.blue, Theme.Palette.green, Theme.Palette.red, Color.white]
    private static let life = 3.6
    private let pieces: [Piece] = (0 ..< 110).map { n in
        // Fixed pseudo-random spread, so the burst looks the same each time and costs nothing to set up.
        func unit(_ salt: Double) -> Double {
            let x = sin(Double(n) * 12.9898 + salt * 78.233) * 43758.5453
            return x - x.rounded(.down)
        }
        return Piece(angle: -.pi / 2 + (unit(1) - 0.5) * 1.5, speed: 620 + unit(2) * 520, spin: (unit(3) - 0.5) * 14,
                     size: 6 + unit(4) * 7, delay: unit(5) * 0.25, colour: colours[n % colours.count])
    }
    @State private var start = Date()
    @State private var over = false

    var body: some View {
        if !over { burst }
    }

    /// Redraws every frame only while there is confetti in the air, then removes itself.
    private var burst: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard elapsed < Self.life else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.92)
                for piece in pieces {
                    let t = elapsed - piece.delay
                    guard t > 0 else { continue }
                    // Thrown up and out, slowed by the air, pulled down by gravity.
                    let drag = (1 - exp(-1.6 * t)) / 1.6
                    let x = origin.x + cos(piece.angle) * piece.speed * drag
                    let y = origin.y + sin(piece.angle) * piece.speed * drag + 420 * t * t
                    guard y < size.height + 20 else { continue }
                    var mark = context
                    mark.opacity = min(1, (Self.life - elapsed) * 1.5)
                    mark.translateBy(x: x, y: y)
                    mark.rotate(by: .radians(piece.spin * t))
                    // Narrowing and widening reads as the piece tumbling.
                    let width = piece.size * abs(cos(piece.spin * t * 0.7)) + 1.5
                    mark.fill(Path(CGRect(x: -width / 2, y: -piece.size / 2, width: width, height: piece.size * 0.6)),
                              with: .color(piece.colour))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            start = Date()
            try? await Task.sleep(nanoseconds: UInt64(Self.life * 1_000_000_000))
            over = true
        }
    }
}

/// Shown after the last step.
struct FinishedCard: View {
    @Environment(AppModel.self) private var app
    /// Leaves the instructions. The finished truck stays on the glasses.
    var onExit: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            CardMark(symbol: "flag.checkered", tint: Theme.Palette.green)
            VStack(spacing: Theme.Spacing.xxs) {
                Text("You built it!")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let model = app.model {
                    Text(model.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .multilineTextAlignment(.center)

            VStack(spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Button {
                        app.back()
                    } label: {
                        Label("Last step", systemImage: "chevron.left")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))

                    Button {
                        app.restart()
                    } label: {
                        Label("Build again", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                if let onExit {
                    Button(action: onExit) {
                        PillLabel(title: "Exit", systemImage: "checkmark")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .floatingCard()
    }
}
