import SwiftUI

/// The build screen: AR camera (iPhone) or 3D viewer, with the step UI floating on top.
/// The model is the hero, so everything over it is glass and stays at the edges.
struct BuildScreen: View {
    enum Mode: String, Identifiable, Hashable {
        case viewer, ar
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: Mode
    @State private var isWide = false
    /// Measured in global coordinates, to aim the 3D camera at the part of the stage
    /// that the controls leave free.
    @State private var stageFrame = CGRect.zero
    @State private var freeTop: CGFloat = 0
    @State private var freeBottom: CGFloat = 0
    #if os(iOS)
    @State private var showGlasses = false
    @State private var showMarker = false
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
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    stageFrame = frame
                    aimCamera()
                }
            VStack(spacing: Theme.Spacing.sm) {
                topBar
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).maxY
                    } action: { edge in
                        freeTop = edge
                        aimCamera()
                    }
                #if os(iOS)
                if mode == .ar && app.placingOnSurface {
                    SurfaceHint()
                        .transition(.opacity)
                }
                if mode == .ar && app.arPhase == .building && !app.showingFinished && !findingSurface {
                    ViewCube(model: app.viewCube)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity)
                }
                #endif
                Spacer(minLength: 0)
                if !findingSurface {
                    bottom
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.stepChange), value: findingSurface)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)

            if app.showingFinished && !reduceMotion {
                ConfettiBurst()
                    .ignoresSafeArea()
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= Theme.Size.wideBreakpoint
        } action: { wide in
            isWide = wide
        }
        .buildLensTheme()
        .onAppear {
            if mode == .viewer { app.enterViewer() }
        }
        .onDisappear { app.leaveInstructions() }
        #if os(iOS)
        .statusBarHidden(mode == .ar)
        .fullScreenCover(isPresented: $showMarker) { MarkerCard() }
        .sheet(isPresented: $showGlasses) {
            GlassesPreview()
                .environment(app)
                .presentationDetents([.medium, .large])
        }
        #else
        .navigationTitle(app.model?.name ?? "Build")
        #endif
    }

    /// The camera is looking for the set's box.
    private var scanningForSet: Bool { mode == .ar && app.arPhase == .scanning }

    /// AR was just opened and is still scanning for the table.
    private var findingSurface: Bool { mode == .ar && app.arFindingSurface }

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
        HStack(spacing: Theme.Spacing.xs) {
            #if os(iOS)
            Button {
                app.hush()                          // not building any more: stop talking now
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CircleButtonStyle(surface: .glass))
            .accessibilityLabel("Close")
            #endif

            Spacer(minLength: Theme.Spacing.xs)

            #if os(iOS)
            if mode == .ar && app.arPhase == .building && !findingSurface {
                // Stand the model on the table (or floor) the camera is pointed at.
                Button {
                    app.placingOnSurface.toggle()
                } label: {
                    Image(systemName: app.placingOnSurface ? "xmark" : "arrow.down.to.line")
                }
                .buttonStyle(CircleButtonStyle(surface: .glass))
                .accessibilityLabel(app.placingOnSurface ? "Stop looking for a surface" : "Place on a surface")
            }
            // While the camera is looking for the set there is only the way out.
            if !scanningForSet {
                SegmentedPill(
                    title: "View",
                    selection: $mode,
                    options: [(value: Mode.ar, label: "AR"), (value: Mode.viewer, label: "3D")]
                )
            }
            #endif

            if !scanningForSet {
            Menu {
                Toggle("Fade pieces already built", isOn: Binding(get: { app.focusMode }, set: { app.focusMode = $0 }))
                Toggle("Read steps aloud", isOn: Binding(get: { app.readAloud }, set: { app.readAloud = $0 }))
                Button {
                    Task { await app.voice.toggle() }
                } label: {
                    Label(app.voice.isListening ? "Stop voice control" : "Voice control", systemImage: "mic")
                }
                #if os(iOS)
                Button { showGlasses = true } label: { Label("Glasses preview", systemImage: "eyeglasses") }
                Button { showMarker = true } label: { Label("Table marker", systemImage: "qrcode") }
                if mode == .ar {
                    Button { app.placingOnSurface = true } label: { Label("Place on a surface", systemImage: "square.3.layers.3d.down.right") }
                    Button { app.beginScanning() } label: { Label("Scan again", systemImage: "camera.viewfinder") }
                }
                #else
                Button { openWindow(id: "glasses") } label: { Label("Glasses preview window", systemImage: "eyeglasses") }
                #endif
                Button { app.restart() } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "ellipsis")
                    .circleIcon(surface: .glass)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            // Menu symbols stay monochrome: on glass, colour is for status, not decoration.
            .tint(Theme.Palette.textPrimary)
            .accessibilityLabel("More options")
            }
        }
        #if os(iOS)
        .onChange(of: mode) { _, newMode in
            app.hush()                              // changing view stops the talking
            if newMode == .viewer { app.enterViewer() }
        }
        #endif
    }

    // MARK: bottom

    private var showsZoom: Bool {
        #if os(iOS)
        return mode == .viewer
        #else
        return true
        #endif
    }

    /// The card for the current phase, with the zoom buttons beside it (wide) or above it (narrow).
    @ViewBuilder private var bottom: some View {
        Group {
            if isWide {
                HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                    // Balances the zoom buttons so the card stays centred.
                    Color.clear.frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
                    card.frame(maxWidth: .infinity)
                    zoom.frame(width: Theme.Size.hitTarget)
                }
            } else {
                VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                    zoom
                    card.frame(maxWidth: .infinity)
                }
            }
        }
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.stepChange), value: app.showingFinished)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.stepChange), value: app.milestone)
        .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.stepChange), value: app.arPhase)
    }

    @ViewBuilder private var zoom: some View {
        if showsZoom, let orbit = app.orbit {
            ZoomControl(orbit: orbit)
        }
    }

    /// The step panel, or for a moment the "well done" card between parts of the build.
    /// Tapping the card moves on at once.
    @ViewBuilder private var stepOrMilestone: some View {
        if let milestone = app.milestone {
            MilestoneCard(milestone: milestone)
                .contentShape(Rectangle())
                .onTapGesture { app.next() }
                .transition(.scale(scale: 0.94).combined(with: .opacity))
        } else {
            stepPanel
        }
    }

    @ViewBuilder private var card: some View {
        #if os(iOS)
        if mode == .ar && app.arPhase == .scanning {
            ScanHint()
        } else if mode == .ar && app.arPhase == .revealed {
            RevealCard()
        } else if app.showingFinished {
            FinishedCard(onExit: { dismiss() })
        } else {
            stepOrMilestone
        }
        #else
        if app.showingFinished {
            FinishedCard(onExit: { dismiss() })
        } else {
            stepOrMilestone
        }
        #endif
    }

    private var stepPanel: some View {
        BuildPanel()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minY
            } action: { edge in
                freeBottom = edge
                aimCamera()
            }
    }

    /// Raises the model so it sits in the middle of the area between the top bar and the
    /// step panel, whatever the size of the window or the screen.
    private func aimCamera() {
        guard let orbit = app.orbit, stageFrame.height > 0, freeBottom > freeTop else { return }
        let freeMiddle = (freeTop + freeBottom) / 2
        let raise = (stageFrame.midY - freeMiddle) / (stageFrame.height / 2)
        let bias = Float(min(max(raise, 0), Theme.Size.maxStageRaise))
        if abs(orbit.verticalBias - bias) > Float(Theme.Size.stageRaiseStep) {
            orbit.verticalBias = bias
        }
    }
}

/// Zoom in and out of the 3D view: one glass capsule on the trailing edge, like a map control.
struct ZoomControl: View {
    let orbit: OrbitController

    var body: some View {
        VStack(spacing: 0) {
            Button {
                orbit.zoom(by: 0.8)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut("=", modifiers: [])
            .accessibilityLabel("Zoom in")
            .help("Zoom in")

            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(width: Theme.Size.hitTarget / 2, height: Theme.Size.hairline)

            Button {
                orbit.zoom(by: 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: Theme.Size.hitTarget, height: Theme.Size.hitTarget)
                    .contentShape(Rectangle())
            }
            .keyboardShortcut("-", modifiers: [])
            .accessibilityLabel("Zoom out")
            .help("Zoom out")
        }
        .buttonStyle(CardButtonStyle())
        .font(Theme.Typography.headline)
        .foregroundStyle(Theme.Palette.textPrimary)
        .glassSurface(Capsule(), material: .ultraThinMaterial)
    }
}

/// "STEP 07 / 23": the current step as a big numeral, the way a manual numbers its pages.
struct StepHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            // Which part of the build this is, so a switch to a sub-build is never a surprise.
            Label(app.sectionTitle, systemImage: app.isSubBuild ? "square.on.square.dashed" : "shippingbox")
                .eyebrowStyle()
                .foregroundStyle(app.isSubBuild ? Theme.Palette.blue : Theme.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
            stepNumber
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.sectionTitle). Step \(app.step + 1) of \(app.stepCount)")
        .accessibilityAddTraits(.isHeader)
    }

    private var stepNumber: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text("Step")
                .eyebrowStyle()
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(String(format: "%02d", app.step + 1))
                .font(Theme.Typography.numeral)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText(value: Double(app.step)))
            Text("/ \(app.stepCount)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .lineLimit(1)
    }
}

/// Live indicators beside the step number: voice control, glasses, device sync.
struct StatusChips: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if app.voice.isListening {
                StatusChip(
                    symbol: "mic.fill",
                    text: app.voice.lastHeard.isEmpty ? "Listening" : "“\(app.voice.lastHeard)”",
                    tint: Theme.Palette.red
                )
                .accessibilityLabel(app.voice.lastHeard.isEmpty ? "Voice control is listening" : "Heard \(app.voice.lastHeard)")
            }
            if app.glassesConnected {
                StatusChip(symbol: "eyeglasses", tint: Theme.Palette.green)
                    .help("Glasses linked")
                    .accessibilityLabel("Glasses linked")
            }
            if !app.syncPeers.isEmpty {
                StatusChip(symbol: "link", tint: Theme.Palette.green)
                    .help("Synced with \(app.syncPeers.joined(separator: ", "))")
                    .accessibilityLabel("Synced with \(app.syncPeers.joined(separator: ", "))")
            }
        }
    }
}
