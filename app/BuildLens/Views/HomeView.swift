import SwiftUI

/// The start screen: the set as the hero, a bento grid of facts and shortcuts,
/// and one pill for the main action.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @State private var presented: BuildScreen.Mode?
    @State private var showGlasses = false
    #else
    @State private var path: [BuildScreen.Mode] = []
    @Environment(\.openWindow) private var openWindow
    #endif
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 64
    @ScaledMetric(relativeTo: .largeTitle) private var wideHeadlineSize: CGFloat = 112

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                // The glasses asked for the code from the home screen: put it up here. (With
                // the instructions open, BuildScreen puts it up instead.)
                .fullScreenCover(isPresented: Binding(
                    get: { app.markerRequested && presented == nil },
                    set: { if !$0 { app.markerRequested = false } }
                )) { MarkerCard() }
        }
            // The glasses have placed the build: straight into the steps (once the code is away).
            .onChange(of: app.openInstructionsRequested) { _, wanted in
                guard wanted else { return }
                app.openInstructionsRequested = false
                Task {
                    try? await Task.sleep(for: .seconds(0.7))
                    if presented == nil { presented = .viewer }
                }
            }
            .fullScreenCover(item: $presented) { mode in
                BuildScreen(initialMode: mode)
                    .environment(app)
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
        GeometryReader { proxy in
            if proxy.size.width >= Theme.Size.wideBreakpoint {
                wideLayout
            } else {
                compactLayout(height: proxy.size.height)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("BuildLens")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: layouts

    /// iPhone and narrow windows: one fixed page that fits the screen, nothing to scroll.
    /// The picture takes whatever height is left over; the two things to press sit
    /// together at the bottom, instructions first.
    private func compactLayout(height: CGFloat) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            header
            hero(headlineSize: headlineSize)
                .frame(maxHeight: .infinity)
            facts
                .fixedSize(horizontal: false, vertical: true)
            shortcuts
                .frame(height: min(max(height * 0.2, 132), 176))
            primaryAction
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.xs)
        .frame(maxWidth: Theme.Size.contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Mac and iPad: the hero on the left, the bento grid and the main action in a column
    /// on the right. The tiles stretch so both columns end on the same line.
    private var wideLayout: some View {
        VStack(spacing: Theme.Spacing.sm) {
            header
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                hero(headlineSize: wideHeadlineSize)
                VStack(spacing: Theme.Spacing.sm) {
                    facts
                    shortcuts
                    primaryAction
                }
                .frame(width: Theme.Size.sidebarWidth)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.xl)
        .frame(maxWidth: Theme.Size.wideContentWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "cube.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: Theme.Size.mark, height: Theme.Size.mark)
                    .background(
                        Theme.Palette.yellow,
                        in: Theme.shape(Theme.Radius.concentric(outer: Theme.Radius.tile, inset: Theme.Spacing.xxs))
                    )
                    .accessibilityHidden(true)
                Text("BuildLens")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                #if os(iOS)
                moreMenu
                #endif
            }
            .frame(minHeight: Theme.Size.hitTarget)

            // The glasses show up on the Open tile itself, so only other devices are listed here.
            if !app.syncPeers.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    if !app.syncPeers.isEmpty {
                        StatusChip(symbol: "link", text: "Synced with \(app.syncPeers.joined(separator: ", "))", tint: Theme.Palette.green)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    #if os(iOS)
    /// The same ••• menu as in the instructions, here on the home screen too. Everything is
    /// set up on the phone; the glasses just show the build.
    private var moreMenu: some View {
        Menu {
            Group {
                Toggle("Fade pieces already built", isOn: Binding(get: { app.focusMode }, set: { app.focusMode = $0 }))
                Toggle("Read steps aloud", isOn: Binding(get: { app.readAloud }, set: { app.readAloud = $0 }))
            }
            .menuActionDismissBehavior(.disabled)
            Picker(selection: Binding(get: { app.voiceName }, set: { app.voiceName = $0 })) {
                ForEach(AppModel.voices, id: \.name) { Text($0.name).tag($0.name) }
            } label: {
                Label("Voice", systemImage: "waveform")
            }
            .pickerStyle(.menu)
            Button {
                Task { await app.voice.toggle() }
            } label: {
                Label(app.voice.isListening ? "Stop voice control" : "Voice control", systemImage: "mic")
            }
            Button { showGlasses = true } label: { Label("Glasses preview", systemImage: "eyeglasses") }
            Button { app.markerRequested = true } label: { Label("Table marker", systemImage: "qrcode") }
            Button { app.restart() } label: { Label("Start over", systemImage: "arrow.counterclockwise") }
        } label: {
            Image(systemName: "ellipsis")
                .circleIcon(surface: .glass)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .tint(Theme.Palette.textPrimary)
        .accessibilityLabel("More options")
        .sheet(isPresented: $showGlasses) {
            GlassesPreview()
                .environment(app)
                .presentationDetents([.medium, .large])
        }
    }
    #endif

    // MARK: hero

    @ViewBuilder private func hero(headlineSize: CGFloat) -> some View {
        if let model = app.model {
            ZStack(alignment: .topLeading) {
                // The headline sits behind the render, so the model overlaps it.
                VStack(alignment: .leading, spacing: 0) {
                    if !model.package.setInfo.id.isEmpty {
                        Text("Set \(model.package.setInfo.id)")
                            .eyebrowStyle()
                    }
                    Text(model.name)
                        .font(Theme.Typography.display(size: headlineSize))
                        .fontDesign(.default)
                        .textCase(.uppercase)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(Theme.Spacing.lg)

                if let url = model.heroImageURL, let image = ImageCache.shared.image(at: url) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .shadow(color: Theme.Palette.shadow, radius: Theme.Spacing.md, y: Theme.Spacing.sm)
                        .padding(.top, headlineSize * Theme.Size.heroImageInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(Theme.Palette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [Theme.Palette.studio, Theme.Palette.studioShade],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(Theme.shape(Theme.Radius.hero))
        }
    }

    // MARK: bento grid

    /// What is in the box: plain text, not cards, so only the things that can be pressed
    /// (the tiles) look like buttons.
    @ViewBuilder private var facts: some View {
        if let model = app.model {
            HStack(spacing: Theme.Spacing.lg) {
                FactLabel(symbol: "square.stack.3d.up", value: "\(model.pieceCount)", label: "pieces")
                FactLabel(symbol: "list.number", value: "\(model.steps.count)", label: "steps")
                FactLabel(symbol: "clock", value: "\(model.estimatedMinutes)", label: "min")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xxs)
        }
    }

    /// The three things to do on the phone, side by side: scan the set's box, open the
    /// instructions, put up the table marker for the glasses. On the Mac: the instructions.
    private var shortcuts: some View {
        HStack(spacing: Theme.Spacing.sm) {
            #if os(iOS)
            Button {
                // Scan the box again; the table marker follows by itself, for the glasses.
                app.setScanned = false
            } label: {
                BentoTile(eyebrow: "Set", value: "Scan", symbol: "camera.viewfinder", caption: "Then marker",
                          fill: Theme.Palette.red, isAction: true)
            }
            .accessibilityLabel("Scan your set")
            Button {
                presented = .viewer
            } label: {
                BentoTile(
                    eyebrow: app.glassesConnected ? "Glasses" : "Steps",
                    value: "Open",
                    symbol: app.glassesConnected ? "eyeglasses" : "cube",
                    caption: "Step by step",
                    fill: app.glassesConnected ? Theme.Palette.green : Theme.Palette.yellow,
                    isAction: true
                )
            }
            .accessibilityLabel(app.glassesConnected ? "Open instructions on phone and glasses" : "Open instructions")
            Button {
                app.markerRequested = true
            } label: {
                BentoTile(eyebrow: "Table", value: "Marker", symbol: "qrcode", caption: "For glasses",
                          fill: Theme.Palette.blue, isAction: true)
            }
            .accessibilityLabel("Table marker")
            #else
            Button {
                path.append(.viewer)
            } label: {
                BentoTile(
                    eyebrow: "Instructions",
                    value: "Open",
                    symbol: "cube",
                    caption: "Step by step in 3D",
                    fill: Theme.Palette.yellow,
                    isAction: true
                )
            }
            .accessibilityLabel("Open instructions")
            #endif
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: main action

    @ViewBuilder private var primaryAction: some View {
        #if os(iOS)
        // The three tiles above are the actions on the phone.
        EmptyView()
        #else
        // On the Mac the instructions are the big tile; this is the small extra.
        Button {
            openWindow(id: "glasses")
        } label: {
            PillLabel(title: "Glasses preview", systemImage: "eyeglasses")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, height: Theme.Size.cta))
        .accessibilityLabel("Glasses preview window")
        #endif
    }
}
