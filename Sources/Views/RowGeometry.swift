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
    /// Four, because four is what changes a row's height. The plan, the account
    /// label and the action buttons all live on the title line, which is one box
    /// whatever is in it, and the error and loading lines are the window line's
    /// own box with different words in it.
    public struct Lines: OptionSet, Equatable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// The row occupies its meter slot. Under `.bar` that is a track when the
        /// window has a real quota and an empty box of the same height when it
        /// does not — loading, failed, or a service reporting no quota at all.
        /// Under `numberOnly` the figure on the title line is the meter and the
        /// slot stands empty at that same height on every row. Both drawings are
        /// one height, which is what the row is squared against.
        ///
        /// Under `.ring` this flag reserves nothing here: the dial in the leading
        /// column is the meter and the leading column has already paid for it
        /// (see the `meterStyle != .ring` gate below).
        ///
        /// It named two more drawings until this pass and neither exists.
        /// `Meter.hairline` was deleted — under `.bar` a quotaless row drew that
        /// rule between its own title and caption, indistinguishable from a row
        /// divider — and nothing stands in for a meter under `numberOnly` either:
        /// the slot is held open and left empty rather than filled with a second
        /// drawing of the reading already on the title line.
        public static let meter = Lines(rawValue: 1 << 0)
        /// The line under the meter: "5h · resets 1h 20m", "Not connected",
        /// "Loading…", an error.
        public static let window = Lines(rawValue: 1 << 1)
        /// The pace caption: "on pace to cap in 40m". The one line the row draws
        /// only when there is something honest to say, which is why it is asked
        /// about rather than assumed.
        public static let forecast = Lines(rawValue: 1 << 2)
        /// The twenty-four-hour trace under the meter block.
        ///
        /// Presence here is a *setting* and the same one bit the meter slot turns
        /// on — has this row anything to report — and never whether the trace has
        /// anything in it. That is the whole discipline: a row whose slot appeared
        /// when its first hour of history landed would grow 6 + 18 = 24pt under
        /// the pointer a day after the service was connected, which is the resize
        /// this type exists to make impossible. An empty slot beside a full one is
        /// the price, and it is the same price the meter slot has always paid.
        public static let sparkline = Lines(rawValue: 1 << 3)
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
        rowActions: AppearanceSettings.RowActionVisibility = .onHover,
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

        // The leading column is as tall as the taller of the two things in it.
        // No nudge: the mark box and the title box are the same 18pt at the
        // defaults, and a 1pt lift onto a band it is already on was a 1pt lie
        // told in two files at once.
        let leadingHeight = hasLeading ? max(logo, ring) : 0

        // The title line is one box holding the name, the figure and the action
        // buttons, and it is as tall as the tallest of the three whichever of
        // them a given row happens to draw. The buttons count only when the
        // setting can ever draw them: with `.never` they are neither drawn nor
        // reserved, so reserving their height there was 2pt of dead air on
        // every row of the panel.
        var titleHeight = max(
            Tokens.lineBox(metrics.titleSize),
            Tokens.lineBox(metrics.figureSize)
        )
        if rowActions != .never {
            titleHeight = max(titleHeight, Tokens.Control.rowIconButton)
        }

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

        // A sibling of the meter block and of the pace line, at the full pitch
        // from both: the trace is a reading of the same window the meter reads,
        // taken over a day instead of at an instant, and a block of its own is
        // what says so. Reserved at `Metrics.sparklineHeight` exactly — not a
        // floor, unlike the text lines: a text line at the top of the scale range
        // can measure a fraction over its box and the row would rather be a point
        // tall than clip a descender, where a `Path` in a fixed frame has no such
        // fraction and reserving slack for one would be 1pt of dead air on every
        // row.
        let sparklineHeight = lines.contains(.sparkline) ? Self.positive(metrics.sparklineHeight) : 0

        var textHeight = titleHeight
        if meterBlock > 0 { textHeight += metrics.contentSpacing + meterBlock }
        // Between the meter block and the pace line because that is the order the
        // row draws them. Addition commutes, so the sum does not care; a
        // reservation that reads in a different order from the drawing is how the
        // two come apart when somebody next edits one of them.
        if sparklineHeight > 0 { textHeight += metrics.contentSpacing + sparklineHeight }
        if forecastHeight > 0 { textHeight += metrics.contentSpacing + forecastHeight }

        height = max(leadingHeight, textHeight) + 2 * metrics.rowVerticalPadding
    }

    // MARK: - The chips on the caption line
    //
    // The whole of this section is one arithmetic with two consumers, and they
    // have to be read together: `chipLimit` says how many chips the line is
    // offered and `chipCap` says how wide each of them may draw. Multiply the
    // second by the first, add the gaps and the caption's own leading half, and
    // the answer is at most `textColumnWidth` — by construction rather than by
    // estimate, which is the whole point of the rebuild.
    //
    // It was an estimate, and it was wrong in four directions at once. It
    // reserved 25pt of capsule padding and a coloured dot that `SecondaryChip`
    // states outright it does not draw; it reserved the label at four cells
    // where real window labels run seven to nineteen characters; it reserved the
    // reading at seven cells where a capped count takes nine; and it used
    // `Space.snug` for the gap between two chips where `SecondaryChipRun` sets
    // its stack at `Space.medium`. Being small in three places and generous in
    // one, it handed a 356pt row three slots for a run whose ideal was 344pt of
    // a 304pt text column — and `SecondaryChipRun` is `.fixedSize()`, so the run
    // could not give the width back. The row drew past the ground, and because
    // every row in the list is `maxWidth: .infinity` inside one `VStack`, one bad
    // row dragged the marks off the leading edge of all of them. That is the
    // screenshot this rebuild answers.
    //
    // What makes it a bound rather than a better guess is that the drawing is
    // capped at the reservation: `SecondaryChip` is handed `chipCap` and splits
    // it between its two runs, so no provider's label length and no reading's
    // digit count can push the run past the column. The estimate and the drawing
    // agree by arithmetic; nothing here hopes.

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
    /// about a service that has several windows. The floor is safe because
    /// `chipCap` floors with it — when the line cannot hold a whole chip the one
    /// chip it does hold is cut down to what is left rather than drawn at full
    /// stretch past the edge.
    ///
    /// `chipSize` is `Metrics.detailSize` and not `captionSize`. `SecondaryChip`
    /// and `OverflowChip` both size themselves from `detailSize`, which is a
    /// point larger at every density, so a budget measured at the caption's size
    /// was one type step below the type being drawn.
    public static func chipLimit(
        textColumnWidth: CGFloat,
        chipSize: CGFloat,
        carriesSpend: Bool
    ) -> Int {
        let width = chipWidth(chipSize: chipSize)
        let residue = chipResidue(
            textColumnWidth: textColumnWidth,
            chipSize: chipSize,
            carriesSpend: carriesSpend
        )
        guard width > 0, residue > 0 else { return 1 }
        return max(1, Int(residue / width))
    }

    /// The widest one chip may draw, which is what `SecondaryChip` frames itself
    /// against.
    ///
    /// A chip's share of the line rather than a flat ceiling, and the difference
    /// is worth a paragraph because both directions of it are a real defect. Cut
    /// at the eight-cell label cap, a 520pt panel truncates "Weekly · all models"
    /// to "Weekly · a…" with 165pt of that line standing empty — a caption
    /// abbreviating itself in a panel the user widened precisely so it would not
    /// have to. Cut at nothing, the run overflows the column, which is the
    /// shipped bug. So the cap is the larger of the chip's own stretch and what
    /// the line has to divide between the chips it is holding, and never more
    /// than the line has left at all:
    ///
    ///     cap = min(residue, max(stretch, (residue − gaps) / count))
    ///
    /// Every term is a setting. The last case is the floor `chipLimit` returns 1
    /// in: a 300pt panel at comfortable density and 130% type, with a spend on
    /// the line, has 83pt for a chip whose stretch is 169 — so it draws 83 and
    /// truncates, which is a chip that reports something in a panel that still
    /// has its edges.
    public static func chipCap(
        textColumnWidth: CGFloat,
        chipSize: CGFloat,
        carriesSpend: Bool
    ) -> CGFloat {
        let residue = chipResidue(
            textColumnWidth: textColumnWidth,
            chipSize: chipSize,
            carriesSpend: carriesSpend
        )
        // The count this divides by is the count the row will draw, read from
        // `chipLimit` rather than worked out again: the two are one arithmetic,
        // and a cap sized for a different number of chips than the line is handed
        // is the same class of mistake as the estimate this replaced.
        let count = CGFloat(chipLimit(
            textColumnWidth: textColumnWidth,
            chipSize: chipSize,
            carriesSpend: carriesSpend
        ))
        let share = (residue - (count - 1) * Tokens.Space.medium) / count
        let stretch = chipWidth(chipSize: chipSize) - Tokens.Space.medium
        return min(residue, max(stretch, share))
    }

    /// How the windows a service reports divide between chips of their own and
    /// the `+N` standing for the rest.
    ///
    /// The overflow chip takes a slot off the line rather than being added to it
    /// — pushed past the trailing edge it would be truncated away, which is the
    /// failure it exists to report — and one real chip is always kept, because
    /// `+6` alone names no window at all.
    ///
    /// It lives here because it had come to live in two places. `ProviderRow` and
    /// the Appearance pane's `SampleRow` each held a private copy, identical line
    /// for line, and the moment one of them learned `yieldsToTheSentence` the
    /// preview stopped previewing: measured at 520pt, 318 columns of the caption
    /// line differed between the two rows, which is one of them fitting a
    /// sentence the other is not. That is the exact class of drift the rest of
    /// this file was written to close, and `AppearancePaneTests` caught it in the
    /// same run it was introduced.
    ///
    /// `yieldsToTheSentence` gives one chip back to the caption's leading half —
    /// see `ProviderRow.yieldsToTheSentence` for when and why. It is width only
    /// and can never be a height, because the caption is one `lineBox` whatever
    /// is on it.
    public static func chipSplit(
        count: Int,
        limit: Int,
        yieldsToTheSentence: Bool = false
    ) -> (shown: Int, hidden: Int) {
        let limit = yieldsToTheSentence ? max(1, limit - 1) : limit
        guard count > limit else { return (count, 0) }
        let shown = max(1, limit - 1)
        return (shown, count - shown)
    }

    /// How a chip's cap divides between its two runs.
    ///
    /// The reading is served first and the label takes what is left, which is
    /// the chip's own stated rule: the reading is why the chip is there, so the
    /// label is what gives. The reading never needs more than its nine cells, so
    /// on a wide line every point of the cap above them goes to the label —
    /// which is what lets "Weekly · all models" draw whole on a 520pt panel.
    /// Squeezed, the label goes to nothing before the reading gives a point, and
    /// below `snug + one reading` the reading gives too rather than overhang a
    /// cap it was handed.
    ///
    /// `label + Space.snug + reading == cap` exactly, which is what lets the
    /// reservation be stated as one number per chip.
    public static func chipRuns(cap: CGFloat, chipSize: CGFloat) -> (label: CGFloat, reading: CGFloat) {
        // The chip's inner gap is spent whatever else it can afford, so the two
        // runs divide what is left of the cap after it.
        let inner = max(0, positive(cap) - Tokens.Space.snug)
        let reading = min(inner, chipReadingRail(chipSize))
        return (inner - reading, reading)
    }

    /// What the trailing half of the caption line may spend on chips: the text
    /// column, less the gap to the sentence beside it, less the sentence's own
    /// incompressible half, less the cell the `+N` takes when there is one.
    ///
    /// The `+N` is reserved up front rather than counted as a chip because
    /// `chipSplit` does not always take a slot for it: at one chip it keeps its
    /// one real chip and puts the `+N` beside it, since "+6" alone names no
    /// window. That is the one case where the run draws more items than the
    /// limit, and reserving three cells and a gap here is what makes it fit.
    private static func chipResidue(
        textColumnWidth: CGFloat,
        chipSize: CGFloat,
        carriesSpend: Bool
    ) -> CGFloat {
        let size = positive(chipSize)
        let column = positive(textColumnWidth)
        // `MetricCaption` and `StatusLine` both set their line at `Space.medium`
        // between the sentence and the run.
        let toTheSentence = Tokens.Space.medium
        let overflowChip = Tokens.figureWidth(size, digits: 3) + Tokens.Space.medium
        return max(0, column - toTheSentence - overflowChip - (carriesSpend ? spendReserve(size) : 0))
    }

    /// One chip and the gap to the next.
    ///
    /// Built from the chip's own two runs at the size the chip is set in. The gap
    /// belongs in here: read off the chip alone this is the exact width of one
    /// chip with nothing left over, and the division then always finds room for
    /// one more than the line has. It reserves one gap more than the run draws,
    /// which is the direction that drops a chip rather than clipping one.
    private static func chipWidth(chipSize: CGFloat) -> CGFloat {
        chipLabelCap(chipSize)
            + Tokens.Space.snug
            + chipReadingRail(chipSize)
            + Tokens.Space.medium
    }

    /// A window's name — "Weekly", "30 days", "Weekly · all models".
    ///
    /// Eight cells, and this is the one number in the section that is a taste
    /// rather than a measurement, so here is the arithmetic behind it. It is the
    /// widest cap that still fits two chips on the shipped 356pt panel at cozy
    /// and 100%: the text column is 304, the residue after the sentence gap, the
    /// `+N` cell and no spend is 267, and a chip at eight cells is 129 of it
    /// (267 / 129 = 2.07). Nine cells makes the chip 136 and 267 / 136 is 1.96,
    /// which costs the second chip outright.
    ///
    /// Cells of the *figure* face for a run set in SF Pro, deliberately: SF Pro's
    /// advance is the narrower of the two, so eight cells buys about ten
    /// characters — "Weekly" (37.8pt at 11) and "30 days" (41.6) fit whole inside
    /// the 55 this reserves, and "Weekly · all models" (100.5) truncates. A
    /// truncated label still names the window's family; the reading beside it is
    /// untouched, and that is the reading the chip is there for.
    private static func chipLabelCap(_ chipSize: CGFloat) -> CGFloat {
        Tokens.figureWidth(positive(chipSize), digits: 8)
    }

    /// A window's reading: "61%", "12/100", "1.0k/1.0k", "9767.2M".
    ///
    /// Nine cells, and the string that used to justify them is gone. It was
    /// `9767.2M/0` — `ClaudeCodeProvider` reports its token windows at `limit: 0`,
    /// and the chip rendered "no ceiling" as a fraction over zero. A window with
    /// no cap now reads as the bare value, so that reading is seven characters
    /// (7 × 6.8035 = 47.63pt in SF Mono at 11) and not nine.
    ///
    /// Nine stays, and not out of inertia: what is left at the wide end is a
    /// *capped* count with both halves formatted. `CursorProvider` reports request
    /// buckets as counts, and `UsageMetric.format` renders a thousand of them as
    /// `1.0k` — so `1.0k/1.0k` is nine characters, 9 × 6.8035 = 61.23pt against
    /// the 62 that nine cells reserve. That is the reading this rail is now cut
    /// for. A wider pair truncates against the ceiling `chipRuns` hands the run
    /// rather than overhanging it, which is the direction this whole section was
    /// rebuilt to fail in.
    private static func chipReadingRail(_ chipSize: CGFloat) -> CGFloat {
        Tokens.figureWidth(positive(chipSize), digits: 9)
    }

    /// What `SpendFigure` cannot give back, on a line that carries one.
    ///
    /// `MetricCaption` puts the spend at `layoutPriority(1)` in every one of its
    /// four candidates, including the last, and the amount inside it is
    /// `.fixedSize()` — so the caption's leading half has a floor that no
    /// candidate can drop, and until this term existed nothing reserved it. It is
    /// subtracted before the division rather than given a rail of its own,
    /// because a rail around a leading figure is the indent `SpendFigure`
    /// deliberately gave up.
    ///
    /// Nine cells for the amount and not `Tokens.moneyWidth`'s eight: that rail
    /// covers `$1234.56`, and a four-figure bill formatted for a reader carries a
    /// thousands separator too — `$8,700.47`, nine characters, 61.20pt at 11
    /// against the 62 this reserves. Three cells for the "est." qualifier, which
    /// is SF Pro and therefore narrower than the cells it is counted in (19.51pt
    /// against 21), and it is only drawn on a locally-priced figure.
    ///
    /// Presence of a spend, never its amount: this decides how many chips ride
    /// the line and never how tall the line is, so it cannot resize a row when a
    /// bill lands.
    /// Nine cells, a gap, three cells, a gap and one cell — 62 + 4 + 21 + 4 + 7 =
    /// **98** at the shipped 11pt, where it was 87.
    ///
    /// The last two terms are the middle dot `MetricCaption` now draws between
    /// the amount and the window beside it. One mono cell is generous for a `·`
    /// set in SF Pro, and generous is the direction this whole section fails in:
    /// under-reserving the sentence's incompressible half is what let a chip run
    /// past the ground in the first place.
    private static func spendReserve(_ chipSize: CGFloat) -> CGFloat {
        let size = positive(chipSize)
        return Tokens.figureWidth(size, digits: 9)
            + Tokens.Space.snug
            + Tokens.figureWidth(size, digits: 3)
            + Tokens.Space.snug
            + Tokens.figureWidth(size, digits: 1)
    }

    /// A length, with a NaN answering 0 rather than surviving the arithmetic.
    /// `min`/`max` both lose to a NaN, so one reaching a frame width would take
    /// the layout with it.
    private static func positive(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
