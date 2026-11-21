import SwiftUI

/// The start screen: the set as the hero, a bento grid of facts and shortcuts,
/// and one pill for the main action.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @State private var presented: BuildScreen.Mode?
    #else
    @State private var path: [BuildScreen.Mode] = []
    @Environment(\.openWindow) private var openWindow
    #endif
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 64
    @ScaledMetric(relativeTo: .largeTitle) private var wideHeadlineSize: CGFloat = 112

    var body: some View {
        #if os(iOS)
        NavigationStack { content }
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

    /// iPhone and narrow windows: one scrolling column, the main action pinned at the bottom.
    private func compactLayout(height: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.sm) {
                header
                hero(headlineSize: headlineSize)
                    .frame(height: Theme.Size.heroHeight(in: height))
                facts
                    .fixedSize(horizontal: false, vertical: true)
                shortcuts
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.xs)
            .padding(.bottom, Theme.Spacing.md)
            .frame(maxWidth: Theme.Size.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            primaryAction
                .frame(maxWidth: Theme.Size.contentWidth)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.xs)
                .frame(maxWidth: .infinity)
                .background {
                    // Content fades out under the pinned button instead of being cut off.
                    LinearGradient(
                        colors: [Theme.Palette.canvas.opacity(0), Theme.Palette.canvas],
                        startPoint: .top,
                        endPoint: .center
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
        }
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

    /// What is in the box. Not tappable.
    @ViewBuilder private var facts: some View {
        if let model = app.model {
            HStack(spacing: Theme.Spacing.sm) {
                BentoTile(
                    eyebrow: "Pieces",
                    value: "\(model.pieceCount)",
                    symbol: "square.stack.3d.up",
                    caption: "in the box",
                    fill: Theme.Palette.yellow
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.pieceCount) pieces")

                BentoTile(
                    eyebrow: "Steps",
                    value: "\(model.steps.count)",
                    symbol: "list.number",
                    caption: "about \(model.estimatedMinutes) min",
                    fill: Theme.Palette.blue
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.steps.count) steps, about \(model.estimatedMinutes) minutes")
            }
        }
    }

    /// One way into the instructions. When the glasses are linked they show the same step
    /// by themselves, so there is nothing separate to open for them.
    private var shortcuts: some View {
        HStack(spacing: Theme.Spacing.sm) {
            #if os(iOS)
            Button {
                presented = .viewer
            } label: {
                BentoTile(
                    eyebrow: app.glassesConnected ? "Phone + glasses" : "Instructions",
                    value: "Open",
                    symbol: app.glassesConnected ? "eyeglasses" : "cube",
                    caption: app.glassesConnected ? "Shows on your glasses too" : "Step by step in 3D",
                    fill: app.glassesConnected ? Theme.Palette.green : Theme.Palette.surface,
                    ink: app.glassesConnected ? Theme.Palette.ink : Theme.Palette.textPrimary,
                    isAction: true
                )
            }
            .accessibilityLabel(app.glassesConnected ? "Open instructions on phone and glasses" : "Open instructions")
            #else
            Button {
                path.append(.viewer)
            } label: {
                BentoTile(
                    eyebrow: "Instructions",
                    value: "Open",
                    symbol: "cube",
                    caption: "Step by step in 3D",
                    fill: Theme.Palette.surface,
                    ink: Theme.Palette.textPrimary,
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
        Button {
            app.beginScanning()
            presented = .ar
        } label: {
            PillLabel(title: "Scan your set", systemImage: "camera.viewfinder")
        }
        .buttonStyle(PillButtonStyle(kind: .primary, height: Theme.Size.cta))
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
