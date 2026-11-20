import SwiftUI

@main
struct BuildLensApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.load() }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 820)
        #endif

        #if os(macOS)
        // What the glasses will show, in its own window (handy on a projector).
        Window("Glasses Preview", id: "glasses") {
            GlassesPreview()
                .environment(app)
                .frame(minWidth: 480, minHeight: 420)
        }
        .defaultSize(width: 700, height: 600)
        #endif
    }
}
