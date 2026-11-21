import SwiftUI

/// The BuildLens design system: every spacing, radius, colour, type style and animation the
/// views use is defined here, so the screens never carry their own magic numbers.
///
/// The look: a dark navy canvas, vivid brick-coloured bento cards with dark ink text, one
/// white pill for the primary action on each screen, and glass panels floating over the 3D
/// and AR views so the model stays the hero.
enum Theme {

    // MARK: spacing (4 pt grid)

    enum Spacing {
        /// 4 – between an icon and its label, badge offsets.
        static let xxs: CGFloat = 4
        /// 8 – between controls in a row.
        static let xs: CGFloat = 8
        /// 12 – the gap between cards, and between rows inside a panel.
        static let sm: CGFloat = 12
        /// 16 – screen margin and panel padding.
        static let md: CGFloat = 16
        /// 20 – padding inside a card.
        static let lg: CGFloat = 20
        /// 24 – between sections, margins on wide windows.
        static let xl: CGFloat = 24
        /// 32 – around empty and loading states.
        static let xxl: CGFloat = 32
    }

    // MARK: corner radii (always continuous corners)

    enum Radius {
        /// 12 – tiles nested in a panel: panel radius (28) minus panel padding (16).
        static let tile: CGFloat = 12
        /// 24 – bento cards.
        static let card: CGFloat = 24
        /// 28 – floating glass panels and sheets.
        static let panel: CGFloat = 28
        /// 32 – the hero card.
        static let hero: CGFloat = 32

        /// Radius for a shape nested `inset` points inside a shape with radius `outer`,
        /// so both curves share a centre.
        static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(outer - inset, Spacing.xxs)
        }
    }

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    // MARK: sizes

    enum Size {
        /// Smallest tappable area (Human Interface Guidelines).
        static let hitTarget: CGFloat = 44
        /// Height of pill buttons and the round buttons beside them.
        static let control: CGFloat = 52
        /// Height of the one call-to-action pill on the Home screen.
        static let cta: CGFloat = 56
        /// Small round marks: the brand mark, the big status icons.
        static let mark: CGFloat = 32
        /// Count badges on part tiles, status chips.
        static let badge: CGFloat = 20
        static let chip: CGFloat = 28
        /// Thumbnail tile for one part.
        static let partTile: CGFloat = 72
        static let hairline: CGFloat = 1
        static let selectionStroke: CGFloat = 2

        /// Widest a single column of content grows.
        static let contentWidth: CGFloat = 640
        /// Widest the step panel grows.
        static let panelWidth: CGFloat = 720
        /// Widest a floating message card grows.
        static let cardWidth: CGFloat = 440
        /// From this width the Home screen uses two columns.
        static let wideBreakpoint: CGFloat = 880
        static let sidebarWidth: CGFloat = 400
        static let wideContentWidth: CGFloat = 1280
        /// Hero card height in the single-column layout: a share of the screen, within limits,
        /// so hero, bento grid and the pinned button fill an iPhone screen without scrolling.
        static func heroHeight(in available: CGFloat) -> CGFloat {
            min(max(available * 0.4, 260), 420)
        }
        /// The hero render starts this far below the top of its card, as a share of the
        /// headline size: the model overlaps the foot of the headline but never hides it.
        static let heroImageInset: CGFloat = 0.75
        /// The 3D model is raised by at most this fraction of half the stage height, and only
        /// re-aimed when the free area moved by more than `stageRaiseStep`.
        static let maxStageRaise: CGFloat = 0.45
        static let stageRaiseStep: CGFloat = 0.02
        /// The glasses display is 640 points wide in its own coordinates.
        static let glassesDisplayWidth: CGFloat = 640
    }

    // MARK: colours

    /// Each brick colour stands for one thing, everywhere in the app:
    /// yellow = pieces, blue = steps, green = glasses / linked / done, red = live camera and mic.
    enum Palette {
        /// App background.
        static let canvas = Color(hex: 0x171A2B)
        /// Neutral cards on the canvas.
        static let surface = Color(hex: 0x242942)
        /// Muted buttons, on the canvas or on glass.
        static let muted = Color.white.opacity(0.14)
        /// Thin outlines and dividers.
        static let hairline = Color.white.opacity(0.12)
        /// Laid over a system material, so glass reads as navy and white text keeps its
        /// contrast even over the bright 3D studio.
        static let glassTint = canvas.opacity(0.55)
        /// Soft shadow under anything that floats.
        static let shadow = Color.black.opacity(0.2)
        /// Wash behind a status chip, in the chip's own colour.
        static let chipWash: Double = 0.16

        /// Text on dark surfaces. Contrast on `canvas`: 17.2, 8.0 and 5.9 to 1; on `surface`:
        /// 14.3, 6.6 and 4.9 to 1.
        static let textPrimary = Color.white
        static let textSecondary = Color(hex: 0xA9B0CC)
        static let textTertiary = Color(hex: 0x8E96B8)
        /// Text on the brick colours and on white. At least 5.7 to 1 on each of them.
        static let ink = Color(hex: 0x12152A)

        static let yellow = Color(hex: 0xFFD02E)
        static let blue = Color(hex: 0x4F8FFF)
        static let green = Color(hex: 0x46D36B)
        static let red = Color(hex: 0xFF5F52)

        /// The light "photo studio" backdrop behind renders of the model and its parts.
        /// Matches the floor of the 3D viewer.
        static let studio = Color(hex: 0xECEEF2)
        static let studioShade = Color(hex: 0xD3D8E4)

        /// The monochrome green of the smart-glasses display.
        static let hud = Color(red: 0.36, green: 1.0, blue: 0.5)
    }

    // MARK: type

    /// System text styles, so everything follows Dynamic Type. Body text is SF Rounded
    /// (set once in `buildLensTheme()`); the hero headline is condensed and uppercase.
    enum Typography {
        /// Tiny uppercase label above a value. Use through `eyebrowStyle()`.
        static let eyebrow = Font.caption.weight(.bold)
        static let eyebrowTracking: CGFloat = 0.8
        /// The one big number in a card or the current step.
        static let numeral = Font.system(.largeTitle, design: .rounded, weight: .heavy)
        static let title = Font.title2.weight(.bold)
        static let headline = Font.headline
        static let body = Font.subheadline
        static let caption = Font.footnote

        /// Condensed black headline. Pass a size from `@ScaledMetric` so it scales.
        static func display(size: CGFloat) -> Font {
            Font.system(size: size, weight: .black).width(.compressed)
        }
    }

    // MARK: motion

    enum Motion {
        /// Step changes and cards swapping in.
        static let stepChange = Animation.spring(response: 0.42, dampingFraction: 0.86)
        /// Button presses and the segmented pill.
        static let press = Animation.spring(response: 0.24, dampingFraction: 0.8)
        static let pressedScale: CGFloat = 0.97
        static let pressedOpacity: Double = 0.8
        static let disabledOpacity: Double = 0.4

        /// `nil` (no animation) when the user turned on Reduce Motion.
        static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}

extension Color {
    /// `Color(hex: 0x171A2B)`
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// Applies the app-wide look: dark appearance, rounded type, blue tint for system controls.
    /// Put it on the root of every window, sheet and full-screen cover.
    func buildLensTheme() -> some View {
        self
            .tint(Theme.Palette.blue)
            .fontDesign(.rounded)
            .preferredColorScheme(.dark)
    }

    /// Tiny uppercase label ("PIECES", "STEP").
    func eyebrowStyle() -> some View {
        self
            .font(Theme.Typography.eyebrow)
            .textCase(.uppercase)
            .tracking(Theme.Typography.eyebrowTracking)
    }
}
