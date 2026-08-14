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
        /// The 1pt that is not a gap: the space between a title and the caption
        /// directly under it, which is one block of text set in two sizes rather
        /// than two things beside each other.
        ///
        /// Two of its jobs are gone. The nudge that dropped the leading column
        /// onto a cap-height title went because there was nothing to nudge: the
        /// mark box and the title box are both 18pt at defaults, so that 1pt was
        /// a drawn row and a reserved height disagreeing by a point in two
        /// files. The plan pill's vertical padding went with the pill.
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
        ///
        /// Ten rather than eleven now the mark is 18pt and sits on the ground
        /// with no plate around it: a tile carried its own visual margin, and a
        /// bare glyph needs the gap to be a little tighter to bind to the name
        /// beside it rather than float between the edge and the text.
        public static let leadingColumn: CGFloat = 10
        /// Logo to dial inside that column: the spacing of the `leading` stack
        /// in both rows, and the gap `AppearanceSettings.ringBudget` subtracts
        /// along with the logo when it decides how wide a dial may be — which is
        /// why this one is not free to move far.
        ///
        /// Six, and therefore `small`, rather than the 7 it was. Seven was the
        /// last value in the file sitting between two steps of its own scale,
        /// which is the thing this scale exists to stop; and it is cheap to fix
        /// because only `.ring` puts two items in this column at all, so the
        /// change moves `leadingWidth` by 1pt under one logo style and nothing
        /// else in the panel.
        public static let leadingItems: CGFloat = small
        /// Panel header: above the title line, and below it to the divider.
        /// Asymmetric because the divider reads as part of the bottom edge.
        ///
        /// Both grew a couple of points when the header lost its subtitle: one
        /// line of type in the same box reads as cramped where two read as
        /// full, and the header is the only place in the panel that is allowed
        /// to be generous, because nothing repeats down the list behind it.
        public static let headerTop: CGFloat = 12
        public static let headerBottom: CGFloat = 11
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
        /// A borderless icon button's hover plate, and the disclosure plate.
        /// Six rather than five: at a 22pt plate a 5pt corner reads as almost
        /// square beside a 6pt chip and an 8pt card sitting directly under it,
        /// and three radii inside 3pt is noise rather than a hierarchy.
        public static let control: CGFloat = 6
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
        /// Prose footers, slider readouts, axis labels, and a heading that stands
        /// directly over a column of figures set at this same size — `DayHeaderRow`
        /// in the History pane, whose own comment (`HistoryPane.swift:678-680`)
        /// gives the reason: a heading set larger than the column under it reads
        /// as a title for the pane rather than as a label for the column.
        ///
        /// A group header over a *block of rows* is `Ramp.detail`, not this. That
        /// is stated ninety lines below ("a group header is a word — sentence
        /// case, `Ramp.detail`, `Ink.muted`") and the code has always agreed:
        /// `MenuBarContentView.sectionFontSize` returns `detail`, and both
        /// `DisclosureHeader.fontSize` and `SectionLabel.fontSize` default to it.
        /// This line claimed the header rung anyway, which left the file
        /// contradicting itself twice on one page and offering the next caller a
        /// choice of two sizes for the same heading.
        public static let caption: CGFloat = 10

        /// A name, a figure, the `Sign in` word, an icon glyph — anything that
        /// is the answer rather than the context.
        ///
        /// Medium, not semibold. Nine semibold names down a 356pt panel is the
        /// panel shouting, and hierarchy in a quiet dark UI comes from colour
        /// and space rather than from weight — `Ink.body` against `Ink.muted`
        /// separates a name from its caption further than a weight step does.
        /// It also closes a divergence that had no business existing: the panel
        /// set a row title at `emphasisWeight` and the Appearance preview set
        /// the same title at `titleWeight`, so the preview drew heavier than the
        /// thing it was previewing. They resolve to one weight now.
        ///
        /// There are two weights in the app and an alert, and this is the whole
        /// rule: subjects and figures take this, everything that is context —
        /// captions, labels, countdowns, units, error sentences, `Checking…` —
        /// is `.regular`, and a figure at or above the warning threshold is
        /// `alertWeight`. `.regular` is deliberately not named here: it is the
        /// system's own default and the weight this ramp is measured against, so
        /// a token for it would only invite a fourth. It does have to be written
        /// at the call site rather than inherited, because a caption that
        /// inherits from a `.medium` container is a third weight nobody chose.
        /// HIG: never lighter than Regular.
        public static let titleWeight: Font.Weight = .medium
        /// A figure at or above `warningThreshold`. The only weight in the app
        /// heavier than `titleWeight`, so the change at the threshold cannot
        /// be read as anything else — it is one of the three channels that carry
        /// near-cap, and one of the two that survive a greyscale screenshot. The
        /// other two are the fill's square trailing cap and a bar that is
        /// visibly full; the coloured spine that used to be a fourth is gone,
        /// and its share of the work is why this one cannot be softened.
        ///
        /// Safe to cross mid-line, and that is measured rather than assumed: SF
        /// Pro's cap height at 13pt is 9.1597 at regular, medium, semibold *and*
        /// bold, while x-height moves 6.843→6.989. A threshold crossing changes
        /// the stem weight and cannot shift the axis the row is aligned on.
        public static let alertWeight: Font.Weight = .semibold

        // `emphasisWeight` was here, at `.medium` — the same value as
        // `titleWeight`, under a name that promised a step up and delivered
        // nothing. Twenty-odd call sites across nine files were asking for
        // emphasis and getting the title weight, which is why the panel read as
        // one flat weight with no contrast in it: the contrast was supposed to
        // come from a token that had quietly been flattened into its neighbour.
        // They all take `titleWeight` now, and the captions beside them say
        // `.regular` out loud, which is where the contrast actually was.
        /// Percentages and any figure the eye scans down a column.
        ///
        /// **SF Pro with tabular figures, not SF Mono.** The columns were never
        /// the font — they are `figureWidth`'s reserved rails and the fixed digit
        /// advance inside them, and `.monospacedDigit()` gives both of those on
        /// the system face. What SF Mono added on top was its *voice*: a coding
        /// face has slab terminals, an exaggerated aperture and a slashed zero,
        /// and eleven rows of it down a panel read as a terminal window rather
        /// than as an instrument. Every figure in the app is one word next to a
        /// word set in SF Pro, and two faces on one line is a seam the eye finds
        /// before it finds the reading.
        ///
        /// So the rule that used to say "digits take SF Mono, prose takes SF Pro
        /// with `.monospacedDigit()`" collapses to its second half: **everything
        /// is SF Pro, and everything with a digit in it is tabular.** There is no
        /// judgement left at a call site, which is one fewer than before.
        ///
        /// The clause that turns "we use tabular figures" into "we have columns"
        /// is unchanged and is the load-bearing one: every figure run lives inside
        /// a reserved, fixed-width, trailing-aligned rail from `figureWidth`
        /// below. Tabular digits fix the width of a digit, not the length of a
        /// string — `9%` still reflows to `92%` — so the rail is what stops a
        /// reading from moving its neighbours, and a figure free to size itself
        /// is just a font choice.
        ///
        /// The *reserved* and *fixed-width* halves of that are unconditional. The
        /// *trailing* half has one exception, and it is the menu bar strip, where
        /// the figures sit side by side rather than stacked: with no column to
        /// align to, trailing alignment spends a cell's slack between a figure and
        /// its own mark instead of after it. `Tokens.Strip.figureCell` reserves the
        /// width and `StripFigure` — in `StripStyle.swift` — owns that one decision.
        ///
        /// Reached through `figureFont` below and never through
        /// `Text.monospaced()`. That method is `macOS 13.3`; the `View` overload
        /// is 13.0, and wherever the receiver is statically a `Text` the compiler
        /// binds the 13.3 one and silently raises the app's floor past the stated
        /// minimum with no diagnostic. `Font.Design` carries no availability at
        /// all, and `Font.monospacedDigit()` is macOS 12 and safe.
        public static let figureDesign: Font.Design = .default

        /// The face every figure in the app is set in: the system font at
        /// `figureDesign`, with its digits made tabular.
        ///
        /// One function rather than `design:` at thirty call sites, because the
        /// tabular feature is not a `Font.Design` and a call site that took the
        /// design and forgot the feature would draw proportional digits — which
        /// is invisible until a 1 follows a 4 and the column twitches. Asking for
        /// the font in one place makes that unrepresentable.
        public static func figureFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: figureDesign).monospacedDigit()
        }
    }

    // `sectionTracking` was here, and the uppercased group header it was for is
    // gone with it. Tracking is now zero everywhere in the app: SF ships optical
    // tracking per size and correcting it is how house type starts disagreeing
    // with every native label beside it. The negative tracking the reference
    // dark tools use is an Inter correction and does not transfer to SF.
    //
    // A group header is a word — sentence case, `Ramp.detail`, `Ink.muted` — not
    // a rule with a word on it.

    /// Width of `digits` tabular digit cells at `size`.
    ///
    /// Tabular figures fix the width of a digit, not the length of a string:
    /// `9%` still reflows to `92%` and drags the label beside it. Every figure
    /// column is therefore reserved, and this is the width to reserve it at.
    ///
    /// **Measured, not a ratio.** It used to be `size * 0.6185`, which was SF
    /// Mono's advance ratio on this platform — exact, because a mono face has one
    /// advance at every size and weight. SF Pro does not: its tabular digit runs
    /// 0.648 of the point size at 9pt and 0.610 at 16pt as the optical size
    /// changes, and another 4% wider again at semibold. A single constant is
    /// therefore either too narrow somewhere or too wide everywhere, and too
    /// narrow is a rail a reading escapes. So the cell is measured off the real
    /// face, at the heaviest weight a figure can take, and cached per size.
    ///
    /// The unit letters are *not* one of these cells any more and that is the
    /// other half of the face change. In SF Mono `%` and `M` measured exactly a
    /// digit; in SF Pro `%` is 1.47× a digit and `M` is 1.39×, while `.`, `,` and
    /// `/` are about half. A rail that counted a `%` as a digit cell was 4pt
    /// short of `100%` at 13pt — `unitWidth` below is what the call sites that
    /// draw a unit ask for instead, and every one of them already had it as a
    /// separate `+ figureWidth(unitSize, digits: 1)` term.
    /// **And measured at the weight the run is drawn in**, which a mono face
    /// never had to care about. SF Pro's tabular digit is 1.7% wider at medium
    /// than at regular and 3.5% wider at semibold, and those percents decide
    /// whole chips: at the shipped 356pt panel the difference between reserving
    /// a chip's runs at semibold and at the weights they are actually set in is
    /// the difference between one chip on the line and two. The default is the
    /// heaviest, because a caller who has not thought about it should get the
    /// rail that cannot be escaped; the three call sites that know their run is
    /// lighter say so.
    public static func figureWidth(
        _ size: CGFloat,
        digits: Int,
        weight: Font.Weight = Ramp.alertWeight
    ) -> CGFloat {
        guard size.isFinite, digits > 0 else { return 0 }
        return (figureAdvances(at: size, weight: weight).digit * CGFloat(digits)).rounded(.up)
    }

    /// The reserved cell for one unit letter — `%`, `M`, `k`, `$` — at `size`.
    ///
    /// The widest of them rather than the one in hand, for the same reason the
    /// digit cell is a cell: a rail sized to `k` and then asked to draw `M` is a
    /// rail a reading escapes, and `644.6k` becoming `644.6M` is a thing that
    /// happens to a real account between two refreshes.
    public static func unitWidth(_ size: CGFloat, weight: Font.Weight = Ramp.alertWeight) -> CGFloat {
        guard size.isFinite else { return 0 }
        return figureAdvances(at: size, weight: weight).unit.rounded(.up)
    }

    /// The two advances every rail in the app is cut from, measured off the face
    /// `Ramp.figureFont` actually draws in and cached per size and weight.
    ///
    /// Cached because `figureWidth` is called from row geometry — a dozen times
    /// per row per layout pass — and a `CTLine` per call is not free. The lock is
    /// there because geometry is asked for off the main actor in the tests as
    /// well as on it in the app.
    static func figureAdvances(
        at size: CGFloat,
        weight: Font.Weight = Ramp.alertWeight
    ) -> (digit: CGFloat, unit: CGFloat) {
        advanceCache.value(for: Advance(size: size, weight: weight), otherwise: measureFigureAdvances)
    }

    /// `Font.Weight` is opaque and `NSFont.Weight` is a `CGFloat`, and only the
    /// second can be measured. Four cases because four are what the app draws;
    /// anything else answers the heaviest, which is the safe direction.
    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        default: return .bold
        }
    }

    private struct Advance: Hashable {
        let size: CGFloat
        let weight: Font.Weight
    }

    private static func measureFigureAdvances(_ key: Advance) -> (digit: CGFloat, unit: CGFloat) {
        let system = NSFont.systemFont(ofSize: key.size, weight: nsWeight(key.weight))
        let descriptor = system.fontDescriptor
            .addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                ]]
            ])
        let font = NSFont(descriptor: descriptor, size: key.size) ?? system
        func advance(_ glyph: String) -> CGFloat {
            (glyph as NSString).size(withAttributes: [.font: font]).width
        }

        // `8` rather than `0`: tabular or not, they are one advance, and `8` is
        // the one that is still the widest glyph in the set if the feature ever
        // fails to apply.
        return (
            digit: advance("8"),
            unit: ["%", "M", "k", "$"].map(advance).max() ?? advance("8")
        )
    }

    private static let advanceCache = AdvanceCache()

    /// A lock and a dictionary, and it is a class so that `Tokens` can stay an
    /// uninstantiable namespace of `static let`s with no mutable state of its own.
    private final class AdvanceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Advance: (digit: CGFloat, unit: CGFloat)] = [:]

        func value(
            for key: Advance,
            otherwise measure: (Advance) -> (digit: CGFloat, unit: CGFloat)
        ) -> (digit: CGFloat, unit: CGFloat) {
            lock.lock()
            defer { lock.unlock() }
            if let hit = storage[key] { return hit }
            let measured = measure(key)
            storage[key] = measured
            return measured
        }
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
    ///
    /// A column, though, and only a column. The Budget pane stacks four amounts
    /// vertically and their decimals have to line up, so it reserves this. The
    /// panel's row does not: there is at most one spend figure on a row and
    /// nothing above or below it to line up with, so reserving the rail there
    /// only indented the caption that follows it by whatever slack the current
    /// amount left — an indent that moved as the bill grew. A rail is worth
    /// paying for where there is a column, and nowhere else.
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
        /// square that still reads as a target in a menu bar panel — four of
        /// them sit on the header line, and at 24 they were a row of plates
        /// competing with the wordmark they share the line with.
        public static let iconButton: CGFloat = 22
        /// The same button inside a row's title line, where it shares the line
        /// with type instead of standing alone. This is the *whole* button — the
        /// hover plate included — not a frame wrapped around a 22pt one.
        ///
        /// Eighteen, which is also the logo box, and that is not a coincidence:
        /// it is the row's title-line height, so the reserved action column and
        /// the leading mark agree on how tall a row's first line is.
        public static let rowIconButton: CGFloat = 18
        /// The glyph inside either.
        public static let iconGlyph: CGFloat = 12
        /// The square a row's figure rail draws a glyph in, when what the rail
        /// has to say is not a number: the error triangle, the status dot.
        ///
        /// Fixed, and that is the whole reason it exists. Measured at 11pt,
        /// `exclamationmark.triangle.fill` renders 14×13, `lock.fill` 11×13 and
        /// `arrow.clockwise` 12×14 — so a rail sized to whichever symbol is
        /// currently in it moves the row's right edge by up to 3pt as a service
        /// changes state, and two rows six apart in the same list disagree about
        /// where the rail is. One box, centred, whatever goes in it.
        public static let railGlyph: CGFloat = 14
        /// The status-item mark as drawn in the panel header and the appearance
        /// sample. Not `menuBarGlyphHeight`: that setting sizes the mark in the
        /// menu bar, where the row height is the system's, and a header is not
        /// a menu bar. Named so the two stop being the same literal in two
        /// files with no relationship written down.
        ///
        /// Fourteen: one point over the 13pt wordmark beside it, so the mark
        /// reads as the wordmark's companion rather than as a logo the title has
        /// been placed against.
        public static let headerGlyph: CGFloat = 14
        /// The mark on the About pane, which is a logo rather than a control.
        public static let aboutGlyph: CGFloat = 44
        /// A provider logo in the settings window, which has no density setting
        /// to size it from.
        public static let settingsLogo: CGFloat = 26
        /// A provider logo in a connect dialog's headline.
        public static let dialogLogo: CGFloat = 34
        /// The one status dot the panel draws: proof of connection on a service
        /// that reports a state rather than a quota, in the figure rail. It used
        /// to sit in front of the status line, which put a glyph ahead of text on
        /// a detail line and indented that one line past every other.
        ///
        /// It was "the one green dot" until green left the palette. It is drawn
        /// in `Ink.body` now and reads as a *lit* dot against the `Ink.muted` the
        /// same rail takes for a service that is not reporting — a two-state pair
        /// with 2.22:1 light and 2.23:1 dark between its halves, which is a
        /// stronger signal than a hue nobody had to be taught was good news.
        public static let dot: CGFloat = 6
        /// The dot on a chip, which sits beside caption type rather than body.
        public static let chipDot: CGFloat = 5
        /// The trace in a row's sparkline.
        ///
        /// One point, not the chart's 1.5: that width is tuned for a 144pt plot
        /// where a trace crosses several hundred points of well, and the same
        /// stroke over an 18pt box twelve points wide per bucket is a ribbon
        /// rather than a line. Not stepped up under increased contrast and not
        /// snapped either — `Tokens.Control.snap` is for axis-aligned rules, and
        /// snapping the vertices of a diagonal only moves the blur along the line.
        public static let sparklineStroke: CGFloat = 1
        /// A one-bucket trace, which is a point rather than a line, drawn as one.
        /// Three points across: half of `dot`, because the status dot is the only
        /// proof of connection a quotaless row has and this is context under a
        /// meter that has already said the number.
        public static let sparklineDot: CGFloat = 3
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
        /// The narrowest a strip-style chip may be. Sized for the widest sample
        /// any chip draws — mark + figure at three services is 130pt at the 13pt
        /// height the chips are fixed at (`Strip.chipPreviewHeight`) — plus the
        /// chip's own 8pt of horizontal padding each side.
        ///
        /// It was 144 for a 127pt sample. The figure cell is measured off the
        /// face now rather than off SF Mono's one advance, and SF Pro's semibold
        /// digit is 5% wider, so the same three services measure 130 and the chip
        /// follows them. A chip narrower than its own sample does not clip it —
        /// the grid drops a column instead, which is the whole six-chip row
        /// rearranging itself because a digit got wider.
        public static let stripStyleChip: CGFloat = 148
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
        /// Seven cells, not six, and derived rather than written down — which is
        /// the rule stated at `figureWidth` above ("every figure run lives inside
        /// a reserved, fixed-width rail from `figureWidth`") applied to the one
        /// rail in the app that had been given a literal instead.
        ///
        /// `AppearancePane.pointReadout` writes the half-point form at every
        /// half-step of the Thickness slider, and "10.5 pt" is seven characters:
        /// inside the 42 this used to be, it truncated to "10.5 …" — a readout
        /// that cannot print its own value. `AlertsPane.AlertColumn.age` had
        /// already worked this out and spelled `figureWidth(Ramp.caption,
        /// digits: 7)` in its own words.
        public static let readoutWidth: CGFloat = figureWidth(Ramp.caption, digits: 7)
        /// The shortcut field in General. Sized for the widest thing it can
        /// print — ⌃⌥⇧⌘ plus `Space`, four glyphs and five letters at
        /// `Ramp.title` — measured at 78pt of type inside two `Space.medium`
        /// insets, rounded up to clear the field's own border. Fixed, because the
        /// string inside it changes length as the user records and a field that
        /// sized itself to the combination would move the "Clear" button beside
        /// it every time.
        public static let recorderWidth: CGFloat = 116
        /// And its height, which is deliberately the same 22 as `iconButton`:
        /// there is one small-control height in this app and this is it.
        public static let recorderHeight: CGFloat = iconButton
        /// The recorder's own border while it is waiting for a keystroke. A
        /// step above `borderOpacity(increased:)` because a field that is
        /// listening has to be distinguishable from a field that is merely
        /// enabled, and the app has no focus ring of its own to spend here.
        public static let recorderListeningBorder: Double = 0.28
        /// A hairline rule drawn as a `Rectangle` rather than a `Divider`, in
        /// points, at the system's own weight: `NSBox(.separator)` reports an
        /// intrinsic height of 1 and `NSSplitView.dividerThickness` is 1.0.
        ///
        /// A point, not a pixel — and on a Retina display those are not the same
        /// rule. One point of grey at 2× lights two device pixels, which is
        /// twice the ink the system's own separator lays down and reads as a soft
        /// grey band rather than as a line.
        ///
        /// So the app draws rules at two weights on purpose, and which one a rule
        /// takes is a question about what the rule is for rather than about where
        /// it is. Chrome — an edge between the app's own furniture — takes
        /// `hair(scale:)` below: the panel's header rule
        /// (`MenuBarContentView.swift:159`), the connect dialog's
        /// (`BrowserLoginView.swift:111`) and the Appearance preview's own copy of
        /// the header rule (`AppearancePane.swift:777`). Two rules genuinely want
        /// the point and keep this value: the Appearance pane's column rule
        /// (`AppearancePane.swift:95`), whose 1pt is budgeted into
        /// `settingsMinWidth` above, and the History table's head rule
        /// (`HistoryPane.swift:738`), which is a table's ruling at the weight the
        /// system rules a table at and sits beside chart marks drawn at the same
        /// weight.
        ///
        /// This paragraph used to say there was one rule in the app, that it was
        /// the panel header's, and that it snapped its offset. All three were
        /// false — there were five rules at three spellings, `hair(scale:)` had no
        /// callers at all, and `Control.snap`'s only caller is
        /// `HistoryChart.swift:289`, a chart gridline rather than a rule. The
        /// three device-pixel rules now go through the one accessor; the snapping
        /// claim is dropped rather than corrected, because no rule needs it:
        /// `MenuBarContentView.swift:143-146` argues that whole-point gaps above
        /// the rule already land it on the grid.
        public static let hairline: CGFloat = 1

        /// One device pixel at `displayScale`: 0.5pt at 2×, 1pt at 1×.
        ///
        /// The thinnest line the display can draw, which is what a hairline is
        /// supposed to be. Read `@Environment(\.displayScale)` and pass it — a
        /// view cannot be trusted to guess 2× and the app runs on 1× externals.
        /// A scale of 0 (which nothing should report, but a stub or a snapshot
        /// host can) answers `hairline` rather than dividing by zero.
        public static func hair(scale: CGFloat) -> CGFloat {
            scale > 0 ? 1 / scale : hairline
        }

        /// `value` moved to the nearest device pixel boundary at `displayScale`.
        ///
        /// A half-point rule drawn at a fractional offset is resampled across two
        /// pixel rows at half strength each — the blur the previous rule had, and
        /// the reason thinning it alone does not help. Snap the offset as well as
        /// the thickness, or the line lands between pixels.
        public static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
            scale > 0 ? (value * scale).rounded() / scale : value.rounded()
        }
        /// A connect dialog's width. One number, so the two dialogs stop being
        /// 440 and 460.
        public static let dialogWidth: CGFloat = 460

        // `spineWidth`, `spineWidthIncreased` and `spineInset` were here, for the
        // coloured bookmark down a row's leading edge. The mark is deleted, and
        // the reason is that nobody could read it: it was the one vertical
        // coloured element in the panel, it meant two different things depending
        // on why it was there, and its meaning could not be recovered from
        // looking at it. Near-cap keeps three channels without it, and "this one
        // needs you" is now the word `Sign in`, in the row's own figure rail,
        // which names the action on the line the state belongs to. The amber
        // `lock.fill` that briefly stood there is gone too, for the smaller
        // version of the same reason: a padlock asks the user to decode a glyph
        // where two words tell them what to click.
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
    ///
    /// It is now the *whole* of that arithmetic and not just the shared half.
    /// `StripFit` kept private copies of `markGap`, `segmentGap`, `figureDigits`,
    /// `markBox` and `figureSize`, and two of the five had already drifted: its
    /// `figureSize` guarded a non-finite height and floored at 1 where this one
    /// did neither, so at a height of 0.5 the renderer set a font from one
    /// definition and reserved a cell from the other. Every number a strip style
    /// may use is here now, each of them pure, each taking only a height, and each
    /// returning a whole point — which is what makes "no style's cell width can
    /// depend on a reading" a property of the signatures rather than a rule
    /// somebody has to keep remembering.
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
        /// Twelve, and the number is measured rather than chosen. `worstOnly`
        /// spells the service out, and a rail sized to the name in hand would move
        /// the item every time one service overtook another — the 99 → 100 bug
        /// arriving through a wider door. So the rail is reserved in digit cells,
        /// and twelve is the largest count that keeps the whole style inside
        /// `maxWidth` at every height the settings allow: at a 16pt mark twelve
        /// comes to 116 + 3 + 29 = 148, exactly the cap, and thirteen overflows it
        /// by nine.
        ///
        /// **The documented ellipsis is gone.** Twelve mono advances used to leave
        /// "GitHub Copilot" — 67.459pt of semibold at 9pt — a fraction over a 67pt
        /// rail, so at `menuBarGlyphHeight == 10` and only there the widest shipped
        /// name took a tail ellipsis. The cell is measured off the drawn face now
        /// and SF Pro's tabular digit is wider than SF Mono's at these sizes, so
        /// the same twelve cells are 73pt and the name fits. Every shipped name
        /// now clears its rail at every height, with the widest at 10pt measuring
        /// 67.46 in 73, at 13pt 86.83 in 95, and at 16pt 105.25 in 116.
        public static let nameDigits: Int = 12

        /// The widest the item may draw. Past this the strip stops being an
        /// indicator and starts pushing other people's status items off the right
        /// of a notched laptop, which is not ours to spend — so the least urgent
        /// segment is dropped instead.
        public static let maxWidth: CGFloat = 148

        /// A meter's empty channel, as an opacity on the strip's neutral and never
        /// as `Tokens.Meter.track`. A template image keeps its alpha and discards
        /// its hue, so an opaque grey track becomes full-strength ink and a micro
        /// bar reads 100% at every level. At 0.30 the empty channel measures 2.10:1
        /// on a light bar and 2.73:1 on a dark one — deliberately under the 3:1 a
        /// meaningful graphic wants, because the channel is not the reading; the
        /// fill is, and it stands 3.4× the channel's ink in the monochrome case
        /// where nothing else tells them apart.
        public static let trackOpacity: Double = 0.30
        /// The rule the micro bars stand on, at `AppMark`'s own value. It measures
        /// 4.62:1 light and 5.92:1 dark, so the axis survives being the quietest
        /// thing in the strip.
        public static let baselineOpacity: Double = 0.55

        /// The height every drawing in the strip is actually laid out in.
        ///
        /// Rounded, and that is the fix rather than a tidy-up: the tuner offers
        /// half points, and at 13.5 the mark box was 13.5 wide, so the figure cell
        /// began at x = 16.5 and every boundary after it landed between pixels. The
        /// rasteriser rounds only the total width, so the interior was resampled
        /// and a 13.5pt strip read softer than a 13pt one at 1×. Guarded for the
        /// reason `MenuBarEntry` guards its percentage: this is public and pure,
        /// the value reaches it from a store that can hold anything, and a
        /// non-finite height survives every `max` and then traps in the rounding
        /// inside `figureWidth`.
        public static func markBox(height: CGFloat) -> CGFloat {
            guard height.isFinite else { return 1 }
            return max(1, height.rounded())
        }

        /// The figure's point size: one under the mark. A digit sits inside its
        /// line box, so at the mark's own height it out-measures the logo beside
        /// it. Guarded like `markBox`, and now the single definition — the
        /// unguarded copy here and the guarded one in `StripFit` disagreed about a
        /// height of 0.5, one of them setting the font and the other reserving the
        /// cell it had to fit in.
        public static func figureSize(height: CGFloat) -> CGFloat {
            guard height.isFinite else { return 1 }
            return max(1, (height - 1).rounded())
        }

        /// The reserved cell for one figure, sized from the widest reading the
        /// strip can produce and never from the string in hand.
        ///
        /// The reserved width, and only that. Where the figure sits *inside* the
        /// cell is stated once, at `StripFigure` in `StripStyle.swift`, and
        /// deliberately not restated here: this doc and `StripFit.figureCell`'s
        /// both used to call the cell trailing-aligned "like every other rail in
        /// the app" while the view drew it leading and recorded, beside the
        /// drawing, that trailing had been measured and rejected. Two copies of an
        /// alignment rule are what produced that, so correcting both copies would
        /// only rearm it; there is one copy now and it lives with the drawing.
        public static func figureCell(height: CGFloat) -> CGFloat {
            figureWidth(figureSize(height: height), digits: figureDigits)
        }

        /// The reserved rail a service *name* is drawn in, on the styles that
        /// spell a service out instead of marking it. Twelve mono advances, for
        /// the reason on `nameDigits`.
        public static func nameCell(height: CGFloat) -> CGFloat {
            figureWidth(figureSize(height: height), digits: nameDigits)
        }

        /// A meter column's width. 0.38 of the mark box, which lands on 5pt at the
        /// shipped 13pt mark — wide enough that a 1pt fill at the bottom of the
        /// channel is a bar rather than a speck, narrow enough that three of them
        /// plus their gaps stay inside a third of what mark-plus-figure costs.
        public static func meterColumn(height: CGFloat) -> CGFloat {
            max(3, (markBox(height: height) * 0.38).rounded())
        }

        /// The micro-bar drawing, in `AppMark`'s own proportions and rounded the
        /// same way. Not a coincidence and not a copy to keep in step: the app's
        /// mark *is* four bars on a baseline, it used to carry live levels, and
        /// `microBars` is that drawing given back its levels and one column per
        /// named service.
        public static func meterPlot(
            height: CGFloat
        ) -> (baseline: CGFloat, gap: CGFloat, plot: CGFloat) {
            let h = markBox(height: height)
            let baseline = max(1, (h * 0.09).rounded())
            let gap = max(1, (h * 0.11).rounded())
            return (baseline, gap, max(1, (h - baseline - gap).rounded(.down)))
        }

        /// A meter column with no baseline under it, centred in the box.
        public static func barePlot(height: CGFloat) -> CGFloat {
            max(3, (markBox(height: height) - 2).rounded())
        }

        /// The height every chip in the style chooser draws its sample at.
        ///
        /// Fixed at the shipped 13 and never at the live setting. Six chips that
        /// resized with the height tuner would re-flow the grid the tuner sits in
        /// and walk the thumb out from under the pointer — the same fault
        /// `Tokens.Control.previewColumn` was made a constant to avoid. The tuner's
        /// own effect is shown in the "Preview" row below it, at the live height.
        public static let chipPreviewHeight: CGFloat = 13
    }

    // MARK: - Fills

    /// Ink opacities, named by what the fill *means* rather than by its number.
    /// Seven slightly different values were spread across four files for this
    /// handful of meanings, and no call site said which of them it was reaching
    /// for — so a card and a hover plate could be told apart in one file and not
    /// in the next.
    ///
    /// "Ink" and no longer "`Color.primary`": these are read through `quiet(_:)`,
    /// which lays down pure black or pure white at the stated alpha. It used to go
    /// through `Color.primary`, which is `NSColor.labelColor` at alpha 0.8471, and
    /// `Color.opacity(_:)` multiplies — so every value below was drawing 84.71% of
    /// the ink it names and every ΔL\* recorded against it was 15% optimistic. The
    /// numbers here did not move when that was fixed, because they were authored
    /// as pure-ink alphas in the first place; see `quiet(_:)` for the arithmetic.
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
        /// Any surface under a finger that is going down: a row card, an icon
        /// button's plate. The step above every hover value here, in every row
        /// background style, so "I am about to act on this" always reads as
        /// darker than "I am pointing at this".
        ///
        /// The panel had no pressed state at all — a 66pt target that lit on
        /// hover and then said nothing whatsoever when clicked, which is the
        /// single clearest tell that software is a side project rather than a
        /// shipped thing. Press feedback is a fill and only a fill: no scale, no
        /// shadow, no geometry change, because a row that moves under the pointer
        /// moves the thing being clicked.
        public static let pressed: Double = 0.12
        /// The neutral container a brand mark sits in when `logoStyle` is
        /// `.tile`. Named here rather than written into `BrandMark` because a
        /// tile is a container or it is nothing: one neutral plane in every
        /// appearance and for every brand, and the tinted version of it — brand
        /// hue, a tint floor and a hairline stroke — is what made the panel read
        /// as 2015 iOS. It draws no stroke either. A fill *and* an edge is two
        /// edges for one container.
        ///
        /// It kept the plan pill's 0.07 when the pill went, because the number
        /// was never the pill's: 0.07 over `Surface.base` is the quietest plane
        /// that still reads as a plane. It is a **1.1681 step in light and 1.1653
        /// in dark** — the two halves agree to three thousandths, and that
        /// agreement is what a relative opacity was always supposed to buy. They
        /// were recorded as 1.165 and 1.186 while `quiet(_:)` was multiplying by
        /// `Color.primary`'s hidden 0.8471, which moved the two appearances by
        /// different amounts because L\* is compressive near black. (The pair was
        /// also written down the wrong way round — 1.165 is the dark half.)
        ///
        /// **Both figures are against `Surface.base`, and that is a simplifying
        /// ground rather than the one the panel draws on.** Over the *composited*
        /// panel — `scrimAlpha` over whatever desktop is behind it — the two part
        /// company: sampled off the rendered snapshot, the same 0.07 measures
        /// 1.3019:1 in dark and 1.1234:1 in light, because the two composited
        /// grounds are not mirror images of each other and a fixed alpha cannot
        /// make them one. Nothing here is cut for that ground and nothing can be:
        /// it depends on the user's wallpaper. `Surface.base` is quoted because
        /// it is the one plane that is the same in every drawing, which is the
        /// same convention `UsageRampContrastTests` records its table on.
        public static let logoTile: Double = 0.07
        /// A hairline rule, and the border on a floating surface. Read them
        /// through `ruleOpacity(increased:)` and `borderOpacity(increased:)`
        /// rather than directly: both step up under increased contrast.
        ///
        /// There is exactly one rule left in the panel, under the header. The
        /// one that ran along a section label's trailing edge is deleted with
        /// the rest of that furniture.
        public static let rule: Double = 0.07
        public static let border: Double = 0.09

        // `pill` (0.07) was here, for the plan capsule on a row's title line,
        // and the pill is deleted. It was the last filled shape in the panel
        // after the chips and the section count went to plain text, and it
        // failed the way a fill with no width discipline does: `Text(plan)` had
        // `lineLimit(1)` and no `fixedSize()` while the name beside it held
        // `layoutPriority(1)`, so at 300pt the capsule squeezed to nothing and
        // still drew its padding and its fill — a bare 12×22pt grey blob after a
        // truncated name. The plan is a word in the caption's own run now, and
        // `logoTile` inherited the number.
        //
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

    /// `Color.primary` at one of `Fill`'s opacities — except that it is not
    /// `Color.primary`, and that is the correction.
    ///
    /// `Color.primary` resolves to `NSColor.labelColor`, which is black or white
    /// at **alpha 0.8471**, and `Color.opacity(_:)` multiplies. So every value in
    /// `Fill` was laying down 84.71% of the ink it names: `card` 0.05 composited
    /// at 0.0424, and a hovered `.always` row card measured `#E4E5E7` light /
    /// `#222326` dark rather than the `#E1E2E4` / `#262629` this file and
    /// `GlyphColourTests` both recorded. The whole elevation ladder was 15%
    /// quieter than every number written against it, and the two appearances were
    /// quieter by *different* amounts, which is why `logoTile`'s two halves used
    /// to disagree by a step they were meant to share.
    ///
    /// Pure ink at the stated alpha, therefore, rather than a system colour with a
    /// second alpha hidden inside it. The signature is unchanged and no call site
    /// moves; the planes simply land where the arithmetic in this file says they
    /// do. The resting card step goes from ΔL\* 3.76 light / 4.70 dark to
    /// 4.18 / 5.14, which is the step the file was already claiming.
    public static func quiet(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink: CGFloat = dark ? 1 : 0
            return NSColor(srgbRed: ink, green: ink, blue: ink, alpha: CGFloat(opacity))
        })
    }

    /// The row background opacity for a background setting, a hover state and a
    /// press.
    ///
    /// One switch for all of it: the panel's rows and the Appearance pane's
    /// sample row each had their own copy, which is how a preview comes to
    /// disagree with the thing it is previewing.
    ///
    /// Pressed wins over both hover and style, and it is the same value under
    /// all three settings. A row being clicked is one event, so it looks like one
    /// thing — a `.plain` row that lights only on press still answers, and a
    /// `.always` card does not need a fourth step to say the same word. It
    /// defaults to `false` so a caller with no press to report reads exactly as
    /// it did.
    ///
    /// Keyboard selection resolves to that same `Fill.pressed`, one step below it
    /// in precedence, and there is deliberately no `Fill.selected` token. The two
    /// states are the same sentence — "this is the row you are about to act on" —
    /// arriving from the pointer in one case and from the arrow keys in the other,
    /// and a fourth plane between `cardHover` 0.09 and `pressed` 0.12 would be a
    /// 1.5% step nobody can see, asking the reader to tell apart two things that
    /// never appear at once anyway: the pointer's hover follows the pointer and
    /// the selection follows the keys, so a row is at most one of them. Selection
    /// is *not* an input to `RowGeometry` and must never become one — it changes a
    /// fill and nothing else, so it cannot change a row's height.
    public static func rowBackground(
        _ style: AppearanceSettings.RowBackground,
        isHovered: Bool,
        isPressed: Bool = false,
        isSelected: Bool = false
    ) -> Double {
        if isPressed { return Fill.pressed }
        if isSelected { return Fill.pressed }
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
    /// Derived, not chosen, and derived from the one absolute token that is drawn
    /// on the material rather than from the card steps that are not.
    ///
    /// `Fill`'s planes are relative — they lay ink *on top of* whatever the ground
    /// resolves to, so `card > ground` is arithmetic and cannot invert whatever
    /// the desktop does. `Meter.track` is the exception: it is an explicit pair
    /// (see `Meter`), it is drawn inside the panel, and the panel's ground moves
    /// with the wallpaper. At the shipped 0.88 a white desktop lifted the dark
    /// ground to `#2D2E30`, L\* 18.91, against the track's L\* 17.58 — solving
    /// `16 + (W − 16)·0.12 = 42` puts the crossing at a wallpaper of sRGB ≈ 233,
    /// past which the empty half of every bar and dial stopped being a container
    /// and became a hole.
    ///
    /// So both halves are solved against the worst wallpaper, with
    /// `.regularMaterial` modelled as fully transparent — the strict upper bound
    /// on what the desktop can contribute, since a real material adds its own
    /// tint and pulls the ground back towards `base`:
    ///
    /// - dark **0.94**: `12 + 243·0.06 = 26.6 → #1B1C1F`, L\* 10.28, against the
    ///   track's 19.42 → **1.2735:1 with the track still above the ground**. At
    ///   0.92 it is 1.216, at the shipped 0.88 it is 1.071, and at 0.86 it
    ///   inverts.
    /// - light **0.96**: `246·0.96 → #ECEDF0`, L\* 93.75, against the track's
    ///   85.25 → **1.2545:1 with the track still below**. At 0.92 it is 1.144.
    ///
    /// Light stays the larger of the two, and for the reason it always did: its
    /// base sits nearer a bright desktop, so it has less of a swing to absorb per
    /// point of scrim and can afford — and needs — the heavier one.
    ///
    /// The cost is stated rather than hidden: at 0.94/0.96 the panel is markedly
    /// less translucent than it was. That is the trade the track defect forces,
    /// and the alternative was rejected on measurement — a relative track
    /// (`quiet(0.12)`) rises with the ground, so under a white desktop on a
    /// pressed row it lifts to `#434447` and `attention` against it falls to
    /// 2.43:1, under the 3:1 a bar needs against its own container. The
    /// fill-against-track ratio is the reading; track-against-ground is chrome.
    ///
    /// Fully opaque under reduce-transparency, where the caller also drops the
    /// material entirely: a scrim over nothing is just a fill.
    public static func scrimAlpha(isDark: Bool, reduceTransparency: Bool) -> Double {
        if reduceTransparency { return 1 }
        return isDark ? 0.94 : 0.96
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

    // `notchColour(increased:)` and `notchWidth(increased:)` were here, for the
    // pace riser that cut through the meter fill. The whole drawing is deleted —
    // riser, cut and elapsed track shade — because a meter with a slit punched
    // through it is a private vocabulary the user has to be taught, and it was
    // also the reason a bar could not be drawn thinner than 5pt without becoming
    // incoherent. No information is lost: pace already says itself in words, in
    // `ForecastLine` ("on pace to cap in 40m"), which is where a quiet UI puts a
    // second reading.

    // MARK: - Dimming

    /// Opacity applied to a mark to say something about its subject rather than
    /// about the surface under it.
    ///
    /// There is one of these left, and that is the point. Opacity is the wrong
    /// instrument for state: it says "less of this" to the eye and "under the
    /// contrast floor" to the measurement, and it says both at once wherever it
    /// is used. State in this panel is carried by *ink* — a mark that is not
    /// reporting is drawn in `Ink.muted` at full opacity, which is a stronger
    /// statement than a fade and still measures 6.85:1 light and 7.85:1 dark on
    /// `Surface.base`, 4.80 and 4.81 on the worst plane in the panel.
    public enum Dim {
        /// A service switched off in Settings — the one place a fade is still the
        /// honest drawing, because the subject really is inactive and the lists
        /// it appears in are outside the panel.
        ///
        /// Seventy, up from 0.40. At 0.40 `Ink.muted` composites to 1.81:1 in
        /// light and 2.13:1 in dark: not quiet, illegible, in a settings list
        /// whose whole job is to tell you which services you have switched off.
        /// 0.70 measures **3.39:1 and 4.34:1** on `Surface.base` — read as off,
        /// still readable. On `Surface.raised`, which is the plane the settings
        /// list actually draws on, 3.50 and 4.03.
        ///
        /// It was recorded as 3.09 / 4.08 against the old grounds and the old
        /// `Ink.muted`; both moved with the palette, so this is re-measured rather
        /// than corrected. The value itself did not move.
        public static let disabled: Double = 0.70
        /// A reserved control that is not currently offered. Named because the
        /// value matters: the space stays, only this changes.
        public static let reserved: Double = 0

        // `disconnected` (0.55) was here, applied to a brand mark on any row
        // that was not reporting — loading, error, expired, locked, not
        // connected. Composited it gave Gemini 1.92:1 and MiniMax 2.11:1 in
        // light, under the 3:1 a meaningful non-text graphic needs, down an
        // entire fifteen-row first-run panel: the state a new user stares at was
        // the state drawn illegibly. "Not reporting" is now one ink for the whole
        // row — mark, name and caption in `Ink.muted` — which says the same thing
        // louder and passes.
    }

    // MARK: - Motion

    /// Every animation in the application. There are three curves and five
    /// places they are allowed, and the list is closed.
    ///
    /// Where they may appear, exhaustively: a meter fill's width (`fill`); a card
    /// fill under the pointer, a released press, and a row's revealed action
    /// buttons (`hover`); a press going down (`press`, which is instant). The
    /// headline's digits use `.contentTransition(.numericText())` on macOS 14 and
    /// carry their own timing. Nothing else moves — no row height, no mark
    /// opacity, no colour, no insertion, no scale, no shadow.
    ///
    /// Two rules hold the whole thing together. **Geometry animates, ink does
    /// not**: every tint is drawn under `.animation(nil, value: tint)`, because a
    /// threshold crossing is an event and a colour easing into red over a third
    /// of a second reads as a mood. And **frequent things are quick**: the panel
    /// is a glance, and the pointer crosses nine rows on the way to one of them,
    /// so a hover that takes as long as a meter fill turns the list into a wake
    /// of fading plates. 0.12 is under the system's own 0.25
    /// (`NSAnimationContext.duration`) on purpose; HIG says to generally avoid
    /// adding motion to interactions that occur frequently, and hover is the most
    /// frequent interaction there is.
    public enum Motion {
        /// A meter fill's width, animated on the reading rather than on the
        /// view's appearance — the one place in the panel where something the
        /// user cannot see happening is worth showing move.
        public static let fillDuration: Double = 0.30
        public static let fill: Animation = .easeOut(duration: fillDuration)

        /// Anything that answers the pointer: a hover fill arriving or leaving, a
        /// press releasing, a revealed control's opacity. One duration for all of
        /// them, because they are all the same event from the user's side and
        /// three timings on one row is a row that shears.
        public static let hoverDuration: Double = 0.12
        public static let hover: Animation = .easeOut(duration: hoverDuration)

        /// A press: down in zero, back on the hover curve.
        ///
        /// Asymmetric deliberately. The point of a pressed fill is that it lands
        /// with the click — eased in, it arrives after the user has already
        /// decided, which is worse than nothing because it reads as lag in the
        /// app rather than as feedback from it. Coming back it is a fade, since
        /// nothing is waiting on it. `nil` is the "no animation" answer, applied
        /// as `.animation(Motion.press(isPressed), value: isPressed)`.
        public static func press(_ isPressed: Bool) -> Animation? {
            isPressed ? nil : hover
        }
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
    /// One implementation, because there were two: `BrandMark.luminance` decided
    /// whether a near-black logo needed lifting off a dark menu, and `onAccent`
    /// decides whether text on the user's accent is black or white. Those are the
    /// same question and were being answered by two copies of the same transfer
    /// function. The first of them is gone entirely now — a mark's ink is
    /// `Ink.mark` and never a function of its own brand hex, so there is nothing
    /// left to lift — which leaves this the only copy and `onAccent` its only
    /// caller in the palette.
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
    /// Cool and near-black, by a +3/+5 offset of blue over red — the inverse of
    /// the warm graphite that was here. Warmth is the single biggest reason a
    /// dark panel reads as dated: brown-ish tiles and mustard bars sitting on a
    /// beige-black ground look like a theme rather than a tool. Every dark
    /// surface a user would call modern is neutral-to-cool and lands nearer
    /// black than this one did, so the dark ground drops from `0x1B1A18` to
    /// `0x0C0D11` and the light one loses its cream for a blue-white.
    ///
    /// This lands cheaply, and the reason is worth writing down: every value in
    /// `Fill` is an ink opacity and is therefore *relative* — it keeps its
    /// meaning over any ground. Changing the palette is swapping the base
    /// underneath, not rewriting call sites. `quiet(_:)` and `rowBackground` are
    /// untouched, and every appearance setting that reaches through them keeps
    /// working. It is also what keeps light mode designed rather than inverted:
    /// the same opacity resolves to a *darker* fill on a near-white ground and a
    /// lighter one on a near-black one.
    ///
    /// Elevation has exactly three planes — ground, card, raised — and there is
    /// no fourth. The steps between them are measured and are not free to be
    /// tidied: well→base is **1.1041** in light and **1.0556** in dark,
    /// base→raised **1.0712** and **1.1632**. Each has to read as a plane change
    /// and none of them as a second material, which is a narrow band: flattened
    /// they become one grey, opened up they start looking like translucency the
    /// panel does not have.
    ///
    /// None of the three ever meets the material, which is what makes that ladder
    /// unconditional rather than wallpaper-dependent. Grepped rather than assumed:
    /// `well` and `raised` appear only in `SettingsView`, `AppearancePane`,
    /// `BudgetPane`, `ConnectDialog` and `HistoryChart`, every one of them an
    /// opaque window. `base` is the only token here drawn on the material, and
    /// what holds it apart from the desktop is `scrimAlpha`, not this pair.
    public enum Surface {
        /// The panel ground, the panel header, and the settings form's.
        ///
        /// Dark moved `0x101114` → `0x0C0D11` to buy the well somewhere to go. At
        /// `0x101114` the whole headroom beneath the ground is 1.0813:1, so the
        /// deepest non-black well inside it lands within four thousandths of the
        /// 1.05 floor the ladder is asserted against; at `0x0C0D11` the well
        /// clears it at 1.0556 and is still a colour rather than pure black. Light
        /// moved `0xF7F8FA` → `0xF6F7FA` for the mirror-image reason — it lets the
        /// light well take a 1.1041 step, which is dark's raised step to three
        /// decimals, so the two appearances show the same number of visible planes
        /// instead of light showing one fewer.
        public static let base = dynamic(light: 0xF6F7FA, dark: 0x0C0D11)
        /// A well sunk into it: the history chart's plot area, the conditional
        /// footer band, a raw-JSON field. Darker than `base` in both appearances,
        /// so it reads as recessed rather than as a card. Dark's well is very
        /// nearly black, which is the point of a near-black ground: the only
        /// direction left to sink into is the last few points, and `0x030407`
        /// spends them — 1.0556 under the base, with blue still 4 over red so the
        /// last plane before black is cool rather than neutral.
        public static let well = dynamic(light: 0xEAECF0, dark: 0x030407)
        /// A surface with its own edge: the Appearance pane's sample panel, a
        /// banner, a callout, a connect dialog's step block. The one plane that
        /// stands *above* the ground, and the only one that takes a border — a
        /// raised surface is a border plus a ground and never a shadow, which the
        /// app does not have anywhere.
        ///
        /// Lighter in both appearances, and dark takes much the larger step
        /// (1.1632 against light's 1.0712) for the reason its well takes the
        /// smaller one: a near-black ground has less room below it than a
        /// near-white one has above it, so dark spends its budget upward and light
        /// spends it down. Light's raised plane is plain white, which is the one
        /// place in the light appearance white is allowed — a raised surface is
        /// exactly what the near-white ground is measured against.
        ///
        /// Dark's `0x1A1B1F` → `0x1B1E24` is that budget being spent: b − r goes
        /// 5 → 9, so the plane that stands above the ground is also the coolest of
        /// the three, which is the direction a raised surface reads as lit from.
        public static let raised = dynamic(light: 0xFFFFFF, dark: 0x1B1E24)

        // `onFill` was here — the ground punched back through a saturated meter
        // fill to keep the pace riser legible where the fill had overtaken it.
        // It died with the cut it existed for. Nothing is drawn over a fill now.
    }

    /// The parts of a meter that are not the fill. Which, now, is the track, and
    /// nothing else at all.
    ///
    /// Explicit pairs rather than ink opacities, which is the exception to how
    /// every other fill in this file works and is measured rather than preferred:
    /// the track is the ground every meter fill is read against, and a single
    /// opacity cannot hold the same ratio against a near-white panel and a
    /// near-black one. These are set from the fill down: the resting stop clears
    /// the track by **3.05:1 light and 3.19:1 dark**, amber by **4.78 and 7.19**,
    /// red by **6.85 and 5.26** — all past the 3:1 a non-text graphic needs, on
    /// both sides, at the *quietest* stop, which is resting and is cut as close to
    /// the floor as the track allows on purpose (see `fill`).
    ///
    /// Every one of those six figures has moved at least once, and each time
    /// because a stop moved rather than because this pair did. The resting stop
    /// left `Ink.muted` for `Meter.fill` when the ramp's first step turned out to
    /// be invisible in greyscale; the amber and the red were then re-cut so the
    /// ramp ranks in chroma, which swapped which of them sits nearest the track
    /// in dark (amber 5.09 → 7.19, red 7.13 → 5.26). The pair recorded here two
    /// re-cuts ago — "4.20 and 6.98" for amber — was measured against an amber the
    /// app had already stopped drawing, which is the drift a ramp written down in
    /// two files produces and the reason it is only written down in one now.
    public enum Meter {
        /// An empty track — bar and ring both. The meter slot has exactly two
        /// drawings: this with a fill on it, or nothing.
        ///
        /// The one absolute token drawn inside the panel, and therefore the one
        /// that can invert against a wallpaper. It moved with the grounds
        /// (`0xD8D9DD / 0x2A2B2F` → `0xD3D5DA / 0x2D2F35`) so that it stays 1.3709
        /// light and 1.4516 dark from `Surface.base` at rest, and `scrimAlpha` is
        /// solved to keep it on the correct side of the ground under any desktop —
        /// see the derivation there. A relative track was considered and rejected
        /// on measurement, also written up there.
        public static let track = dynamic(light: 0xD3D5DA, dark: 0x2D2F35)

        /// The usage ramp's resting stop — every bar, ring and strip segment
        /// below `cautionThreshold`.
        ///
        /// It was `Ink.muted`, folded there to "delete a duplicate", and the
        /// duplicate it deleted was the only greyscale step the ramp's *first*
        /// boundary had. Measured on the render of the day: resting `Ink.muted`
        /// L\* 67.61 against the amber of the day at 65.73 was **1.062:1, ΔL\*
        /// 1.87** in dark and **1.020:1, ΔL\* 0.54** in light — both stops have
        /// moved since, so those are the figures that made the case rather than
        /// the ones that hold now. Convert the panel to greyscale — which
        /// the near-cap contract three files over insists every channel must
        /// survive — and a resting bar and a caution bar are the same grey. A ramp
        /// whose first step is invisible without hue is a ramp carried by hue
        /// alone, in an application that spends hue on nothing else.
        ///
        /// So it is a stop of its own again, and this time it is solved rather
        /// than picked. Two bounds, both measured against the ground the fill is
        /// actually read on, which is the track and not the panel:
        ///
        /// - **≥ 3:1 on `Meter.track`**, the floor a non-text graphic needs to be
        ///   a shape at all. Dark `0x787C83` measures **3.192:1**, light
        ///   `0x74777E` **3.054:1**. Light's five hundredths is the thinnest
        ///   margin in this enum and is stated rather than rounded away: this is
        ///   the first pair to re-measure if `Meter.track` moves.
        /// - **≥ 9 L\* from `Ink.attention`**, the same greyscale gap
        ///   `testAmberAndRedSeparateInGreyscale` demands of the ramp's other
        ///   boundary, so that resting and caution are two greys once the hue comes
        ///   off. Measured **ΔL\* 25.03** dark and **12.24** light.
        ///
        ///   It used to say "≥ 9 L\* *under*", and the direction died when the
        ///   ramp was re-cut to rank in chroma: dark amber went up to L\* 76.92 to
        ///   let the red take the contrast bound, so resting is now the *darker*
        ///   of that pair in dark and the lighter of it in light. The gap is what
        ///   was ever load-bearing and the gap is wider than it was in both
        ///   appearances. The ladder now reads dark 51.89 → 76.92 → 66.76 and
        ///   light 49.99 → 37.76 → 27.93 — no longer monotone in lightness, and
        ///   monotone in chroma instead, which is stated on `Ink.alarm`.
        ///
        /// It is quieter than the ink it replaces, deliberately and by a lot:
        /// **4.633:1 dark / 4.186:1 light on `Surface.base`** against `muted`'s
        /// 7.850 / 6.853. Eight resting rows of nine each carried a 200–300pt slab
        /// at body-text contrast in a panel whose whole premise is quiet, and this
        /// is the change that stops them. Nothing here carries text, so 4.5:1 is
        /// not the floor it has to clear — 3:1 on the track is, and `Ink.muted`
        /// keeps the text ink unchanged.
        ///
        /// `ColorRamp.mono` still resolves to `Ink.muted` at every level, which is
        /// what that setting means: one ink, always. So `usage` and `mono` differ
        /// below caution again — a claim the palette's own doc had to retire when
        /// the two were folded together, and the band where that setting was ever
        /// saying anything.
        public static let fill = dynamic(light: 0x74777E, dark: 0x787C83)

        // `hairline` was here, at the same values as `track`, for "the slot on a
        // row with no meter at all". It was meant to distinguish "reports no
        // quota" from "is at 0%", and it could not, because it appeared in four
        // unrelated situations and looked like a table rule in all of them: under
        // the shipped Minimal preset every row drew a full-width rule with
        // nothing beneath it and the last one dangling at the window's bottom
        // edge; under `.bar` a quotaless row drew that rule between its own title
        // and caption, indistinguishable from a row divider. The distinction it
        // was carrying moves to the figure rail, where the row already says what
        // it is: a figure means there is a quota, a dot means there is not. The
        // slot keeps its height, so no row moves.
        //
        // `trackElapsed`, `notch`, `cutClearance` and `cutMinBarHeight` were
        // here. All four belonged to one drawing — a track shaded up to the
        // elapsed boundary, a riser standing on it, and a slit cut through the
        // fill so the riser survived being overtaken — and that drawing is
        // deleted. It cost a reader a paragraph of explanation to decode a
        // second quantity that `ForecastLine` already states in a sentence, and
        // it is what pinned the minimum bar height at 5pt.
    }

    /// The ninety-day heatmap: its grid, and the one ramp in the app that is a
    /// ramp of *luminance* rather than of hue.
    ///
    /// Why neutral. The panel's colour rule is that chroma means measurement or
    /// state and that any hue anywhere means something wants looking at. A
    /// heatmap coloured green-through-red would put ninety saturated squares in a
    /// settings window, every one of them making a claim in the same vocabulary
    /// the panel reserves for "you are about to be cut off" — and the two loudest
    /// cells on such a grid would be the days a user has nothing to do about,
    /// because they are already over. So the ramp is one neutral getting darker
    /// in light and lighter in dark, and the alarm hues are held back for the
    /// cells that are at or over the user's own warning line. On a ninety-day
    /// grid that means the coloured cells are countable, which is the only state
    /// in which a colour is worth spending.
    ///
    /// The four steps are a straight interpolation of the sRGB components from
    /// `Meter.track` — which is what an *empty* cell already is, so the ramp
    /// starts on the ground it is read against — to `Ink.muted`, which is the
    /// ink everything that is context takes. Written out as hexes rather than
    /// computed at draw time so the palette can be read off this file, and both
    /// endpoints are existing tokens so no cell is ever a colour nothing else in
    /// the app uses.
    public enum Heat {
        /// A day with no readings. Not a day at zero: `HistoryQuery` keeps those
        /// apart everywhere else and a grid is the one drawing where conflating
        /// them would invent three months of idleness.
        public static let empty = Meter.track
        public static let step1 = dynamic(light: 0xB9BBC0, dark: 0x46484E)
        public static let step2 = dynamic(light: 0x9A9DA3, dark: 0x62656C)
        public static let step3 = dynamic(light: 0x7B7E86, dark: 0x7F838A)
        public static let step4 = Ink.muted

        /// Eleven points square. Below ten a cell stops being a target the
        /// pointer can land on without care, and above twelve fourteen weeks of
        /// them stop fitting a settings form beside its own labels.
        public static let cell: CGFloat = 11
        /// `Space.tight`, which is the only gap on the scale that reads as a
        /// seam between two squares rather than as a column of its own.
        public static let gap: CGFloat = Space.tight
        /// Derived from the cell rather than taken from `Radius`: `Radius.chip`
        /// on an 11pt square is very nearly a circle, and a grid of circles is a
        /// dot plot. This is the exception the migration note at the foot of this
        /// file names — a literal derived from a subject's own size.
        public static let radius: CGFloat = 2
        /// Weeks the grid always draws.
        ///
        /// Fourteen and never thirteen, though ninety days spans one or the
        /// other depending on which weekday today is. A grid that narrowed by
        /// 13pt every Sunday and widened again on Monday is the settings
        /// window's version of the panel resizing under the pointer.
        public static let columns = 14
        /// One column and the seam after it.
        public static var pitch: CGFloat { cell + gap }
        /// The whole grid: fourteen columns and seven rows, seams between and
        /// none on the outside.
        public static var width: CGFloat { CGFloat(columns) * pitch - gap }   // 180
        public static var height: CGFloat { 7 * pitch - gap }                 // 89
        /// The weekday labels down the left.
        ///
        /// Reserved off the spacing scale rather than measured, because the
        /// abbreviation is the reader's locale's and not this file's — the label
        /// is held to one line and allowed to scale to 0.8, exactly as the day
        /// table's own headings are, so a locale that writes four letters
        /// shrinks its label instead of moving the grid.
        public static let weekdayGutter: CGFloat = Space.huge                 // 24
    }

    // MARK: - Semantic colour

    /// Every ink in the app: the neutrals text and marks are set in, and the
    /// colours that mean a state.
    ///
    /// **Colour only for alarm. Everything else is a neutral.** That is the whole
    /// colour rule now, and it is shorter than the one it replaces because two of
    /// the three hue zones have been spent down to nothing.
    ///
    /// There are exactly **two hues in the application**, and both of them mean
    /// alarm:
    ///
    /// - **amber** — `attention`: near the cap, and "needs you".
    /// - **red** — `alarm`: at the cap, and over budget.
    ///
    /// No item may add a third. Green went with `ok` and indigo went with `arc`;
    /// their tombstones below say what each was carrying and what carries it now.
    /// The rule is not tidiness — it is that a hue is only a signal while it is
    /// scarce. A panel running three unrelated colour systems in 356pt (fifteen
    /// brand marks at full saturation, a usage ramp with its own amber and red,
    /// and a semantic green/amber/red beside them) read as stickers on a grey
    /// wall, and worse than untidy: the raw brand hexes out-chromaed every colour
    /// that meant something (DeepSeek 0.220 and Mistral 0.214 OKLCh chroma against
    /// the ramp's 0.146–0.192), so the colour hierarchy was inverted and an alert
    /// could not announce itself against the row's own logo.
    ///
    /// Because the two survivors are the *only* colours, they also have to be
    /// distinguishable from each other with the hue removed — a greyscale
    /// screenshot, a deuteranope, a menu bar template image. The pair before last
    /// were 1.8 L\* apart in light and 2.9 in dark, so "at the cap" and "near the
    /// cap" were the same mark to anyone not reading the hue. That is fixed and
    /// stays fixed: **9.83 L\* of separation in light, 10.16 in dark**, against a
    /// floor of 9.
    ///
    /// **And they have to rank.** Separation says they are two marks; it does not
    /// say which of them is worse, and the pair this replaces got that backwards
    /// in the channel a viewer actually uses. Measured on the shipped dark render,
    /// the 92% row's amber carried OKLCh chroma 0.1506 and the 97% row's red
    /// 0.1069 — **the caution stop was 1.41× the chroma of the alarm stop**, so a
    /// panel of nine rows pulled the eye to the second-worst one. The rule that
    /// fixes it is stated on `alarm` and holds in both appearances: **chroma never
    /// decreases going up the ramp, and red is always the darker of the two.**
    ///
    /// A brand mark is therefore drawn in `mark`, a neutral, in both appearances
    /// and in every window. Identity survives it, because identity was never the
    /// hue: Simple Icons ships one path with no `fill` for exactly this reason,
    /// the menu bar strip has always drawn monochrome by default, and normalising
    /// the brand hexes to any chroma ceiling low enough to cohere collapses
    /// Claude, Mistral and MiniMax onto one pink and DeepSeek and OpenRouter onto
    /// one periwinkle anyway (OKLab ΔE 0.002–0.015). Where a user opts brand
    /// colour back on, it arrives through the banded lookup in `BrandMarks.swift`
    /// and never as a raw brand hex: that band holds one luminance and a chroma
    /// ceiling *under* the live `attention`'s, which is what keeps an opt-in
    /// identity from becoming a third thing that means alarm. This file states
    /// that rule; `BrandMarks.swift` owns the band, and neither reaches into the
    /// other.
    ///
    /// Usage colour is not here and must not come here: every meter, dot and
    /// percentage goes through `AppearanceSettings.tint(for:providerAccent:)`,
    /// which the user configures. This is the small set of states that are not
    /// usage — a connection that needs the user, a budget past its line — spelled
    /// `.green`, `.orange` and `.red` at four call sites in three files, with no
    /// agreement between them, until they were named here.
    ///
    /// **Where the ratios below are measured.** Not on `Surface.base`, which is a
    /// ground the user may never see. On **the worst plane the ink can actually
    /// land on**: the *pressed* row card, over `Surface.base` at `scrimAlpha`,
    /// over the wallpaper that pushes hardest — pure white in dark, pure black in
    /// light — with `.regularMaterial` modelled as fully transparent. That model
    /// is deliberately pessimistic, because a real material contributes its own
    /// tint and pulls the ground back towards `base`.
    ///
    /// The pressed card and not the hovered one, and that correction is the whole
    /// reason this paragraph is here. `Fill.pressed` (0.12) is a step *above*
    /// `Fill.cardHover` (0.09), `rowBackground` returns it for the whole row card
    /// under all three background settings, and `RowButtonStyle` draws the row's
    /// entire contents on it — so "a hovered card, the worst ground any of them
    /// lands on" was false for as long as a button was held down, and it put two
    /// inks under 4.5:1 there. The resolved planes are `#D0D1D3` light and
    /// `#36373A` dark. Every ink clears 4.5:1 on both: `body` 10.66/10.72,
    /// `mark` 7.42/7.32, `muted` 4.80/4.81, `attention` 4.60/6.39, `alarm`
    /// 6.59/4.68.
    ///
    /// The binding constraint is **light `attention` at 4.60**, and it moved here
    /// from dark `attention` at 4.53 when the ramp was re-cut to rank. The two
    /// numbers are the same fact seen from either side: the plane bounds a light
    /// figure at L\* ≤ 38.32 and a dark one at L\* ≥ 65.51, and each appearance
    /// now spends that bound on whichever of its two hues has the least chroma to
    /// give — the light amber, which is brown at any lightness the bound allows,
    /// and the dark red, which is pink at any lightness above it. Both sit on
    /// their own bound with 0.10 and 0.18 to spare where the old pair had 0.03, so
    /// this is a thicker margin than the palette has ever held. It is still the
    /// first thing to re-measure if `Surface.base`, `Fill.pressed`, `scrimAlpha`
    /// or either hue is ever re-cut.
    ///
    /// `.tertiary` is banned from the panel. There is no third neutral: a value
    /// is `body` or it is `muted`, and something that wants to be quieter than
    /// muted wants to not be there. A fourth was costed and rejected — `#61666F`,
    /// for gridlines and empty containers, measures 3.39:1 on the plane above and
    /// cannot carry text anywhere in the app. That role belongs to `Fill.rule` and
    /// `Meter.track`, which are fills and step up under increased contrast.
    public enum Ink {
        /// Text that is the answer: a service name, the wordmark, a figure below
        /// caution.
        ///
        /// It is also the lit half of a two-state pair now that green has gone: a
        /// connected service's status dot is drawn in this and an unreporting
        /// one's in `muted`, 2.22:1 light and 2.23:1 dark apart, which is a wider
        /// gap than the hue it replaces ever gave a colour-blind reader.
        ///
        /// Not `Color.primary`, and this is the quietest change in the file with
        /// the loudest effect. Primary on a near-black ground is pure white at
        /// 19:1 — harsh to read, and the single clearest tell that a dark UI is
        /// a default template rather than something anyone chose. No modern dark
        /// tool sets body text at `#FFF`. 15.20:1 light and 17.49:1 dark on
        /// `Surface.base`, 10.66 and 10.72 on the worst plane: still far past any
        /// requirement, without the glare.
        ///
        /// Light darkened `0x22242A` → `0x1E2026` to put the three neutrals on
        /// even L\* steps, which is the whole hierarchy now that weight is doing
        /// less: 12.28 → 24.51 → 36.56 in light, steps of 12.2 and 12.1. Dark
        /// already sat where it needed to.
        public static let body = dynamic(light: 0x1E2026, dark: 0xF2F3F5)

        /// A brand mark, and every brand mark. Identity is a shape in one ink.
        ///
        /// One ink for all fifteen, in both appearances, in the panel, in
        /// Settings and in the connect dialog — the finish of a rule the app was
        /// already applying to 73% of its surfaces (the default strip is
        /// monochrome; the dark panel already substituted a neutral for eleven of
        /// the fifteen marks) and applying nowhere consistently.
        ///
        /// The value is chosen to make a ladder rather than to be a third grey:
        /// `body` 15.20/17.49 → `mark` 10.58/11.94 → `muted` 6.85/7.85 on
        /// `Surface.base`, and 7.42/7.32 on the pressed card, which is the worst
        /// ground anything in the panel lands on. The name is the row's subject,
        /// the mark labels it, the caption is context — three steps of luminance
        /// that cost no space, no weight and no hue, and even ones: L\* 12.28 →
        /// 24.51 → 36.56 in light, 95.82 → 81.60 → 67.61 in dark. On a `.tile`
        /// plate it measures 9.08:1 light and 10.24:1 dark.
        ///
        /// `BrandMark.hex` stays, as data: the per-service menu bar colouring and
        /// the opt-in `.provider` ramp still read it, through a banded lookup that
        /// holds one luminance and a chroma ceiling. Nothing draws a raw brand hex.
        public static let mark = dynamic(light: 0x383A42, dark: 0xC7CBD3)

        /// Everything that is context rather than answer: a caption, a
        /// countdown, a section label, a unit tick, an icon glyph, a secondary
        /// chip's label.
        ///
        /// The whole of the panel's hierarchy is this against `body`. Two inks
        /// and one weight step do more separating than four type sizes did, and
        /// they cost no vertical space. 6.85:1 light, 7.85:1 dark on
        /// `Surface.base` — a caption is quiet, not unreadable, which is the
        /// difference between this and the `.secondary`/`.tertiary` pair it
        /// replaces.
        ///
        /// It is the floor, and that is a measurement rather than a preference:
        /// on the pressed card it is 4.80 light and 4.81 dark, so anything a step
        /// quieter than this fails 4.5:1 on a ground the app really draws. Dark
        /// lifted `0x9BA0A9` → `0xA0A5AE` for exactly that — the old value measures
        /// 4.39 there, which is under the floor a caption has to clear.
        ///
        /// It has a third job as of the palette rebuild: the usage ramp's resting
        /// stop is this ink, not a fourth grey written out in `UsageMeterGlyph`.
        /// The two hexes were already within 3 L\* of each other, so that deletes a
        /// duplicate rather than changing a look — but the consequence is worth
        /// stating, because it is visible: below caution, `ColorRamp.usage` and
        /// `ColorRamp.mono` now resolve identically. They still differ above
        /// caution, which is the only band where the setting was ever saying
        /// anything.
        ///
        /// It has a second job now, and it is the one `Dim` used to do badly:
        /// a row that is not reporting — loading, error, expired, locked, not
        /// connected — is drawn in this, mark and name and caption together, at
        /// full opacity. One ink for the whole row says "nothing here yet" more
        /// plainly than a fade, and it is the only version of that statement that
        /// measures. The error glyph takes it too, and carries its meaning by
        /// shape rather than by colour.
        public static let muted = dynamic(light: 0x53565E, dark: 0xA0A5AE)

        // `arc` was here, at `0x454BA7 / 0x8C9BFF` — indigo, "the app itself". Its
        // own doc called it "the only saturated thing in the chrome", and that is
        // precisely the sentence that no longer has a place to stand: indigo is
        // not grey, white, black, amber or red, and deleting it is the whole of
        // "colour only for alarm".
        //
        // Ten references, and the compiler finds every one: `AppMark`'s `tint`
        // default, the panel header's mark, the About pane's mark, one text link
        // in Settings, the `Sign in` word in a row's figure rail, and five `.tint`
        // modifiers in the browser-login sheet (three `.bordered` buttons and two
        // `Link`s). Being compile-visible is the point — a token left in place is
        // a look left in place. The one change that is *not* loud is the default
        // argument: every `AppMark(size:)` caller re-inks without saying so, which
        // is why it is written down here.
        //
        // What carried its meaning: the mark's own silhouette, which is what a
        // mark is for. The `tint` default becomes `body`, the three links take
        // `body` plus `.underline()` (an underline is the affordance a greyscale
        // UI has always had and a hue was standing in for), and the `Sign in` rail
        // word takes `body` at `Ramp.titleWeight` — it is already the only word in
        // a column of figures, so shape carries it.
        //
        // `ok` was here, at `0x11703C / 0x2CA765` — green, "working". Three
        // drawings: the 6pt connection dot in a row's figure rail
        // (`ProviderRow`), the connection row in Settings, and `Tone.ok` in the
        // connect dialog. Green is not in the vocabulary either, and its dark
        // half's recorded "10.06:1" had been stale since the hex was re-cut — a
        // figure quoting a colour the app had stopped drawing, which is the
        // strongest argument there is for deleting a token rather than correcting
        // its prose.
        //
        // What carried its meaning: `body`, as the *lit* half of a lit/unlit pair
        // against the `muted` the same rail already draws for a service that is
        // not reporting. Measured, that pair separates by 2.22:1 in light and
        // 2.23:1 in dark, and `body` on the worst plane is 10.66/10.72 — so the
        // dot is louder as a neutral than it was as a hue, and the state is now
        // carried by a difference the eye can rank rather than by a colour the
        // reader had to be taught meant good news. The two text sites also keep a
        // second channel that was always doing the real work: the word
        // "Connected." says it in English.

        /// Near the cap, and "needs you". The first of the two hues.
        ///
        /// These are the ramp's caution stops, byte for byte, and that is
        /// enforced rather than intended — the ramp's light stop had drifted to
        /// `0xB45309`, which put a figure under the 4.5:1 floor under three
        /// shipped presets. One amber, one pair of hexes: "nearly out" and "needs
        /// you" are the same call to action and cannot be two colours.
        ///
        /// **6.55:1 light and 10.43:1 dark on `Surface.base`; 4.60 and 6.39 on the
        /// worst plane; 4.78 and 7.19 against `Meter.track`.** Light's 4.60 is the
        /// thinnest margin over the floor of any ink in this enum, so this is the
        /// first pair to re-measure if `Surface.base`, `Fill.pressed`, `scrimAlpha`
        /// or the amber itself moves again.
        ///
        /// **Both halves are re-cut so that the ramp ranks, and the dark half
        /// moved for a reason worth stating in full, because it reverses what this
        /// doc used to say.** The sRGB gamut does not offer the same chroma at
        /// every lightness, and it offers the two hues their maxima in opposite
        /// directions: amber peaks *high* (`#FFA600` at L\* 75.2 is OKLCh C 0.171)
        /// and red peaks *low* (`#FF0000` is L\* 53). The pressed plane bounds both
        /// dark stops at L\* ≥ 65.51 and the greyscale rule holds them ≥ 9 L\*
        /// apart, so there are exactly two arrangements, and only one of them
        /// ranks:
        ///
        /// - amber on the bound and red above it — the shipped pair — caps amber
        ///   at C 0.18 and red at **C 0.121**, because no sRGB red at L\* 74.5 is
        ///   more saturated than a salmon. That is the inversion, and it was
        ///   forced by the arrangement rather than by the hexes.
        /// - red on the bound and amber above it caps red at **C 0.172** and amber
        ///   at 0.171 — both stops *more* chromatic than the arrangement above
        ///   gives them, and in the order that ranks.
        ///
        /// So dark `0xE08D1C` → `0xF1B347`: L\* 65.73 → 76.92, C 0.1506 → 0.1408,
        /// hue 66.9° → 77.9°. The amber gives up 7% of its chroma and steps off
        /// the contrast bound entirely (4.53 → 6.39), which is the half of the fix
        /// that stops the caution stop shouting; `alarm` takes the bound and spends
        /// it.
        ///
        /// Light `0x764C00` → `0x894800`, and light is designed rather than
        /// derived from that. It keeps the arrangement it had — amber on the
        /// ceiling the plane allows (L\* ≤ 38.32, `Y = (0.6237 + 0.05)/4.5 − 0.05
        /// = 0.1027`), red below it — because the mirror image does not work here:
        /// red at the ceiling would reach C 0.20, but it would push amber down to
        /// L\* 29, where hue 60° is `#6C3500` and no longer reads as a warm alarm
        /// at all. What is fixed instead is the *hue*: 73.0° → 57.9°, which is the
        /// difference between an olive-brown and a burnt orange, and it buys 17%
        /// more chroma (0.0965 → 0.1131) at the same bound. L\* 36.02 → 37.76,
        /// taking the last two points the ceiling had left.
        public static let attention = dynamic(light: 0x894800, dark: 0xF1B347)

        /// Over budget, and at the cap. The second of the two hues, and the last
        /// colour in the application.
        ///
        /// It lives here rather than as a literal in `UsageMeterGlyph` for the
        /// reason the file already learned with amber: a stop written out in a
        /// second file is a stop that gets re-cut in one place and not the other,
        /// which is how `0xB45309` and `Ink.attention` came to be two ambers. The
        /// ramp's top stop *is* this token now, byte for byte, and there is
        /// nowhere else to change it.
        ///
        /// **The two rules that make it read as worse than amber, in that order.**
        ///
        /// **Chroma never decreases going up the ramp.** Resting C 0.0113 →
        /// amber 0.1131 → red 0.1595 in light, 0.0117 → 0.1408 → 0.1600 in dark:
        /// each step is a step up, and the last one is 1.41× and 1.14×. This is
        /// the rule that was broken, and it was broken in dark by a factor of 1.41
        /// the other way — `0xFFA5A7` is C 0.1069 against the old amber's 0.1506,
        /// so the worse reading was drawn in the softer, pinker, less saturated
        /// colour. `0xFD7B74` is **+50% chroma** on that (0.1069 → 0.1600) and 10
        /// L\* deeper, which is the difference between a salmon and a red.
        ///
        /// **Red is the darker of the two, in both appearances.** L\* 27.93
        /// against amber's 37.76 in light, 66.76 against 76.92 in dark — 9.83 and
        /// 10.16 apart, against a floor of 9, so which alarm it is still survives a
        /// greyscale screenshot and a deuteranope. It is a physical rule rather
        /// than a preference: red's chroma peaks at L\* 53 and amber's near 75, so
        /// the darker of the two is the one that can hold the most colour, in
        /// either appearance, on either ground.
        ///
        /// That replaces "red is always the stop *further from the ground*", which
        /// held for one pass and cost the ramp its ranking. Further-from-the-ground
        /// means darker in light and *lighter* in dark, so it asked the dark red to
        /// sit above L\* 74.5 — the one place in the gamut where red has no chroma
        /// left — and the salmon was the result rather than the choice. The new
        /// rule is also the simpler one: the two appearances now agree about which
        /// stop is darker instead of mirroring each other.
        ///
        /// The cost is stated rather than hidden: in dark, red is now *nearer* the
        /// ground than amber, so a greyscale screenshot shows the 97% row's bar
        /// darker than the 92% row's. Nothing rests on that. Near-cap is carried by
        /// three channels that are not colour at all — the fill's square trailing
        /// cap, the figure at `Ramp.alertWeight`, and a fill visibly past the
        /// redline — and `UsageRampContrastTests` desaturates a rendered panel to
        /// prove it rather than quoting this paragraph.
        ///
        /// 9.40:1 light and 7.64:1 dark on `Surface.base`; 6.59 and 4.68 on the
        /// worst plane in the panel; 6.85 and 5.26 against `Meter.track`. Dark's
        /// 4.68 is this appearance's binding ink, for the reason on `attention`:
        /// each appearance spends its contrast bound on whichever hue has the least
        /// chroma to give.
        public static let alarm = dynamic(light: 0x890313, dark: 0xFD7B74)

        // `failure` was here, at `0xC62A2F / 0xFF6B6E` — a red for "the request
        // failed", beside a ramp whose warning stop was byte-identical to it. So
        // "this fetch did not come back" and "you are at your cap" were the same
        // colour, and a panel of dropped requests drew ten red triangles down a
        // list whose entire premise is that red means near-cap.
        //
        // Red has one owner and it is the ramp, because the ramp is the thing
        // that measures. A failed request is not a measurement: its glyph is
        // `muted` and its meaning is carried by shape and by one sentence of
        // English. The deletion is compile-visible so that nothing keeps the old
        // reading by keeping the old token.

        /// Neither: disabled, nothing reported yet, a count of things elsewhere.
        /// Explicitly `muted` rather than `Color.secondary`, so a disabled row
        /// and a caption are the same grey — the system's secondary is a
        /// different value from ours and put a third neutral on the panel.
        ///
        /// It survives the palette rebuild as an alias and not as a value. Folding
        /// its eleven call sites into `muted` would be eleven edits for no
        /// measurement, and the name is doing real work at those sites: "idle" and
        /// "context" are different sentences that happen to be the same grey, and
        /// a reader who finds `muted` on a disabled control cannot tell which one
        /// was meant.
        public static let idle: Color = muted

        /// The wash behind a warning banner, at the weight a banner wants.
        ///
        /// Not `dynamic`, because it is the one colour here that is deliberately
        /// translucent: it has to let the surface under it through.
        ///
        /// The light half is `attention` light exactly — `rgb(0.537, 0.282, 0.000)`
        /// is `0x894800` — and the dark half is `attention` dark exactly —
        /// `rgb(0.945, 0.702, 0.278)` is `0xF1B347` — at a heavier alpha. That is
        /// the whole arrangement, and it is written out by hand rather than derived
        /// because `dynamic` builds its `NSColor` at alpha 1 with no component
        /// accessor to reach back through, and the two halves want different
        /// alphas: 0.09 in light and 0.12 in dark, because a 9% tint of the ink's
        /// own value disappears into a near-black ground.
        ///
        /// It once claimed to be "retuned to `attention`'s new stops" and was not:
        /// the light half had been, but the dark half was still `rgb(1.00, 0.65,
        /// 0.14)` = `0xFFA624`, the *retired* `0xF5A623` amber, so a dark warning
        /// banner drew two ambers, the wash and the ink on it, neither of them the
        /// token they were both named after. Both halves track the shipped pair
        /// now, and both moved again with the ramp's re-cut — which is what that
        /// discipline is for: the drift is a two-line edit here rather than a
        /// silent disagreement.
        ///
        /// Resolved: over `Surface.base`, light `#ECE7E4` (1.145:1 above the
        /// ground, `body` 13.27 and `muted` 5.98 on it) and dark `#272117`
        /// (1.217:1, `body` 14.37, `muted` 6.45). Over `Surface.raised`, which is
        /// where `ConnectDialog` actually draws it, light `#F4EFE8` (`muted`
        /// 6.42) and dark `#353028` (`muted` 5.29).
        public static let attentionWash = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.945, green: 0.702, blue: 0.278, alpha: 0.12)
                : NSColor(srgbRed: 0.537, green: 0.282, blue: 0.000, alpha: 0.09)
        })

        /// Text and glyphs on an accent-filled chip.
        ///
        /// A function of the fill, not a constant, and this is the whole point:
        /// the accent is the user's and may be any colour they picked, including
        /// a pale yellow that white text disappears into. The fix for a pale
        /// accent is to darken the *text*; it is never to darken the colour the
        /// user chose, which is what a binary search on their hex would amount
        /// to. `0x101010` rather than pure black, for the same reason `Ink.body`
        /// is not pure white: the extremes are where a palette stops looking
        /// chosen. It is fixed rather than dynamic because the ground here is
        /// the user's fill, not the appearance.
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
///
/// Generic over an accessory view, so the strip-style chooser — six chips, each
/// with a rasterised sample of the strip it selects above its label — is this
/// control and not a fourth copy of it. That is the pane's own doctrine: the
/// rule is not "keep the copies in step", it is that there are no copies. The
/// accessory sits above the existing row and everything else is untouched, so a
/// style chip and a preset chip are one control with one fill, one hover rule,
/// one `Ink.onAccent` and one `.isSelected` trait between them.
///
/// The five call sites that want no accessory do not mention one: the extension
/// below gives `Accessory == EmptyView` an init with the original signature, so
/// generalising this cost the sidebar and the preset grid nothing.
public struct SelectableChip<Accessory: View>: View {
    public let title: String
    /// SF Symbol in front of the title, in a fixed column so a list of these
    /// lines its titles up. Nil centres the title instead, which is what a chip
    /// in a grid wants and a sidebar row does not.
    public let symbol: String?
    public let isSelected: Bool
    public let help: String?
    public let action: () -> Void
    /// Drawn above the title row when there is one. A closure rather than a
    /// stored view so a chip that never shows one costs nothing to build — the
    /// preset grid makes five of these on every Appearance render.
    private let accessory: () -> Accessory

    @State private var isHovered = false

    public init(
        title: String,
        symbol: String? = nil,
        isSelected: Bool,
        help: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
        self.help = help
        self.accessory = accessory
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: Tokens.Space.small) {
                accessory()
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
                            weight: isSelected ? Tokens.Ramp.titleWeight : .regular
                        ))
                        .lineLimit(1)
                        // The title takes the rest of the width and places itself
                        // in it, so a centred chip and a leading row are one view
                        // with one alignment argument rather than two layouts.
                        .frame(
                            maxWidth: .infinity,
                            alignment: symbol == nil ? .center : .leading
                        )
                }
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

public extension SelectableChip where Accessory == EmptyView {
    /// The signature every chip in the app had before the style chooser needed a
    /// sample above its label, kept so that generalising the type moved no call
    /// site. A stack lays out no box and inserts no spacing for an `EmptyView`, so
    /// a chip built this way measures exactly what it measured before.
    init(
        title: String,
        symbol: String? = nil,
        isSelected: Bool,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            symbol: symbol,
            isSelected: isSelected,
            help: help,
            accessory: { EmptyView() },
            action: action
        )
    }
}

/// One line of prose under a form section.
///
/// Here rather than in a pane because the settings window has one voice for this
/// and three chances to lose it: the Appearance pane had eight sections each
/// saying `.font`, `.foregroundStyle` and `.fixedSize` in their own words, and
/// `SettingsView` had a private `PaneFooter` that was these same three lines.
/// This is the copy to keep.
public struct SectionFooter: View {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: Tokens.Ramp.caption))
            .foregroundStyle(Tokens.Ink.muted)
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
// radius or ink opacity written into a view is a value nothing else in the app
// can agree with, so it is named here first (and it is an *ink* opacity now, not
// a `Color.primary` one — see `quiet(_:)`). The exceptions are the
// literals derived from a subject's own size rather than from the window's
// rhythm — a logo's tile radius, a glyph's bar width.
// ---------------------------------------------------------------------------
