import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let error = app.loadError {
                ContentUnavailableView("Couldn't load the model", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if app.model == nil {
                loading
            } else {
                HomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .buildLensTheme()
    }

    private var loading: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "cube.transparent")
                .font(.largeTitle.weight(.semibold))
                .imageScale(.large)
                .foregroundStyle(Theme.Palette.yellow)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            Text("Preparing pieces…")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            ProgressView(value: app.loadingProgress)
                .tint(Theme.Palette.yellow)
                .frame(maxWidth: Theme.Size.cardWidth / 2)
        }
        .padding(Theme.Spacing.xxl)
    }
}
