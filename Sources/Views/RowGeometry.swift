import SwiftUI

/// A provider row's measurements, as arithmetic with no view in it.
///
/// `ProviderRow` and the Appearance pane's `SampleRow` each worked these out
/// privately — the same leading-column sum, the same figure rail, the same chip
/// estimate, written twice — and that is exactly how the preview came to
/// disagree with the row it previews. Both read this now and neither computes
/// geometry again.
///
/// It is given no content at all: not a reading, not a plan name, not whether a
/// fetch has landed. That is what makes the height invariant structural rather
/// than a promise. A row cannot change height when a spinner resolves, when a
/// quota arrives, or when a figure goes from two digits to three, because none
/// of those are inputs. `MenuBarExtra` sizes its window to the height its rows
/// report, so a row that grew on a refresh would resize the panel under the
/// pointer.
///
/// Every measurement here is *reserved* rather than measured. Tabular figures
/// fix the width of a digit and not the length of a string, and a `GeometryReader`
/// would have to resolve before the row could report a height at all.
public struct RowGeometry: Equatable {

    /// Which optional lines this row draws. Presence only — never what they say.
    ///
    /// Three, because three is what changes a row's height. The plan pill, the
    /// account label and the action buttons all live on the title line, which is
    /// one box whatever is in it, and the error and loading lines are the window
    /// line's own box with different words in it.
    public struct Lines: OptionSet, Equatable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// The row occupies its meter slot: a track, the rule that stands in for
        /// one under `numberOnly`, or the hairline a service reporting no quota
        /// gets. All three are the same height, which is what the row is squared
        /// against.
        public static let meter = Lines(rawValue: 1 << 0)
        /// The line under the meter: "5h · resets 1h 20m", "Not connected",
        /// "Loading…", an error.
        public static let window = Lines(rawValue: 1 << 1)
        /// The pace caption: "on pace to cap in 40m". The one line the row draws
        /// only when there is something honest to say, which is why it is asked
        /// about rather than assumed.
        public static let forecast = Lines(rawValue: 1 << 2)
    }

    /// The logo-and-dial column, the gap to the text included. Zero when there
    /// is neither, and then the gap goes with it — an 11pt indent in front of
    /// nothing reads as a broken layout rather than as a text list.
    public let leadingWidth: CGFloat

    /// What is left of the panel for the row to say anything in. The only width
    /// budget a row gets to reason about.
    public let textColumnWidth: CGFloat

    /// The width the headline figure and its unit hold, on every row of the
    /// panel including the ones with no figure to put in it.
    public let headlineRail: CGFloat

    /// The same rail for a further window's line.
    public let secondaryRail: CGFloat

    /// The row's height, its own vertical padding included and the gap to the
    /// next row excluded.
    ///
    /// Reserved, and reserved generously in one place: the title line is held at
    /// the height of the action buttons, which `RowActions` reserves rather than
    /// inserts. A panel with those buttons switched off entirely draws a shorter
    /// row than this — that setting is the one case where the reservation is
    /// larger than the drawing, and erring in that direction is the one that
    /// cannot clip a figure.
    ///
    /// Text lines count at `Tokens.lineBox`, the floor the row holds its
    /// single-line details at, so a spinner and a countdown occupy the same box.
    public let height: CGFloat

    /// The radius the row's card is drawn at.
    ///
    /// `Tokens.Radius.row` is right for a 49pt comfortable row and wrong for a
    /// 27pt compact one-line row, whose corners it eats.
    public var cardRadius: CGFloat {
        min(Tokens.Radius.row, height / 3)
    }

    public init(
        metrics: AppearanceSettings.Metrics,
        showsPercentage: Bool,
        meterStyle: AppearanceSettings.MeterStyle,
        logoStyle: AppearanceSettings.LogoStyle,
        logoSize: CGFloat,
        panelWidth: CGFloat,
        lines: Lines
    ) {
        // The two settings that arrive as `Double` and are clamped on write, but
        // are `CGFloat` by the time they reach here and can be handed in by a
        // test. A non-finite value would reach a frame width and take the whole
        // layout with it.
        let logo = logoStyle == .hidden ? 0 : Self.positive(logoSize)
        let ring = meterStyle == .ring ? Self.positive(metrics.ringDiameter) : 0
        let panel = Self.positive(panelWidth)

        // The dial counts as a leading column of its own: under `.ring` it is
        // the row's meter, and every row draws one so the text beside it starts
        // at the same x whether or not there is a reading.
        let hasLeading = logoStyle != .hidden || meterStyle == .ring
        if hasLeading {
            // The inner gap exists only between two things.
            let inner = (logo > 0 && ring > 0) ? Tokens.Space.leadingItems : 0
            leadingWidth = logo + ring + inner + Tokens.Space.leadingColumn
        } else {
            leadingWidth = 0
        }
        textColumnWidth = max(0, panel - 2 * metrics.rowHorizontalPadding - leadingWidth)

        // With `numberOnly` the figure *is* the meter, so the rail outlives the
        // percentage switch there — otherwise a row can be configured down to a
        // name with no usage on it at all. Off, the rail closes for the whole
        // panel rather than row by row, which is what keeps every reading in the
        // window on one trailing edge.
        let showsFigure = showsPercentage || meterStyle == .numberOnly
        headlineRail = showsFigure ? metrics.headlineRail : 0
        secondaryRail = showsFigure ? metrics.secondaryRail : 0

        // The leading column is as tall as the taller of the two things in it,
        // plus the 1pt nudge that drops it onto the title's cap-height band.
        let leadingHeight = hasLeading ? max(logo, ring) + Tokens.Space.hairline : 0

        // The title line is one box holding the name, the figure and the action
        // buttons, and it is as tall as the tallest of the three whichever of
        // them a given row happens to draw.
        let titleHeight = max(
            Tokens.lineBox(metrics.titleSize),
            max(Tokens.lineBox(metrics.figureSize), Tokens.Control.rowIconButton)
        )

        // Under the ring the meter is the dial, which the leading column has
        // already paid for; the text column keeps its slot only under the bar
        // and the bare number.
        let meterHeight = lines.contains(.meter) && meterStyle != .ring
            ? Self.positive(metrics.barHeight)
            : 0
        let windowHeight = lines.contains(.window) ? Tokens.lineBox(metrics.detailSize) : 0
        // A caption belongs to the bar above it, so the two are one block at
        // half the pitch that separates one meter from the next.
        let joint = (meterHeight > 0 && windowHeight > 0) ? metrics.captionGap : 0
        let meterBlock = meterHeight + joint + windowHeight

        // The pace line is a sibling of that block rather than part of it: it is
        // a claim about the whole row, not a reading of the meter, and it sits
        // at the full pitch from it.
        let forecastHeight = lines.contains(.forecast) ? Tokens.lineBox(metrics.captionSize) : 0

        var textHeight = titleHeight
        if meterBlock > 0 { textHeight += metrics.contentSpacing + meterBlock }
        if forecastHeight > 0 { textHeight += metrics.contentSpacing + forecastHeight }

        height = max(leadingHeight, textHeight) + 2 * metrics.rowVerticalPadding
    }

    /// How many secondary chips fit `textColumnWidth`.
    ///
    /// Chips are a single unwrapped line, so their ceiling is width rather than
    /// a count: 520pt of empty panel takes all six, 300pt behind a 40pt logo and
    /// a dial takes one. A flat cap gets both ends of that wrong, and the narrow
    /// end is the one that matters — four chips compressed to four ellipses say
    /// strictly less than one chip that can still be read.
    ///
    /// Never zero and never clamped upward: the caller owns the other end, which
    /// is `secondaryWindowLimit`, and a line of no chips at all reports nothing
    /// about a service that has several windows.
    public static func chipLimit(textColumnWidth: CGFloat, captionSize: CGFloat) -> Int {
        let width = chipWidth(captionSize: captionSize)
        guard width > 0, textColumnWidth.isFinite, textColumnWidth > 0 else { return 1 }
        return max(1, Int(textColumnWidth / width))
    }

    /// One chip and the gap to the next.
    ///
    /// Built from the chip's own parts rather than from a multiple of the type
    /// size, which is what the two private copies did — and their `captionSize * 5`
    /// promised a chip more than a 300pt line holds, so the last one arrived as
    /// an ellipsis. The two runs inside are measured at `Tokens.figureWidth`:
    /// the reading is mono and that is its real advance, and the label is a word
    /// in SF Pro, whose average advance is narrower — so the estimate errs
    /// generous on the label, which is the direction that drops a chip rather
    /// than truncating one.
    ///
    /// The gap belongs in here. Read off the chip alone this is the exact width
    /// of one chip with nothing left over, and the division then always finds
    /// room for one more than the line has.
    private static func chipWidth(captionSize: CGFloat) -> CGFloat {
        let size = positive(captionSize)
        // The capsule's own padding, its dot, and the two gaps inside it.
        let furniture = 2 * Tokens.Space.small
            + Tokens.Control.chipDot
            + 2 * Tokens.Space.snug
        // A window's name — "Weekly", "Opus" — and its reading, "12/100" or
        // "100%". The label is the part allowed to truncate, so it is reserved
        // at the four characters that still name the window rather than at the
        // longest one a provider can send.
        let label = Tokens.figureWidth(size, digits: 4)
        let figure = Tokens.figureWidth(size, digits: 7)
        return furniture + label + figure + Tokens.Space.snug
    }

    /// A length, with a NaN answering 0 rather than surviving the arithmetic.
    /// `min`/`max` both lose to a NaN, so one reaching a frame width would take
    /// the layout with it.
    private static func positive(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
