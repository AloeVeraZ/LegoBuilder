import SwiftUI

// MARK: - surfaces

/// A glass surface for anything floating over the 3D or AR view: a system material, a touch of
/// the canvas colour so white text stays readable over a bright scene, and a hairline edge.
private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let material: Material

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(material)
                    .overlay(shape.fill(Theme.Palette.glassTint))
                    .shadow(color: Theme.Palette.shadow, radius: Theme.Spacing.md, y: Theme.Spacing.xs)
            }
            .overlay {
                shape.strokeBorder(Theme.Palette.hairline, lineWidth: Theme.Size.hairline)
            }
    }
}

extension View {
    /// Panels with text use `.regularMaterial`; small controls can use `.ultraThinMaterial`.
    func glassSurface<S: InsettableShape>(_ shape: S, material: Material = .regularMaterial) -> some View {
        modifier(GlassSurface(shape: shape, material: material))
    }

    /// A floating message card (scan hint, set found, finished).
    func floatingCard() -> some View {
        self
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: Theme.Size.cardWidth)
            .glassSurface(Theme.shape(Theme.Radius.panel))
    }
}

// MARK: - buttons

/// The pill button. `.primary` is the white call-to-action (one per screen);
/// `.secondary` is the muted slate pill beside it.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    var kind: Kind = .primary
    var height: CGFloat = Theme.Size.control

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, height: height)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(Theme.Typography.headline)
                .foregroundStyle(kind == .primary ? Theme.Palette.ink : Theme.Palette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(kind == .primary ? Color.white : Theme.Palette.muted, in: Capsule())
                .contentShape(Capsule())
                .pressEffect(isPressed: configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
        }
    }
}

/// A round icon-only button. Always give the button an `accessibilityLabel`.
struct CircleButtonStyle: ButtonStyle {
    enum Surface { case glass, muted }

    var surface: Surface = .muted
    var diameter: CGFloat = Theme.Size.hitTarget

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, surface: surface, diameter: diameter)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        let surface: Surface
        let diameter: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .circleIcon(surface: surface, diameter: diameter)
                .pressEffect(isPressed: configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
        }
    }
}

/// For whole cards that act as buttons: no chrome of its own, just the press feedback.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .pressEffect(isPressed: configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
        }
    }
}

extension View {
    /// The look of a round icon button, for places that can't take a `ButtonStyle` (menu labels).
    func circleIcon(surface: CircleButtonStyle.Surface, diameter: CGFloat = Theme.Size.hitTarget) -> some View {
        self
            .font(Theme.Typography.headline)
            .foregroundStyle(Theme.Palette.textPrimary)
            .frame(width: diameter, height: diameter)
            .background {
                switch surface {
                case .glass: Color.clear.glassSurface(Circle(), material: .ultraThinMaterial)
                case .muted: Circle().fill(Theme.Palette.muted)
                }
            }
            .contentShape(Circle())
    }

    /// Shared pressed and disabled states, so every custom button responds the same way.
    fileprivate func pressEffect(isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) -> some View {
        self
            .opacity(isEnabled ? (isPressed ? Theme.Motion.pressedOpacity : 1) : Theme.Motion.disabledOpacity)
            .scaleEffect(isPressed && !reduceMotion ? Theme.Motion.pressedScale : 1)
            .animation(Theme.Motion.respecting(reduceMotion, Theme.Motion.press), value: isPressed)
    }
}

/// Pill content with the label on the left and the icon in a dark circle on the right.
struct PillLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Theme.Spacing.xs)
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.white)
                // The pill is 2 x xs taller than this circle, so the two curves are concentric.
                .frame(width: Theme.Size.control - 2 * Theme.Spacing.xs, height: Theme.Size.control - 2 * Theme.Spacing.xs)
                .background(Theme.Palette.ink, in: Circle())
                .accessibilityHidden(true)
        }
        .padding(.leading, Theme.Spacing.lg)
        .padding(.trailing, Theme.Spacing.xs)
    }
}

// MARK: - segmented pill

/// A two-or-three way switch drawn as one glass capsule with a white thumb.
struct SegmentedPill<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.press)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.textPrimary)
                        .frame(minWidth: Theme.Size.hitTarget, minHeight: Theme.Size.hitTarget)
                        .padding(.horizontal, Theme.Spacing.xxs)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white)
                                    .padding(Theme.Spacing.xxs)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .glassSurface(Capsule(), material: .ultraThinMaterial)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - bento tile

/// One solid-colour card of the bento grid: a tiny uppercase label, one big value with a
/// line icon, and a one-line caption.
struct BentoTile: View {
    let eyebrow: String
    let value: String
    let symbol: String
    let caption: String
    var fill: Color
    var ink: Color = Theme.Palette.ink
    /// Shows an arrow to mark the tile as tappable.
    var isAction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(eyebrow)
                    .eyebrowStyle()
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .frame(height: Theme.Size.chip)
            }
            // In a stretched tile the label stays at the top and the value drops to the bottom.
            Spacer(minLength: Theme.Spacing.xs)
            Text(value)
                .font(Theme.Typography.numeral)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.bottom, Theme.Spacing.xs)
            HStack(spacing: Theme.Spacing.xs) {
                Text(caption)
                    .font(Theme.Typography.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if isAction {
                    // The same round arrow as the main buttons: this is something to press.
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(fill)
                        .frame(width: Theme.Size.mark, height: Theme.Size.mark)
                        .background(ink, in: Circle())
                }
            }
        }
        .foregroundStyle(ink)
        .padding(Theme.Spacing.lg)
        // Fills the row's height, so tiles side by side always match.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: Theme.shape(Theme.Radius.card))
        .contentShape(Theme.shape(Theme.Radius.card))
    }
}

// MARK: - fact

/// A plain fact about the set: a number and what it counts. Deliberately not a card, so
/// it does not look like something to press.
struct FactLabel: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(label)
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - status chip

/// A small tinted capsule for live status: "Glasses linked", "Listening".
struct StatusChip: View {
    let symbol: String
    var text: String?
    let tint: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: symbol)
            if let text {
                Text(text)
                    .lineLimit(1)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(minWidth: Theme.Size.chip, minHeight: Theme.Size.chip)
        .background(tint.opacity(Theme.Palette.chipWash), in: Capsule())
    }
}
