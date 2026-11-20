import SwiftUI

/// Shown while the camera looks for the box.
struct ScanHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 34))
                .symbolEffect(.pulse)
            Text("Point the camera at your box")
                .font(.headline)
            Text("Looking for set \(BuildConfig.setNumber)… or tap a table to place the model.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Shown when the box was found and the finished model popped up.
struct RevealCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            if let model = app.model {
                Label(app.foundByScan ? "Set found" : "Model placed", systemImage: app.foundByScan ? "checkmark.seal.fill" : "hand.tap.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                Text(model.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("\(model.pieceCount) pieces · \(model.steps.count) steps · about \(model.estimatedMinutes) min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    app.startBuilding()
                } label: {
                    Label("Start building", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Drag to move it, pinch to resize, twist to turn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Shown after the last step.
struct FinishedCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            Text("You built it! 🏁")
                .font(.title2.bold())
            if let model = app.model {
                Text(model.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    app.back()
                } label: {
                    Label("Last step", systemImage: "chevron.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    app.restart()
                } label: {
                    Label("Build again", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
