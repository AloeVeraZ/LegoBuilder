import SwiftUI

/// Bottom panel while building: what to add, and the step controls.
struct BuildPanel: View {
    @Environment(AppModel.self) private var app
    var showZoom: Bool

    var body: some View {
        VStack(spacing: 10) {
            if let step = app.currentStep {
                if step.isSubAssembly {
                    HStack(spacing: 6) {
                        Image(systemName: "square.on.square.dashed")
                        Text("Sub-assembly: \(step.assembly.name)")
                            .lineLimit(1)
                        if step.assembly.uses > 1 {
                            Text("build ×\(step.assembly.uses)")
                                .fontWeight(.bold)
                        }
                        Spacer()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }
                PartsStrip(lines: step.parts)
            }

            if app.stepCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(app.step) },
                        set: { app.go(to: Int($0.rounded())) }
                    ),
                    in: 0 ... Double(app.stepCount - 1),
                    step: 1
                )
                .tint(.accentColor)
            }

            HStack(spacing: 10) {
                Button {
                    app.back()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(app.step == 0)

                Button {
                    app.replay()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 30, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: [])
                .help("Replay this step")

                if showZoom, let orbit = app.orbit {
                    Button { orbit.zoom(by: 0.8) } label: {
                        Image(systemName: "plus.magnifyingglass").frame(minWidth: 30, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("=", modifiers: [])
                    Button { orbit.zoom(by: 1.25) } label: {
                        Image(systemName: "minus.magnifyingglass").frame(minWidth: 30, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("-", modifiers: [])
                }

                Button {
                    app.next()
                } label: {
                    Label(app.step + 1 == app.stepCount ? "Finish" : "Next", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .controlSize(.large)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 720)
    }
}

/// Puts the icon after the title ("Next >").
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// Thumbnails of the pieces for the current step, with counts.
struct PartsStrip: View {
    @Environment(AppModel.self) private var app
    let lines: [BuildModel.PartLine]
    @State private var selected: BuildModel.PartLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(lines) { line in
                        Button {
                            selected = (selected == line) ? nil : line
                        } label: {
                            PartCell(line: line, isSelected: selected == line)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            if let line = selected ?? lines.first, lines.count == 1 || selected != nil {
                Text("\(line.count)× \(line.name) · \(line.colourName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
                } else {
                    Image(systemName: "cube.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .padding(4)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text("\(line.count)×")
                .font(.caption.bold())
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.75), in: Capsule())
                .foregroundStyle(.white)
                .offset(x: 4, y: 4)
        }
        .accessibilityLabel("\(line.count) \(line.colourName) \(line.name)")
    }
}
