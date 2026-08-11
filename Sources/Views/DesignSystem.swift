import SwiftUI
import AppKit

/// The measurements that are not settings.
///
/// `AppearanceSettings.Metrics` owns everything density and text scale move:
/// row padding, the panel's three type sizes, bar and ring geometry. This owns
/// what they don't — the gutters both windows share, the corner radii, the
/// settings window's own type sizes, hit-target sizes, and the quiet fills,
/// which were seven slightly different `Color.primary.opacity` values across
/// four files before they were named here.
///
/// The rule for where a number goes: if the user can change it, it belongs in
/// `Metrics`; if they cannot, it belongs here. Nothing in here is persisted and
/// nothing has a control in the Appearance pane. `Metrics` is the caller of
/// this type, never the reverse — `rowHorizontalPadding` should return
/// `Tokens.Space.gutter` rather than repeat the literal 12.
public enum Tokens {

    // MARK: - Spacing

    /// Gaps between things, on a 2/4/6/8/12/16/24 scale. Three neighbouring
    /// gaps of 5, 6 and 7pt read as a mistake rather than as a rhythm, which is
    /// what the panel had: its title line at 6, its chips at 5 and its captions
    /// at 4.
    public enum Space {
        /// The 1pt that is not a gap: the nudge that drops the leading column
        /// onto a cap-height title, the pill's own vertical padding, and the
        /// space between a title and the caption directly under it — which is
        /// one block of text set in two sizes, not two things beside each other.
        public static let hairline: CGFloat = 1
        public static let tight: CGFloat = 2
        public static let snug: CGFloat = 4
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 12
        public static let xlarge: CGFloat = 16
        public static let huge: CGFloat = 24

        /// Content inset for the panel and for each settings pane's own columns.
        /// `AppearanceSettings.Metrics.rowHorizontalPadding` is this value, and
        /// so is the indent on the panel's section headers — they exist to line
        /// up with the rows beneath them, which they did only by coincidence
        /// while both were written as a literal 12.
        public static let gutter: CGFloat = 12
        /// How far a row's background is held inside the gutter, so a hovered
        /// card floats instead of touching the window edge.
        public static let cardInset: CGFloat = 6
        /// Logo-and-dial column to the text beside it, at the value both rows
        /// were tuned at rather than rounded onto the scale: `leadingWidth` in
        /// `ProviderRow` and in the Appearance pane's sample row both add it to
        /// the column, and what is left of the panel is the text column their
        /// chip estimate divides. Rounding it to 12 changes how many chips a
        /// 300pt row draws.
        public static let leadingColumn: CGFloat = 11
        /// Logo to dial inside that column: the spacing of the `leading` stack
        /// in both rows, and the gap `AppearanceSettings.ringBudget` subtracts
        /// along with the logo when it decides how wide a dial may be — which is
        /// why this one is not free to move either.
        public static let leadingItems: CGFloat = 7
        /// Panel header: above the title line, and below it to the divider.
        /// Asymmetric because the divider reads as part of the bottom edge.
        public static let headerTop: CGFloat = 11
        public static let headerBottom: CGFloat = 9
        /// Vertical breathing room around the panel's list inside the window.
        public static let listMargin: CGFloat = 6
        /// A settings pane's own inset, for the panes that aren't a `Form`.
        public static let paneMargin: CGFloat = 14
        /// A dialog's inset: the connect window and any sheet.
        public static let dialogMargin: CGFloat = 16
    }

    // MARK: - Corner radii

    /// Named by the kind of surface rather than by size, because each one is a
    /// different thing: four kinds of rounded rectangle were being drawn by five
    /// radii (5, 6, 7, 8, 10), and no call site said which surface it meant.
    public enum Radius {
        /// A borderless icon button's hover plate.
        public static let control: CGFloat = 5
        /// A selectable pill: sidebar row, preset chip, section disclosure.
        public static let chip: CGFloat = 6
        /// A row card in the panel.
        public static let row: CGFloat = 8
        /// A floating surface: the appearance sample, a banner, a callout.
        public static let panel: CGFloat = 10
        /// Every corner in the app is continuous. Named so a caller cannot
        /// forget to say so: the two that had forgotten stood out badly beside a
        /// neighbour that hadn't.
        public static let style: RoundedCornerStyle = .continuous
    }

    /// `RoundedRectangle` at a radius from `Radius`, continuous like the rest.
    public static func surface(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: Radius.style)
    }

    // MARK: - Type

    /// The type ramp for everything `Metrics` does not scale.
    ///
    /// The panel's own title/detail/caption sizes stay in `Metrics` — they move
    /// with density and text scale and are not repeated here. This is the
    /// settings window, the connect dialog and the panel's group headers, none
    /// of which follow the panel's text scale (a settings window that resized
    /// itself from an appearance slider would be its own bug).
    ///
    /// Three sizes, not five. 13/11/10 is macOS's own control ramp, and the two
    /// that went were the two that disagreed with it: a 12pt body sitting one
    /// point under every native form's, and a 9pt section header smaller than
    /// anything the system sets a label at. A house ramp that quietly differs
    /// from every window beside it is the thing to stop shipping — five sizes
    /// over an 8pt span were four boundaries to get wrong rather than a
    /// hierarchy.
    public enum Ramp {
        /// A row's subject, a heading, and body text in a settings row or a
        /// dialog step.
        public static let title: CGFloat = 13
        /// The line under a title, a secondary reading, a chart legend or series
        /// label.
        public static let detail: CGFloat = 11
        /// Prose footers, slider readouts, axis labels, and group headers.
        public static let caption: CGFloat = 10

        /// A name, a heading, a figure that is the row's answer.
        public static let titleWeight: Font.Weight = .semibold
        /// A label that has to hold its own beside a figure.
        public static let emphasisWeight: Font.Weight = .medium
        /// A figure at or above `warningThreshold`. The only weight in the panel
        /// heavier than `emphasisWeight`, so the change at the threshold cannot
        /// be read as anything else — it is the third of the four channels that
        /// carry near-cap, and the one that survives a greyscale screenshot.
        public static let alertWeight: Font.Weight = .semibold
        /// Percentages and any figure the eye scans down a column.
        ///
        /// Monospaced, not rounded: tabular figures are the whole of the
        /// "terminal data" half of the direction, and this one line reaches
        /// every figure call site in both windows. `.monospaced` is a
        /// `Font.Design`, so it goes through `Font.system` and needs no
        /// availability gate — `NSFont(name: "SFMono-Regular", size:)` returns
        /// nil, because SF Mono is not registered for lookup by name.
        ///
        /// The rule for which face a run takes, so no call site has to judge it:
        /// a run that is only digits, separators and the unit letters attached to
        /// them is SF Mono; a run containing a word is SF Pro with
        /// `.monospacedDigit()`. So `92`, `%`, `1.2k`, `$32.84`, `12s` are this.
        /// `resets in 1h 20m`, `on pace to cap in 40m` and `updated 12s ago` are
        /// not — full mono on prose is the terminal pastiche the direction rules
        /// out.
        ///
        /// And the clause that turns "we use a mono font" into "we have
        /// columns": every SF Mono run lives inside a reserved, fixed-width,
        /// trailing-aligned rail from `figureWidth` below. SF Mono never appears
        /// outside a rail, because a mono run that is free to size itself is
        /// just a font choice — the columns are the point.
        ///
        /// Reached through `Font.system(size:weight:design:)` and never through
        /// `Text.monospaced()`. That method is `macOS 13.3`; the `View` overload
        /// is 13.0, and wherever the receiver is statically a `Text` the compiler
        /// binds the 13.3 one and silently raises the app's floor past the stated
        /// minimum with no diagnostic. `Font.Design` carries no availability at
        /// all, and `View.monospacedDigit()` is macOS 12 and safe.
        public static let figureDesign: Font.Design = .monospaced
    }

    /// Letter spacing for an uppercased group header.
    ///
    /// A group header is now one fixed recipe with nothing to configure:
    /// `Ramp.caption`, uppercased, this tracking, `.semibold`, `.secondary`, and
    /// unscaled by the panel's text scale. `sectionSize(textScale:)` was here to
    /// stop a 9pt header being scaled down to 7.6 and read as a grey smear; at a
    /// fixed 10 that special case has nothing left to defend, and a header is
    /// chrome rather than content — it is a divider with a word on it, and the
    /// slider the user reached for was aimed at the readings underneath.
    public static let sectionTracking: CGFloat = 0.5

    /// Width of `digits` monospaced characters at `size`.
    ///
    /// Tabular figures fix the width of a digit, not the length of a string:
    /// `9%` still reflows to `92%` and drags the label beside it. Every figure
    /// column is therefore reserved, and this is the width to reserve it at.
    ///
    /// 0.6185 is SF Mono's measured advance ratio on this platform — "888"
    /// measures 24.11pt at 13pt — so this is the real column rather than an
    /// em-based guess with slack in it. It replaces the `(detailSize * 2.8)`
    /// that `ProviderRow` was estimating with.
    public static func figureWidth(_ size: CGFloat, digits: Int) -> CGFloat {
        (size * 0.6185 * CGFloat(digits)).rounded(.up)
    }

    /// The one rail money is allowed: eight cells, `$1234.56`.
    ///
    /// Money is the single exception to "no decimals on a figure" — a budget of
    /// `$32` when the bill is `$32.84` is a different number, and the two
    /// decimals are the reading rather than a tick that changes no decision. Its
    /// rail is therefore wider than every other one in the app, which is why it
    /// is named here once rather than counted out at each spend call site: eight
    /// covers the currency mark, four digits and the point, and a budget past
    /// four digits truncates rather than widening the column it shares with
    /// three other rows.
    public static func moneyWidth(_ size: CGFloat) -> CGFloat {
        figureWidth(size, digits: 8)
    }

    /// The height a single-line detail row is held at.
    ///
    /// A `ProgressView`, a status dot and a percentage are each taller than the
    /// text beside them, so a row that sizes itself to whichever one is in it
    /// changes height when a load finishes or a quota arrives. One box, one
    /// height, whatever fills it. It was a `+ 3` written twice in `ProviderRow`
    /// and missing from `MetricCaption`, so a row lost those 3pt the moment a
    /// quota arrived and the panel resized around it.
    public static func lineBox(_ size: CGFloat) -> CGFloat {
        size + lineBoxPad
    }

    /// Deliberately off the spacing scale, and kept at the value the panel was
    /// tuned at: it is not a gap between two things but the slack a mini
    /// `ProgressView` and a 6pt status dot need over the line of text they share
    /// a row with. Rounding it to 2 or 4 moves every row in the panel.
    private static let lineBoxPad: CGFloat = 3

    // MARK: - Controls

    /// Hit targets and fixed control geometry.
    public enum Control {
        /// A borderless icon button standing alone in a header. The smallest
        /// square that still reads as a target in a menu bar panel.
        public static let iconButton: CGFloat = 24
        /// The same button inside a row's title line, where it shares the line
        /// with type instead of standing alone. This is the *whole* button — the
        /// hover plate included — not a frame wrapped around a 24pt one.
        public static let rowIconButton: CGFloat = 20
        /// The glyph inside either.
        public static let iconGlyph: CGFloat = 12
        /// The status-item mark as drawn in the panel header and the appearance
        /// sample. Not `menuBarGlyphHeight`: that setting sizes the mark in the
        /// menu bar, where the row height is the system's, and a header is not
        /// a menu bar. Named so the two stop being the same literal 16 in two
        /// files with no relationship written down.
        public static let headerGlyph: CGFloat = 16
        /// The mark on the About pane, which is a logo rather than a control.
        public static let aboutGlyph: CGFloat = 44
        /// A provider logo in the settings window, which has no density setting
        /// to size it from.
        public static let settingsLogo: CGFloat = 26
        /// A provider logo in a connect dialog's headline.
        public static let dialogLogo: CGFloat = 34
        /// The dot in front of a status line.
        public static let dot: CGFloat = 6
        /// The dot on a chip, which sits beside caption type rather than body.
        public static let chipDot: CGFloat = 5
        /// Width the connect/disconnect column holds in Settings, so it doesn't
        /// step in and out as services connect. Sized for the longest label the
        /// column carries — "Configure…" — at `.small`, with room for the
        /// ellipsis rather than exactly none.
        public static let actionColumn: CGFloat = 96
        /// The settings sidebar, and the inset that clears the transparent
        /// titlebar it runs underneath.
        public static let sidebarWidth: CGFloat = 176
        public static let titlebarInset: CGFloat = 38
        /// The narrowest a settings pane's form may be before its labels wrap.
        public static let formMinWidth: CGFloat = 460
        /// The Appearance pane's preview column. Here rather than in the pane
        /// because the window's own minimum is derived from it.
        ///
        /// Deliberately not a function of the panel width being previewed. Sized
        /// to the sample, the column grew 80pt as `panelWidth` went 300→386 and
        /// took those 80pt off the form beside it — so dragging the panel-width
        /// slider re-laid out the form that slider is in and walked the thumb out
        /// from under the pointer.
        ///
        /// It is not a promise that every panel fits in it: the widest the
        /// settings allow is 520pt, which with the pane's margins wants 548, and a
        /// column that wide would push the window's minimum past 1180pt. The pane
        /// scrolls the sample instead — which is why that scroll view has to be
        /// given a definite width.
        public static let previewColumn: CGFloat = 420
        /// The narrowest a preset chip may be. The Appearance pane lays them out
        /// in an adaptive grid, so this is the floor that decides how many share
        /// a line — sized for the longest label, "Comfortable", at `Ramp.title`
        /// with the chip's own padding.
        public static let presetChip: CGFloat = 104
        /// The narrowest the settings window can be with all three of its
        /// columns whole, and the shortest it can be with a form and a preview
        /// strip in it.
        ///
        /// Derived rather than written down: as a literal 980 it disagreed with
        /// the columns inside it by 50-80pt, and the column that gave way was
        /// the form — the only one of the three without a fixed frame.
        public static let settingsMinWidth: CGFloat =
            sidebarWidth + formMinWidth + previewColumn + hairline
        public static let settingsMinHeight: CGFloat = 560
        /// A slider and its readout in the Appearance pane.
        public static let sliderWidth: CGFloat = 168
        public static let readoutWidth: CGFloat = 42
        /// A hairline rule drawn as a `Rectangle` rather than a `Divider`.
        public static let hairline: CGFloat = 1
        /// A connect dialog's width. One number, so the two dialogs stop being
        /// 440 and 460.
        public static let dialogWidth: CGFloat = 460

        /// The attention bookmark at a row's leading edge: `RowSpine`.
        ///
        /// Two points is as wide as it goes at rest, and that is the whole idea —
        /// it is the only vertical coloured element in the panel, and it earns
        /// that by being thin enough that a quiet panel reads as a graphite list
        /// with one or two marks down its left margin.
        public static let spineWidth: CGFloat = 2
        /// The same mark under increased contrast, for the reason
        /// `notchWidth(increased:)` widens the pace riser: colour alone cannot
        /// rescue a 2pt mark on a low-contrast display, and a 2pt mark is the
        /// first thing such a display loses. Presence is a non-colour channel and
        /// has to survive being unable to see the colour.
        public static let spineWidthIncreased: CGFloat = 3
        /// How far the mark is held off the card's top and bottom edge, so it
        /// reads as a bookmark laid *in* the card rather than as the card's own
        /// leading edge gaining a colour.
        public static let spineInset: CGFloat = 2
    }

    // MARK: - The menu bar strip

    /// The status item's own geometry.
    ///
    /// Deliberately not on `Space` and not on `Ramp`: that scale is calibrated
    /// for a 300pt panel a user is reading, and this is a 22pt bar they are
    /// glancing at between other people's status items. A 12pt gap that reads as
    /// breathing room in the panel is a hole in the strip.
    ///
    /// Public because `MenuBarStripRenderer`, which draws the strip, and
    /// `StripFit`, which decides how much of it fits, have to be adding up the
    /// same strip. The gap and the figure cell were private literals inside the
    /// renderer, which makes a width contract one side can quietly stop honouring
    /// — and the bug that discipline exists to close is a status item that shoves
    /// its neighbours sideways when a reading crosses 99.
    public enum Strip {
        /// One service's mark-and-figure pair to the next service's.
        public static let segmentGap: CGFloat = 5
        /// A brand mark to its own figure. Narrower than `segmentGap`, so a mark
        /// binds to its number before it binds to the neighbour — that ordering
        /// is what makes "✳92 ◆64" read as two services rather than one run of
        /// debris.
        public static let markGap: CGFloat = 3
        /// Three, because "100" is the widest reading a segment can carry. The
        /// cell is sized from that once and never from the string in hand:
        /// measuring the current figure is exactly what lets 99 → 100 shove every
        /// icon to the strip's left sideways.
        public static let figureDigits: Int = 3

        /// The widest the item may draw. Past this the strip stops being an
        /// indicator and starts pushing other people's status items off the right
        /// of a notched laptop, which is not ours to spend — so the least urgent
        /// segment is dropped instead.
        public static let maxWidth: CGFloat = 148

        /// The figure's point size for a mark of `height`: one point under it.
        /// SF Mono's digits sit inside their line box, so set at the mark's own
        /// height they out-measure the logo beside them and the pair stops
        /// reading as one thing.
        public static func figureSize(height: CGFloat) -> CGFloat {
            height - 1
        }

        /// The reserved cell one figure is drawn in, trailing-aligned like every
        /// other rail in the app, so "7", "100" and the em dash a status-only
        /// service shows all end on the same edge.
        public static func figureCell(height: CGFloat) -> CGFloat {
            figureWidth(figureSize(height: height), digits: figureDigits)
        }
    }

    // MARK: - Fills

    /// `Color.primary` opacities, named by what the fill *means* rather than by
    /// its number. Seven slightly different values were spread across four files
    /// for this handful of meanings, and no call site said which of them it was
    /// reaching for — so a card and a hover plate could be told apart in one file
    /// and not in the next.
    public enum Fill {
        /// A card at rest, under `RowBackground.always`.
        public static let card: Double = 0.05
        /// Any surface under the pointer that was transparent at rest.
        public static let hover: Double = 0.06
        /// A card under the pointer that was already filled — it still has to
        /// lift, or the row stops answering "is this the one I'm about to click".
        public static let cardHover: Double = 0.09
        /// A control's hover plate: icon button, sidebar row, disclosure header,
        /// preset chip. One value, not 0.05/0.07/0.09/0.10.
        public static let controlHover: Double = 0.08
        /// A pill carrying a value: plan name, section count, secondary chip.
        public static let pill: Double = 0.07
        /// A hairline rule, and the border on a floating surface. Read them
        /// through `ruleOpacity(increased:)` and `borderOpacity(increased:)`
        /// rather than directly: both step up under increased contrast.
        public static let rule: Double = 0.07
        public static let border: Double = 0.09

        // `track` and `gradientFloor` were here. The meter track is now
        // `Meter.track`, an explicit pair rather than an opacity, for the reason
        // written on that type; the gradient floor died with the gradient fill.
        // Both deletions are compile-visible on purpose — a caller that kept
        // reaching for the old value would otherwise keep the old look.
        //
        // `divider` (0.5) went with `SwiftUI.Divider`, which is retired from the
        // app. One weight, one colour, one accessor: a 1pt `Rectangle` filled
        // `quiet(ruleOpacity(increased:))`. A `Divider` at half opacity was a
        // second rule weight that only ever appeared where someone had reached
        // for the system control instead, and it was the one rule in the app that
        // did not step up under increased contrast.
    }

    /// `Color.primary` at one of `Fill`'s opacities — the longhand every one of
    /// those literals is currently written in.
    public static func quiet(_ opacity: Double) -> Color {
        Color.primary.opacity(opacity)
    }

    /// The row background opacity for a background setting and a hover state.
    /// One switch for both callers: the panel's rows and the Appearance pane's
    /// sample row each had their own copy, which is how a preview comes to
    /// disagree with the thing it is previewing.
    public static func rowBackground(
        _ style: AppearanceSettings.RowBackground,
        isHovered: Bool
    ) -> Double {
        switch style {
        case .plain:  return 0
        case .hover:  return isHovered ? Fill.hover : 0
        case .always: return isHovered ? Fill.cardHover : Fill.card
        }
    }

    // MARK: - Contrast and elevation

    /// The scrim laid over the panel's one material.
    ///
    /// And the panel's material is the only translucency in the application.
    /// Nothing else — no chip, hover plate, sidebar row, banner, settings pane,
    /// dialog or chart — is drawn on a material, because anything carrying a
    /// number has to be drawn on an opaque ground. That is what makes every
    /// contrast ratio written in this file a statement rather than a hope: a
    /// measured 4.9:1 over `Surface.base` says nothing about the same ink over a
    /// material with someone's wallpaper behind it. `Ink.attentionWash` is the one
    /// named exception, and it is a wash rather than a material.
    ///
    /// Derived, not chosen. At 0.88 a pure-white wallpaper lifts the panel base
    /// by roughly 11 L\* points, while the card steps above it (`Fill.card` 0.05
    /// and `Fill.cardHover` 0.09) are worth about 13 and 23 — so the value
    /// ladder cannot invert on any desktop. Anything thinner and a bright
    /// wallpaper flattens the base into the card sitting on it. Light needs the
    /// extra 0.04 because its base is nearer the wallpaper to begin with.
    ///
    /// Fully opaque under reduce-transparency, where the caller also drops the
    /// material entirely: a scrim over nothing is just a fill.
    public static func scrimAlpha(isDark: Bool, reduceTransparency: Bool) -> Double {
        if reduceTransparency { return 1 }
        return isDark ? 0.88 : 0.92
    }

    /// A hairline rule's opacity, stepped up under increased contrast.
    ///
    /// Functions rather than `if` at each call site: the increased-contrast
    /// branch was the kind of thing that gets applied in three views out of five
    /// and then reads as a bug in the other two.
    public static func ruleOpacity(increased: Bool) -> Double {
        increased ? 0.16 : Fill.rule
    }

    /// A floating surface's border opacity, stepped up under increased contrast.
    public static func borderOpacity(increased: Bool) -> Double {
        increased ? 0.18 : Fill.border
    }

    /// The pace notch's colour. Under increased contrast it takes a pair that
    /// clears the track by more than the 2.5:1 the resting one manages, because
    /// the notch is a 1pt mark and is the first thing a low-contrast display
    /// loses.
    public static func notchColour(increased: Bool) -> Color {
        increased ? dynamic(light: 0x5E5A53, dark: 0x8E8B85) : Meter.notch
    }

    /// How wide that mark is drawn. Two points rather than one is the other half
    /// of the same fix: colour alone cannot rescue a hairline.
    public static func notchWidth(increased: Bool) -> CGFloat {
        increased ? 2 : 1
    }

    // MARK: - Dimming

    /// Opacity applied to a mark to say something about its subject rather than
    /// about the surface under it.
    public enum Dim {
        /// A service switched off in Settings.
        public static let disabled: Double = 0.4
        /// A service that is not connected.
        public static let disconnected: Double = 0.55
        /// A reserved control that is not currently offered. Named because the
        /// value matters: the space stays, only this changes.
        public static let reserved: Double = 0
    }

    // MARK: - Colour

    /// One colour, resolved against the appearance it is drawn in.
    ///
    /// Both windows and the menu bar strip go through this. A fixed value cannot
    /// serve a light panel and a dark one when the same colour is also body
    /// text: the ramp's dark stops sit at 2.2:1–3.9:1 on a light panel, well
    /// under the 4.5:1 a percentage needs to be read as a number rather than as
    /// a decoration.
    ///
    /// This was private inside `UsageTint`, which is why every colour that was
    /// not on the usage ramp had to be a `Color.primary` opacity or a system
    /// colour. It is the same implementation, promoted so the rest of the
    /// palette can have it.
    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:   CGFloat((hex >>  8) & 0xFF) / 255,
                blue:    CGFloat( hex        & 0xFF) / 255,
                alpha:   1
            )
        })
    }

    /// WCAG relative luminance, 0 for black and 1 for white.
    ///
    /// One implementation, because there were two: `BrandMark.luminance` decides
    /// whether a near-black logo needs lifting off a dark menu, and `onAccent`
    /// decides whether text on the user's accent is black or white. Those are
    /// the same question and were being answered by two copies of the same
    /// transfer function.
    ///
    /// Converts to sRGB first rather than trusting the caller: a colour that
    /// arrived from `NSColor(Color)` or from the colour picker can be in any
    /// space, and the coefficients below are only true in sRGB. A colour that
    /// cannot be converted at all — a pattern — answers 0, which puts white text
    /// on it; that is the safe way round for a fill nothing can measure.
    public static func relativeLuminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ raw: CGFloat) -> Double {
            let v = Double(raw)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
             + 0.7152 * channel(srgb.greenComponent)
             + 0.0722 * channel(srgb.blueComponent)
    }

    /// The grounds everything else is drawn on.
    ///
    /// Warm graphite rather than the system's blue-grey, by a +3/+4 offset of
    /// red over blue: enough to read as deliberate beside a default Mac panel,
    /// never enough to read as tinted. It is the one thing that makes the app
    /// look like neither competitor without hard-coding a look.
    ///
    /// This lands cheaply, and the reason is worth writing down: every value in
    /// `Fill` is a `Color.primary` opacity and is therefore *relative* — it
    /// keeps its meaning over any ground. Introducing graphite is adding a base
    /// underneath, not rewriting call sites. `quiet(_:)` and
    /// `rowBackground(_:isHovered:)` are untouched, and every appearance setting
    /// that reaches through them keeps working.
    ///
    /// Elevation has exactly three planes — ground, card, raised — and there is
    /// no fourth. The steps between them are measured and are not free to be
    /// tidied: base→well is 1.09 in light and 1.07 in dark, base→raised 1.10 and
    /// 1.15. Each has to read as a plane change and none of them as a second
    /// material, which is a narrow band: flattened they become one grey, opened
    /// up they start looking like translucency the panel does not have.
    public enum Surface {
        /// The panel ground, the panel header, and the settings form's.
        public static let base = dynamic(light: 0xF6F4F1, dark: 0x1B1A18)
        /// A well sunk into it: the history chart's plot area, the conditional
        /// footer band, a raw-JSON field. Darker than `base` in both appearances,
        /// so it reads as recessed rather than as a card.
        public static let well = dynamic(light: 0xEDEAE6, dark: 0x141312)
        /// A surface with its own edge: the Appearance pane's sample panel, a
        /// banner, a callout, a connect dialog's step block. The one plane that
        /// stands *above* the ground, and the only one that takes a border — a
        /// raised surface is a border plus a ground and never a shadow, which the
        /// app does not have anywhere.
        ///
        /// Lighter in both appearances, and it has to be: dark needs the larger
        /// step (1.15 against light's 1.10) because a near-black ground has less
        /// room below it than a near-white one has above it, so the same ratio
        /// would land a dark card inside the noise of its own base.
        public static let raised = dynamic(light: 0xFFFDFA, dark: 0x282623)
        /// A mark drawn *over* a saturated meter fill — the pace riser where the
        /// fill has already passed it, and the cut punched through the fill to
        /// keep it. The same values as `base` because that is what it is: a hole
        /// punched back through to the ground.
        public static let onFill = dynamic(light: 0xF6F4F1, dark: 0x1B1A18)
    }

    /// The parts of a meter that are not the fill.
    ///
    /// Explicit pairs rather than `Color.primary` opacities, which is the
    /// exception to how every other fill in this file works and is measured
    /// rather than preferred: a single opacity cannot produce an equal
    /// perceptual step in both appearances. The old `Fill.track` 0.12 against a
    /// `Fill.trackElapsed` 0.20 measures 1.44:1 on dark and 1.09:1 on light —
    /// which is to say the elapsed portion of the track was simply invisible in
    /// the light appearance. These values are matched: 1.28:1 light, 1.33:1
    /// dark.
    public enum Meter {
        /// An empty track — bar and ring both.
        public static let track = dynamic(light: 0xDCD8D3, dark: 0x33312E)
        /// The part of the track the window has already spent. The second of
        /// the two quantities the user is comparing, and the one no rival draws.
        public static let trackElapsed = dynamic(light: 0xC4BFB8, dark: 0x46443F)
        /// The pace notch — the riser at the elapsed boundary — where the fill
        /// has not reached it. Read it through `notchColour(increased:)`, which
        /// steps it up under increased contrast. Where the fill *has* reached it
        /// the mark is `Surface.onFill` instead, standing in the cut below.
        public static let notch = dynamic(light: 0x8A857D, dark: 0x6E6B65)
        /// The slot-filler on a row with no meter at all. Same values as
        /// `track`: a status-only service gets a hairline where the bar would
        /// be, never a 0% track. "Reports no quota" and "is at 0%" are different
        /// statements and must not draw the same.
        public static let hairline = dynamic(light: 0xDCD8D3, dark: 0x33312E)

        /// The clearance of ground punched either side of the riser when the fill
        /// has overtaken it — the cut. Without it the riser is a mark of one
        /// colour laid on a saturated fill of another, and at 1pt that reads as a
        /// rendering artefact; with it the riser sits in a slit of `Surface.onFill`
        /// and survives being drawn over its own fill. The length of fill past the
        /// cut is the overspend, which is the reading.
        public static let cutClearance: CGFloat = 1

        /// The bar height below which the cut is not drawn at all, and the riser
        /// carries pace on its own.
        ///
        /// The cut measures the riser plus this clearance either side: 3pt at
        /// rest, 4pt under increased contrast, where `notchWidth` widens the
        /// riser too. `meterThickness` goes down to 3, and a 3pt-wide gap punched
        /// through a 3pt-tall bar is not a slit — it is a broken bar, and a bar
        /// in two pieces says something the user has to stop and reinterpret.
        public static let cutMinBarHeight: CGFloat = 5
    }

    // MARK: - Semantic colour

    /// Colours that mean a state.
    ///
    /// Usage colour is not here and must not come here: every meter, dot and
    /// percentage goes through `AppearanceSettings.tint(for:providerAccent:)`,
    /// which the user configures. This is the small set of states that are not
    /// usage — a connection working, a connection that needs the user, a request
    /// that failed — spelled `.green`, `.orange` and `.red` at four call sites in
    /// three files, with no agreement between them, until they were named here.
    ///
    /// All of them are now explicit pairs rather than system colours, for the
    /// same reason the ramp is: each of these is sometimes text, and `.green` on
    /// a light panel does not clear 4.5:1.
    public enum Ink {
        /// The app's own colour, and the only saturated thing in the chrome.
        ///
        /// Where it may appear, exhaustively: the app mark in the panel header,
        /// the app mark in the About pane, a text link ("open usage page",
        /// "unlock a browser in Settings"), and the `Connect` affordance on a
        /// disconnected row — as `.bordered`, never `.borderedProminent`.
        /// Nowhere else. Never a surface, never a meter, never a row background,
        /// never in the menu bar.
        ///
        /// It is deliberately *not* `AppearanceSettings.accentColor`. That one
        /// is the user's, it defaults to the system accent, and it keeps every
        /// job it has: selected chips, focus rings, primary buttons. The app
        /// having its own colour and the user having theirs are two different
        /// facts and they were being answered by one value.
        /// Measures 4.86:1 on `Surface.base` light, 8.87:1 dark.
        public static let arc = dynamic(light: 0x0E7490, dark: 0x5CC8E0)

        /// Working. Reserved for exactly that: a connected service that is not
        /// answering is not green.
        ///
        /// Green now means one thing and one thing only, because the usage ramp
        /// gave it up — its low stop is a desaturated teal. A meter resting at
        /// 20% and a connection that is up were the same colour, and 0–60% is
        /// where every row sits on a fresh launch, so the ramp was spending the
        /// eye's whole colour budget on the least informative state.
        public static let ok = dynamic(light: 0x1A7F4B, dark: 0x3DD68C)

        /// Needs the user: locked, expired, connected but not responding.
        public static let attention = dynamic(light: 0x8F6100, dark: 0xE0A200)

        /// The request failed outright. Kept distinct from `attention` because
        /// "re-authenticate me" and "the request failed" ask the user for
        /// different things.
        public static let failure = dynamic(light: 0xC62A2F, dark: 0xEC5D62)

        /// Neither: disabled, nothing reported yet, a count of things elsewhere.
        public static let idle: Color = Color.secondary

        /// The wash behind a warning banner, at the weight a banner wants.
        /// Not `dynamic`, because it is the one colour here that is deliberately
        /// translucent: it has to let the surface under it through.
        public static let attentionWash = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.88, green: 0.64, blue: 0.00, alpha: 0.14)
                : NSColor(srgbRed: 0.56, green: 0.38, blue: 0.00, alpha: 0.10)
        })

        /// Text and glyphs on an accent-filled chip.
        ///
        /// A function of the fill, not a constant, and this is the whole point:
        /// the accent is the user's and may be any colour they picked, including
        /// a pale yellow that white text disappears into. The fix for a pale
        /// accent is to darken the *text*; it is never to darken the colour the
        /// user chose, which is what a binary search on their hex would amount
        /// to. 0x101010 rather than pure black so it sits with the panel's warm
        /// graphite instead of punching a hole in it.
        ///
        /// Two consumers: `SelectableChip` below, and `ConnectionFlow`'s `Tone`
        /// mapping.
        public static func onAccent(_ fill: Color) -> Color {
            relativeLuminance(NSColor(fill)) > 0.45 ? Color(hex: 0x101010) : .white
        }
    }
}

/// A pill that is either selected or not: a settings sidebar row, a preset chip.
///
/// One view for both, because they were meant to be the same control and were
/// not — `PresetChip`'s doc comment claimed it was "styled like the settings
/// sidebar rows" while resting at a 0.06 fill the sidebar row didn't have, so
/// two controls in one window disagreed about what "not selected" looks like.
///
/// Resting transparent is the sidebar's behaviour and the right one: a grid of
/// chips that all carry a fill has five things competing with the one that is
/// actually chosen.
public struct SelectableChip: View {
    public let title: String
    /// SF Symbol in front of the title, in a fixed column so a list of these
    /// lines its titles up. Nil centres the title instead, which is what a chip
    /// in a grid wants and a sidebar row does not.
    public let symbol: String?
    public let isSelected: Bool
    public let help: String?
    public let action: () -> Void

    @State private var isHovered = false

    public init(
        title: String,
        symbol: String? = nil,
        isSelected: Bool,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.medium) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.Control.iconGlyph))
                        // A fixed box, so the titles beside four different
                        // symbols start at one x rather than at four.
                        .frame(width: Tokens.Space.xlarge)
                }
                Text(title)
                    .font(.system(
                        size: Tokens.Ramp.title,
                        weight: isSelected ? Tokens.Ramp.emphasisWeight : .regular
                    ))
                    .lineLimit(1)
                    // The title takes the rest of the width and places itself in
                    // it, so a centred chip and a leading row are one view with
                    // one alignment argument rather than two layouts.
                    .frame(maxWidth: .infinity, alignment: symbol == nil ? .center : .leading)
            }
            // The ink is chosen from the fill it lands on, so a chip stays
            // readable whatever accent the user has picked.
            .foregroundStyle(isSelected ? Tokens.Ink.onAccent(background) : Color.primary)
            .padding(.horizontal, Tokens.Space.medium)
            .padding(.vertical, Tokens.Space.small)
            .contentShape(Rectangle())
            .background(Tokens.surface(Tokens.Radius.chip).fill(background))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help ?? "")
        // Which pane you are on is carried by a fill and a weight, neither of
        // which VoiceOver reads. Without this a sidebar of four buttons sounds
        // identical whichever one is open.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Selected wins over hovered: a chip the pointer is resting on is still the
    /// chosen one, and lightening the accent under the pointer reads as the
    /// selection being dragged off it.
    private var background: Color {
        if isSelected { return .accentColor }
        return Tokens.quiet(isHovered ? Tokens.Fill.controlHover : 0)
    }
}

/// One line of prose under a form section.
///
/// Here rather than in a pane because the settings window has one voice for this
/// and three chances to lose it: the Appearance pane had eight sections each
/// saying `.font`, `.foregroundStyle` and `.fixedSize` in their own words, and
/// `SettingsView` still has a private `PaneFooter` that is these same three
/// lines. This is the copy to keep.
public struct SectionFooter: View {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: Tokens.Ramp.caption))
            .foregroundStyle(.secondary)
            // Prose, so it wraps rather than truncating. A footer that is not
            // allowed to grow downward can only ever say one line, and every
            // footer in the window says two.
            .fixedSize(horizontal: false, vertical: true)
    }
}

// ---------------------------------------------------------------------------
// The migration checklist that used to sit here named call sites that no longer
// exist — the Appearance pane's own literals were the last of them. The rule it
// enforced outlives it, and this is the only place left to read it off: a spacing,
// radius or `Color.primary.opacity` written into a view is a value nothing else
// in the app can agree with, so it is named here first. The exceptions are the
// literals derived from a subject's own size rather than from the window's
// rhythm — a logo's tile radius, a glyph's bar width.
// ---------------------------------------------------------------------------
