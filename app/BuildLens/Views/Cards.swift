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

/// Shown after the last step.
struct FinishedCard: View {
    @Environment(AppModel.self) private var app

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
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .frame(maxWidth: .infinity)
        .floatingCard()
    }
}
