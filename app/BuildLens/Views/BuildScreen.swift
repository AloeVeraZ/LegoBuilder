import SwiftUI

/// The build screen: AR camera (iPhone) or 3D viewer, with the step UI on top.
struct BuildScreen: View {
    enum Mode: String, Identifiable, Hashable {
        case viewer, ar
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    #if os(iOS)
    @State private var showGlasses = false
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    init(initialMode: Mode) {
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ZStack {
            stage
                .ignoresSafeArea()
            VStack(spacing: 10) {
                topBar
                Spacer(minLength: 0)
                bottom
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear {
            if mode == .viewer { app.enterViewer() }
        }
        #if os(iOS)
        .statusBarHidden(mode == .ar)
        .sheet(isPresented: $showGlasses) {
            GlassesPreview()
                .environment(app)
                .presentationDetents([.medium, .large])
        }
        #else
        .navigationTitle(app.model?.name ?? "Build")
        #endif
    }

    // MARK: stage

    @ViewBuilder private var stage: some View {
        if let scene = app.scene, let orbit = app.orbit {
            #if os(iOS)
            if mode == .ar {
                ARExperienceView(app: app)
            } else {
                ModelViewer(scene: scene, controller: orbit)
            }
            #else
            ModelViewer(scene: scene, controller: orbit)
            #endif
        }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            #if os(iOS)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Circle())
            #endif

            if app.arPhase == .building || mode == .viewer {
                StepHeader()
            } else {
                Spacer()
            }

            #if os(iOS)
            Picker("View", selection: $mode) {
                Text("AR").tag(Mode.ar)
                Text("3D").tag(Mode.viewer)
            }
            .pickerStyle(.segmented)
            .frame(width: 96)
            .onChange(of: mode) { _, newMode in
                if newMode == .viewer { app.enterViewer() }
            }
            #endif

            Menu {
                Toggle("Focus on new pieces", isOn: Binding(get: { app.focusMode }, set: { app.focusMode = $0 }))
                Toggle("Read steps aloud", isOn: Binding(get: { app.readAloud }, set: { app.readAloud = $0 }))
                Button {
                    Task { await app.voice.toggle() }
                } label: {
                    Label(app.voice.isListening ? "Stop voice control" : "Voice control", systemImage: "mic")
                }
                #if os(iOS)
                Button { showGlasses = true } label: { Label("Glasses preview", systemImage: "eyeglasses") }
                if mode == .ar {
                    Button { app.beginScanning() } label: { Label("Scan again", systemImage: "camera.viewfinder") }
                }
                #else
                Button { openWindow(id: "glasses") } label: { Label("Glasses preview window", systemImage: "eyeglasses") }
                #endif
                Button { app.restart() } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
    }

    // MARK: bottom

    @ViewBuilder private var bottom: some View {
        #if os(iOS)
        if mode == .ar && app.arPhase == .scanning {
            ScanHint()
        } else if mode == .ar && app.arPhase == .revealed {
            RevealCard()
        } else if app.showingFinished {
            FinishedCard()
        } else {
            BuildPanel(showZoom: mode == .viewer)
        }
        #else
        if app.showingFinished {
            FinishedCard()
        } else {
            BuildPanel(showZoom: true)
        }
        #endif
    }
}

/// "Step 3 of 40" with a progress bar and the sync / voice indicators.
struct StepHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(app.showingFinished ? "Finished" : "Step \(app.step + 1) of \(app.stepCount)")
                    .font(.headline)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if app.voice.isListening {
                    Label(app.voice.lastHeard.isEmpty ? "Listening" : "“\(app.voice.lastHeard)”", systemImage: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if !app.syncPeers.isEmpty {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("Synced with \(app.syncPeers.joined(separator: ", "))")
                }
            }
            ProgressView(value: app.showingFinished ? 1 : app.progress)
                .tint(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
