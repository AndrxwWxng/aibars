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
        /// Prose footers, slider readouts, axis labels, and group headers.
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

    // `sectionTracking` was here, and the uppercased group header it was for is
    // gone with it. Tracking is now zero everywhere in the app: SF ships optical
    // tracking per size and correcting it is how house type starts disagreeing
    // with every native label beside it. The negative tracking the reference
    // dark tools use is an Inter correction and does not transfer to SF.
    //
    // A group header is a word — sentence case, `Ramp.detail`, `Ink.muted` — not
    // a rule with a word on it.

    /// Width of `digits` monospaced characters at `size`.
    ///
    /// Tabular figures fix the width of a digit, not the length of a string:
    /// `9%` still reflows to `92%` and drags the label beside it. Every figure
    /// column is therefore reserved, and this is the width to reserve it at.
    ///
    /// 0.6185 is SF Mono's measured advance ratio on this platform — "888"
    /// measures 24.11pt at 13pt, a ratio of 0.61816 — so this is the real column
    /// rather than an em-based guess with slack in it. It replaces the
    /// `(detailSize * 2.8)` that `ProviderRow` was estimating with.
    ///
    /// And the reason `Ramp.figureDesign` is not a taste: the widest reading a
    /// row can carry, `"100%"`, measures 32.14pt in SF Mono at 13pt and fits the
    /// 35pt rail this function reserves for it. The same string in SF Pro wants
    /// 36.29pt and **overflows** — so anyone who ever "simplifies" the mono
    /// design away breaks the rail rather than just changing the face.
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
        /// The one green dot the panel draws: proof of connection on a service
        /// that reports a state rather than a quota, in the figure rail. It used
        /// to sit in front of the status line, which put a glyph ahead of text on
        /// a detail line and indented that one line past every other.
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
        /// A hairline rule drawn as a `Rectangle` rather than a `Divider`, in
        /// points, at the system's own weight: `NSBox(.separator)` reports an
        /// intrinsic height of 1 and `NSSplitView.dividerThickness` is 1.0.
        ///
        /// A point, not a pixel — and on a Retina display those are not the same
        /// rule. One point of grey at 2× lights two device pixels, which is
        /// twice the ink the system's own separator lays down and reads as a soft
        /// grey band rather than as a line. The one rule left in the app (under
        /// the panel header) therefore opts into `hair(scale:)` below and snaps
        /// its offset; this value stays for anything that genuinely wants a
        /// point, and as the number to compare against.
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
        /// was never the pill's: 0.07 over `Surface.base` is a 1.165 step in
        /// light and 1.186 in dark, which is the quietest plane that still reads
        /// as a plane.
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

    /// `Color.primary` at one of `Fill`'s opacities — the longhand every one of
    /// those literals is currently written in.
    public static func quiet(_ opacity: Double) -> Color {
        Color.primary.opacity(opacity)
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
    public static func rowBackground(
        _ style: AppearanceSettings.RowBackground,
        isHovered: Bool,
        isPressed: Bool = false
    ) -> Double {
        if isPressed { return Fill.pressed }
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
    /// Unchanged when the grounds went near-black, and re-derived rather than
    /// assumed: the new base is *darker* than the graphite it replaced, so the
    /// wallpaper swing this has to absorb is the same or smaller and the ladder
    /// still cannot invert.
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
    /// statement than a fade and still measures 5.93:1 light and 7.19:1 dark.
    public enum Dim {
        /// A service switched off in Settings — the one place a fade is still the
        /// honest drawing, because the subject really is inactive and the lists
        /// it appears in are outside the panel.
        ///
        /// Seventy, up from 0.40. At 0.40 `Ink.muted` composites to 1.81:1 in
        /// light and 2.13:1 in dark: not quiet, illegible, in a settings list
        /// whose whole job is to tell you which services you have switched off.
        /// 0.70 measures 3.09:1 and 4.08:1 — read as off, still readable.
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
    /// `0x101114` and the light one loses its cream for a blue-white.
    ///
    /// This lands cheaply, and the reason is worth writing down: every value in
    /// `Fill` is a `Color.primary` opacity and is therefore *relative* — it
    /// keeps its meaning over any ground. Changing the palette is swapping the
    /// base underneath, not rewriting call sites. `quiet(_:)` and
    /// `rowBackground(_:isHovered:)` are untouched, and every appearance setting
    /// that reaches through them keeps working. It is also what keeps light mode
    /// designed rather than inverted: the same opacity resolves to a *darker*
    /// fill on a near-white ground and a lighter one on a near-black one.
    ///
    /// Elevation has exactly three planes — ground, card, raised — and there is
    /// no fourth. The steps between them are measured and are not free to be
    /// tidied: well→base is 1.092 in light and 1.056 in dark, base→raised 1.063
    /// and 1.086. Each has to read as a plane change and none of them as a
    /// second material, which is a narrow band: flattened they become one grey,
    /// opened up they start looking like translucency the panel does not have.
    public enum Surface {
        /// The panel ground, the panel header, and the settings form's.
        public static let base = dynamic(light: 0xF7F8FA, dark: 0x101114)
        /// A well sunk into it: the history chart's plot area, the conditional
        /// footer band, a raw-JSON field. Darker than `base` in both appearances,
        /// so it reads as recessed rather than as a card. Dark's well is very
        /// nearly black, which is the point of a near-black ground: the only
        /// direction left to sink into is the last few points.
        public static let well = dynamic(light: 0xEDEEF1, dark: 0x08090A)
        /// A surface with its own edge: the Appearance pane's sample panel, a
        /// banner, a callout, a connect dialog's step block. The one plane that
        /// stands *above* the ground, and the only one that takes a border — a
        /// raised surface is a border plus a ground and never a shadow, which the
        /// app does not have anywhere.
        ///
        /// Lighter in both appearances, and dark takes the larger step (1.086
        /// against light's 1.063) for the reason its well takes the smaller one:
        /// a near-black ground has less room below it than a near-white one has
        /// above it, so dark spends its budget upward and light spends it down.
        /// Light's raised plane is plain white, which is the one place in the
        /// light appearance white is allowed — a raised surface is exactly what
        /// the near-white ground is measured against.
        public static let raised = dynamic(light: 0xFFFFFF, dark: 0x1A1B1F)

        // `onFill` was here — the ground punched back through a saturated meter
        // fill to keep the pace riser legible where the fill had overtaken it.
        // It died with the cut it existed for. Nothing is drawn over a fill now.
    }

    /// The parts of a meter that are not the fill. Which, now, is the track, and
    /// nothing else at all.
    ///
    /// Explicit pairs rather than `Color.primary` opacities, which is the
    /// exception to how every other fill in this file works and is measured
    /// rather than preferred: the track is the ground every meter fill is read
    /// against, and a single opacity cannot hold the same ratio against a
    /// near-white panel and a near-black one. These are set from the fill down:
    /// the resting grey stop clears the track by 4.27:1 light and 4.35:1 dark,
    /// amber by 4.20 and 6.98, red by 4.50 and 5.10 — all past the 3:1 a
    /// non-text graphic needs, on both sides, at the *quietest* stop.
    public enum Meter {
        /// An empty track — bar and ring both. The meter slot has exactly two
        /// drawings: this with a fill on it, or nothing.
        public static let track = dynamic(light: 0xD8D9DD, dark: 0x2A2B2F)

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

    // MARK: - Semantic colour

    /// Every ink in the app: the neutrals text and marks are set in, and the
    /// colours that mean a state.
    ///
    /// **Chroma means measurement or state. Identity is drawn in ink. The app's
    /// own colour appears once per window.** That is the whole colour rule, and
    /// it closes a panel that was running three unrelated colour systems in
    /// 356pt: fifteen brand marks at full brand saturation, a usage ramp with its
    /// own amber and red, and a semantic green/amber/red beside them. Down a
    /// nine-row list that reads as stickers on a grey wall, and worse than
    /// untidy — the raw brand hexes out-chromaed every colour that meant
    /// something (DeepSeek 0.220 and Mistral 0.214 OKLCh chroma against the
    /// ramp's 0.146–0.192), so the panel's colour hierarchy was inverted and an
    /// alert could not announce itself against the row's own logo.
    ///
    /// There are exactly three hue zones left, and nothing else in the panel may
    /// carry hue at all:
    ///
    /// - **warm, 22–73°** — measurement and "needs you": the usage ramp at or
    ///   above caution, and `attention`.
    /// - **green, 140–165°** — connected and working: `ok`, one 6pt dot, in the
    ///   figure rail of a row that reports no quota. Nowhere else.
    /// - **indigo, 265–285°** — the app itself: `arc`, and only where its own
    ///   comment says.
    ///
    /// A brand mark is therefore drawn in `mark`, a neutral, in both appearances
    /// and in every window. Identity survives it, because identity was never the
    /// hue: Simple Icons ships one path with no `fill` for exactly this reason,
    /// the menu bar strip has always drawn monochrome by default, and normalising
    /// the brand hexes to any chroma ceiling low enough to cohere collapses
    /// Claude, Mistral and MiniMax onto one pink and DeepSeek and OpenRouter onto
    /// one periwinkle anyway (OKLab ΔE 0.002–0.015). Brand hue bought nothing
    /// here and cost the alert its voice.
    ///
    /// Usage colour is not here and must not come here: every meter, dot and
    /// percentage goes through `AppearanceSettings.tint(for:providerAccent:)`,
    /// which the user configures. This is the small set of states that are not
    /// usage — a connection working, a connection that needs the user, a request
    /// that failed — spelled `.green`, `.orange` and `.red` at four call sites in
    /// three files, with no agreement between them, until they were named here.
    ///
    /// All of them are explicit pairs rather than system colours, for the same
    /// reason the ramp is: each of these is sometimes text, and `.green` on a
    /// light panel does not clear 4.5:1. Every ratio quoted below is measured on
    /// `Surface.base`; each one also clears 4.5:1 on a hovered card, which is
    /// the worst ground any of them lands on.
    ///
    /// `.tertiary` is banned from the panel. There is no third neutral: a value
    /// is `body` or it is `muted`, and something that wants to be quieter than
    /// muted wants to not be there.
    public enum Ink {
        /// Text that is the answer: a service name, the wordmark, a figure below
        /// caution.
        ///
        /// Not `Color.primary`, and this is the quietest change in the file with
        /// the loudest effect. Primary on a near-black ground is pure white at
        /// 19:1 — harsh to read, and the single clearest tell that a dark UI is
        /// a default template rather than something anyone chose. No modern dark
        /// tool sets body text at `#FFF`. 14.6:1 light, 17.0:1 dark: still far
        /// past any requirement, without the glare.
        public static let body = dynamic(light: 0x22242A, dark: 0xF2F3F5)

        /// A brand mark, and every brand mark. Identity is a shape in one ink.
        ///
        /// One ink for all fifteen, in both appearances, in the panel, in
        /// Settings and in the connect dialog — the finish of a rule the app was
        /// already applying to 73% of its surfaces (the default strip is
        /// monochrome; the dark panel already substituted a neutral for eleven of
        /// the fifteen marks) and applying nowhere consistently.
        ///
        /// The value is chosen to make a ladder rather than to be a third grey:
        /// `body` 14.60/17.00 → `mark` 10.22/11.72 → `muted` 5.93/7.19 on
        /// `Surface.base`, and 8.38/9.37 on a hovered card, which is the worst
        /// ground anything in the panel lands on. The name is the row's subject,
        /// the mark labels it, the caption is context — three steps of luminance
        /// that cost no space, no weight and no hue. On a `.tile` plate it
        /// measures 8.77:1 light and 9.88:1 dark.
        ///
        /// `BrandMark.hex` stays, as data: the per-service menu bar colouring and
        /// the opt-in `.provider` ramp still read it, through a banded lookup that
        /// holds one luminance and a chroma ceiling. Nothing draws a raw brand hex.
        public static let mark = dynamic(light: 0x3A3D45, dark: 0xC8CCD3)

        /// Everything that is context rather than answer: a caption, a
        /// countdown, a section label, a unit tick, an icon glyph, a secondary
        /// chip's label.
        ///
        /// The whole of the panel's hierarchy is this against `body`. Two inks
        /// and one weight step do more separating than four type sizes did, and
        /// they cost no vertical space. 5.93:1 light, 7.19:1 dark — a caption is
        /// quiet, not unreadable, which is the difference between this and the
        /// `.secondary`/`.tertiary` pair it replaces.
        ///
        /// It has a second job now, and it is the one `Dim` used to do badly:
        /// a row that is not reporting — loading, error, expired, locked, not
        /// connected — is drawn in this, mark and name and caption together, at
        /// full opacity. One ink for the whole row says "nothing here yet" more
        /// plainly than a fade, and it is the only version of that statement that
        /// measures. The error glyph takes it too, and carries its meaning by
        /// shape rather than by colour.
        public static let muted = dynamic(light: 0x5C6069, dark: 0x9BA0A9)

        /// The app's own colour, and the only saturated thing in the chrome.
        ///
        /// Where it may appear, exhaustively: the app mark in the panel header,
        /// the app mark in the About pane, a text link ("open usage page",
        /// "unlock a browser in Settings"), and the word `Sign in` in a row's
        /// figure rail — plain text there, and `.bordered` in the connect dialog,
        /// never `.borderedProminent`. Nowhere else. Never a surface, never a
        /// meter, never a row background, never a border, never a hover state,
        /// never in the menu bar.
        ///
        /// That rail word is now the app's single answer to "this one needs your
        /// credential", whether the session is missing, expired or locked. It
        /// replaces an amber padlock, and the trade is worth naming: a first run
        /// drew nine saturated locks in a panel whose premise is that colour
        /// means measurement, and none of them said what to click.
        ///
        /// Indigo rather than the teal it was, because teal is a hue away from
        /// nothing: it sat between the ramp's old resting stop and `ok`, so the
        /// one colour that is supposed to mean "this is the app" was competing
        /// with two colours that mean states. Indigo is unmistakably off the
        /// ramp, which is the entire job.
        ///
        /// It is deliberately *not* `AppearanceSettings.accentColor`. That one
        /// is the user's, it defaults to the system accent, and it keeps every
        /// job it has: selected chips, focus rings, `ColorRamp.accent`. The app
        /// having its own colour and the user having theirs are two different
        /// facts and they were being answered by one value — and two accents
        /// lit at once is exactly what a quiet panel cannot afford, which is why
        /// the list above is closed.
        /// The two halves of the pair hold one chroma as well as one hue, and the
        /// light half was re-cut to get there. It was `0x4340C9` — OKLCh C 0.205,
        /// which made the app's own colour the highest-chroma ink in the panel,
        /// above the warning red's 0.186 and nearly twice the caution amber's
        /// 0.108. On a first run that is the whole of the panel's colour: fifteen
        /// `Sign in` rails, 1.07% of every pixel, all of it accent and none of it
        /// measurement — the alert cannot announce itself against a hue that
        /// out-shouts it before there is anything to announce. `0x454BA7` is the
        /// same hue at the dark half's own chroma (0.146) and, deliberately, the
        /// same contrast to within a hundredth: L 0.460, 7.01:1 on `Surface.base`
        /// and 5.75:1 on a hovered card, against 7.02 and 5.75 before. Nothing
        /// about its legibility moved; only its loudness relative to the ramp did.
        /// 7.01:1 on `Surface.base` light, 7.41:1 dark.
        public static let arc = dynamic(light: 0x454BA7, dark: 0x8C9BFF)

        /// Working. Reserved for exactly that: a connected service that is not
        /// answering is not green.
        ///
        /// Green means one thing and one thing only, because the usage ramp gave
        /// it up. The ramp's resting stop is now grey, which takes that further:
        /// a healthy row carries no hue at all, so any colour arriving anywhere
        /// in the panel means something needs looking at.
        ///
        /// It appears in exactly one drawing: a 6pt dot in the figure rail of a
        /// row that reports no quota. That row has no number and no meter, so the
        /// dot is its only proof of connection — and putting it in the rail with
        /// the figures rather than in front of its own caption is what stops that
        /// caption starting 20pt to the right of every other caption in the list.
        /// 5.80:1 light, 10.06:1 dark.
        public static let ok = dynamic(light: 0x11703C, dark: 0x2CA765)

        /// Needs the user, in the two places that still say it in colour: the
        /// usage ramp's caution stop, and a budget figure past its line.
        ///
        /// These are the ramp's caution stops, byte for byte, and that is now
        /// enforced rather than intended — the ramp's light stop had drifted to
        /// `0xB45309`, which measures 3.87:1 on a hovered card and put a figure
        /// under the 4.5:1 floor under three shipped presets. One amber, one pair
        /// of hexes: "nearly out" and "needs you" are the same call to action and
        /// cannot be two colours. 5.58:1 light, 9.32:1 dark on `Surface.base`;
        /// 4.57 and 7.45 on a hovered card.
        public static let attention = dynamic(light: 0x8A5A00, dark: 0xD08214)

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
        public static let idle: Color = muted

        /// The wash behind a warning banner, at the weight a banner wants.
        /// Not `dynamic`, because it is the one colour here that is deliberately
        /// translucent: it has to let the surface under it through. Retuned to
        /// `attention`'s new stops, and a shade thinner in both appearances —
        /// on a near-black ground the same alpha reads as a lit panel rather
        /// than as a tint.
        public static let attentionWash = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 1.00, green: 0.65, blue: 0.14, alpha: 0.12)
                : NSColor(srgbRed: 0.54, green: 0.35, blue: 0.00, alpha: 0.09)
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
                        weight: isSelected ? Tokens.Ramp.titleWeight : .regular
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
// radius or `Color.primary.opacity` written into a view is a value nothing else
// in the app can agree with, so it is named here first. The exceptions are the
// literals derived from a subject's own size rather than from the window's
// rhythm — a logo's tile radius, a glyph's bar width.
// ---------------------------------------------------------------------------
