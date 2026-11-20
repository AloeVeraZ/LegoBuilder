import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let error = app.loadError {
            ContentUnavailableView("Couldn't load the model", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if app.model == nil {
            VStack(spacing: 16) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse)
                Text("Preparing pieces…")
                    .font(.headline)
                ProgressView(value: app.loadingProgress)
                    .frame(maxWidth: 220)
            }
            .padding()
        } else {
            HomeView()
        }
    }
}
