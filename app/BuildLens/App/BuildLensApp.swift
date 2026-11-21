import SwiftUI

@main
struct BuildLensApp: App {
    @State private var app = AppModel()

    init() {
        #if os(macOS)
        // Always start on the home screen with one window, not whatever was open last time.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.load() }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 820)
        // The main window is always what opens, whatever was left open last time.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        #endif

        #if os(macOS)
        // What the glasses will show, in its own window (handy on a projector).
        Window("Glasses Preview", id: "glasses") {
            GlassesPreview()
                .environment(app)
                .frame(minWidth: 480, minHeight: 420)
                .task { await app.load() }
        }
        .defaultSize(width: 700, height: 600)
        // Opened from the app when wanted; never the only thing on screen at launch.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif
    }
}
