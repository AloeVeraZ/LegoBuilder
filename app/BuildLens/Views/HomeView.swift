import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @State private var presented: BuildScreen.Mode?
    @State private var showGlasses = false
    #else
    @State private var path: [BuildScreen.Mode] = []
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack { content }
            .fullScreenCover(item: $presented) { mode in
                BuildScreen(initialMode: mode)
                    .environment(app)
            }
            .sheet(isPresented: $showGlasses) {
                GlassesPreview()
                    .environment(app)
                    .presentationDetents([.medium, .large])
            }
        #else
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: BuildScreen.Mode.self) { mode in
                    BuildScreen(initialMode: mode)
                }
        }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                actions
                if !app.syncPeers.isEmpty {
                    Label("Synced with \(app.syncPeers.joined(separator: ", "))", systemImage: "link")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                tips
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("BuildLens")
    }

    @ViewBuilder private var hero: some View {
        if let model = app.model {
            VStack(spacing: 10) {
                if let url = model.heroImageURL, let image = ImageCache.shared.image(at: url) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
                }
                Text(model.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    Label("\(model.pieceCount) pieces", systemImage: "square.stack.3d.up")
                    Label("\(model.steps.count) steps", systemImage: "list.number")
                    Label("~\(model.estimatedMinutes) min", systemImage: "clock")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !model.package.setInfo.id.isEmpty {
                    Text("Set \(model.package.setInfo.id)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            Button {
                app.beginScanning()
                presented = .ar
            } label: {
                Label("Scan your set", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                presented = .viewer
            } label: {
                Label("Open 3D instructions", systemImage: "cube")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                showGlasses = true
            } label: {
                Label("Glasses preview", systemImage: "eyeglasses")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            #else
            Button {
                path.append(.viewer)
            } label: {
                Label("Open 3D instructions", systemImage: "cube")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                openWindow(id: "glasses")
            } label: {
                Label("Glasses preview window", systemImage: "eyeglasses")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            #endif
        }
        .frame(maxWidth: 420)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(iOS)
            tip("camera.viewfinder", "Point the camera at the box or booklet. The app looks for “\(BuildConfig.setNumber)”, or you can tap a table to place the model yourself.")
            tip("hand.draw", "In AR, drag to move, pinch to resize, twist to turn. In 3D, drag to orbit and pinch to zoom.")
            #else
            tip("keyboard", "← / → change steps, R replays the step. Drag to orbit, pinch to zoom, double-click to reset.")
            #endif
            tip("mic", "Turn on voice and say “next”, “back” or “repeat” while your hands are busy.")
            tip("link", "Open the app on your iPhone and Mac on the same network and they follow each other's step.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            Text(text)
        }
    }
}
