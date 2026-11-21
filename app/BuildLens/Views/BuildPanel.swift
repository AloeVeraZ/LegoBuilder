import SwiftUI

/// Bottom panel while building: which step this is, what to add, and the step controls.
struct BuildPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                StepHeader()
                Spacer(minLength: Theme.Spacing.xs)
                StatusChips()
            }

            if app.stepCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(app.step) },
                        set: { app.scrub(to: Int($0.rounded())) }
                    ),
                    in: 0 ... Double(app.stepCount - 1),
                    step: 1,
                    onEditingChanged: { dragging in
                        if !dragging { app.endScrub() }
                    }
                )
                .accessibilityLabel("Step")
                .accessibilityValue("\(app.step + 1) of \(app.stepCount)")
            }

            if let step = app.currentStep {
                PartsStrip(lines: step.parts, attaches: step.attaches)
            }

            controls
        }
        .padding(Theme.Spacing.md)
        .glassSurface(Theme.shape(Theme.Radius.panel))
        .frame(maxWidth: Theme.Size.panelWidth)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.stepChange), value: app.step)
    }

    private var isLastStep: Bool { app.step + 1 == app.stepCount }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button {
                app.back()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(CircleButtonStyle(surface: .muted, diameter: Theme.Size.control))
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(app.step == 0)
            .accessibilityLabel("Back")
            .help("Previous step")

            Button {
                app.replay()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(CircleButtonStyle(surface: .muted, diameter: Theme.Size.control))
            .keyboardShortcut("r", modifiers: [])
            .accessibilityLabel("Replay this step")
            .help("Replay this step")

            Button {
                app.next()
            } label: {
                PillLabel(title: isLastStep ? "Finish" : "Next", systemImage: isLastStep ? "checkmark" : "chevron.right")
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }
}

/// A finished sub-build as one tile in the parts strip: this step attaches it whole.
private struct SubBuildCell: View {
    let assembly: BuildPackage.Assembly

    var body: some View {
        Image(systemName: "square.on.square.dashed")
            .font(.title.weight(.semibold))
            .foregroundStyle(Theme.Palette.ink)
            .frame(width: Theme.Size.partTile, height: Theme.Size.partTile)
            .background(Theme.Palette.blue, in: Theme.shape(Theme.Radius.tile))
            .overlay(alignment: .bottomTrailing) {
                if assembly.uses > 1 {
                    Text("\(assembly.uses)×")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .frame(minHeight: Theme.Size.chip)
                        .background(Theme.Palette.yellow, in: Capsule())
                        .offset(x: Theme.Spacing.xxs, y: Theme.Spacing.xxs)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(assembly.uses > 1 ? "\(assembly.uses) \(assembly.name) sub-builds" : "\(assembly.name) sub-build")
    }
}

/// Thumbnails of the pieces for the current step, with counts.
struct PartsStrip: View {
    @Environment(AppModel.self) private var app
    let lines: [BuildModel.PartLine]
    /// Sub-builds that go on in this step, shown as one tile each instead of their pieces.
    var attaches: [BuildPackage.Assembly] = []
    @State private var selected: BuildModel.PartLine?

    private var pieceCount: Int { lines.reduce(0) { $0 + $1.count } }

    private var heading: String {
        guard let sub = attaches.first else { return pieceCount == 1 ? "Add 1 piece" : "Add \(pieceCount) pieces" }
        let what = sub.uses > 1 ? "Attach both sub-builds" : "Attach the sub-build"
        return pieceCount == 0 ? what : "\(what) + \(pieceCount) more"
    }

    /// The part whose name is spelled out under the strip: the one picked, else the first.
    private var described: BuildModel.PartLine? { selected ?? lines.first }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Always as tall as the chip, so the panel keeps its height from step to step.
            HStack(spacing: Theme.Spacing.xs) {
                Text(heading)
                    .eyebrowStyle()
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.Size.chip)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(attaches, id: \.id) { sub in
                        SubBuildCell(assembly: sub)
                    }
                    ForEach(lines) { line in
                        Button {
                            selected = line
                        } label: {
                            PartCell(line: line, isSelected: described == line)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                // Room for the count badges, which hang over the tile's corner.
                .padding(.trailing, Theme.Spacing.xxs)
                .padding(.bottom, Theme.Spacing.xxs)
            }
            .scrollClipDisabled()

            Group {
                if let line = described {
                    Text("\(line.count)× \(line.name) · \(line.colourName)")
                } else if let sub = attaches.first {
                    Text(sub.uses > 1 ? "\(sub.uses)× \(sub.name), the ones you just built" : "The \(sub.name) you just built")
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(1)
        }
        .sensoryFeedback(.selection, trigger: selected)
        .onChange(of: app.step) { _, _ in selected = nil }
    }
}

private struct PartCell: View {
    @Environment(AppModel.self) private var app
    let line: BuildModel.PartLine
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = app.model?.thumbnailURL(part: line.part, colour: line.colour),
                   let image = ImageCache.shared.image(at: url) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(Theme.Spacing.xxs)
                } else {
                    Image(systemName: "cube.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(Theme.Spacing.lg)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .frame(width: Theme.Size.partTile, height: Theme.Size.partTile)
            .background(Theme.Palette.studio, in: Theme.shape(Theme.Radius.tile))
            .overlay {
                Theme.shape(Theme.Radius.tile)
                    .strokeBorder(isSelected ? Theme.Palette.yellow : Color.clear, lineWidth: Theme.Size.selectionStroke)
            }

            Text("\(line.count)×")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, Theme.Spacing.xs)
                .frame(minHeight: Theme.Size.badge)
                .background(Theme.Palette.yellow, in: Capsule())
                .offset(x: Theme.Spacing.xxs, y: Theme.Spacing.xxs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.count) \(line.colourName) \(line.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
