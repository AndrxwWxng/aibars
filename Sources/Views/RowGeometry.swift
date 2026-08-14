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
    /// Three, because three is what changes a row's height by being there at all.
    /// The plan, the account label and the action buttons all live on the title
    /// line, which is one box whatever is in it, and the error and loading lines
    /// are the window line's own box with different words in it. The further
    /// windows are the fourth thing that costs height and they are a *count*
    /// rather than a bit, so they are `secondaryLines` below rather than a member
    /// here.
    ///
    /// `Lines.forecast` was here and is deleted. It named the pace caption —
    /// "on pace to cap in 40m" — and it was reserved by this type, named at
    /// fifteen assertion sites across `RowGeometryTests` and `AppearancePaneTests`
    /// (counted while rewriting them), and **inserted by nothing in
    /// `Sources/`**: `ProviderRow` drew `ForecastLine` as a fourth block without
    /// ever declaring it, so the first time a projection qualified for a row that
    /// row grew `contentSpacing + lineBox(captionSize)` — 19pt at cozy/100%, and
    /// about 171pt down a full panel — under the pointer. A correct reservation
    /// nothing calls is worse than no reservation at all: it reads as coverage.
    /// The pace is now a run on the caption line the row already reserves (see
    /// `ForecastLine`), so there is nothing left to reserve and nothing left to
    /// mistakenly insert. Bit 2 is retired rather than reused, so a stray
    /// `Lines(rawValue: 4)` from an old call site means nothing instead of
    /// meaning the trace.
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
        /// The budget block under every window the service reports: a
        /// secondary-thickness track and the "Budget · $30.00 left" line under
        /// it.
        ///
        /// **A setting — "has the user set a budget for this service" — and
        /// never `data.spend != nil`.** It is the third drawing this panel has
        /// shipped that nothing reserved, and it was the largest of them.
        /// `ProviderRow.detailContent` drew `BudgetMeter` as a fourth child of
        /// the row's stack whenever `BudgetPolicy` could compare a spend against
        /// a budget, and a spend is a fetch result: measured on a hosted row at
        /// the shipped 356pt panel, a Claude row with a budget set grew
        /// **22 / 26 / 30pt at compact / cozy / comfortable** the moment its
        /// first reading landed with a spend in it — `contentSpacing +
        /// secondaryBarHeight + captionGap + lineBox(detailSize)`, which is
        /// 6 + 3 + 3 + 14 at cozy/100%. `MenuBarExtra` sizes its window to its
        /// content, so that is the panel resizing under the pointer, and it is
        /// half again the 19pt the pace block cost before it was folded away.
        ///
        /// Folding was the answer for the pace and cannot be the answer here: a
        /// track and a figure are not a run of prose and there is no line in the
        /// row for them to ride. So this reserves, exactly as the meter slot, the
        /// trace and the further-window ladder do, and the row draws an empty
        /// block in the states where there is no comparison to make. The price is
        /// bounded by the pane that sets the number: `BudgetPane` only offers a
        /// budget row for a service that has *already* reported a spend, so a
        /// budget existing means that service reported one — the empty block is
        /// the loading state, the failed state, and a service that has since
        /// stopped reporting, which are the same three states every other
        /// reserved slot in the row is already held open through.
        ///
        /// Bit 4 and not bit 2: bit 2 named the pace and stays retired, so an old
        /// `Lines(rawValue: 4)` still means nothing rather than quietly meaning
        /// the budget.
        public static let budget = Lines(rawValue: 1 << 4)
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

    /// The row's first line: the name, the account run, the action buttons and
    /// the figure rail, in one box as tall as the tallest thing the *settings*
    /// allow onto it.
    ///
    /// Published rather than kept private, because the drawing has to be able to
    /// floor itself at it. This is the reservation that came apart: it counts the
    /// action buttons whenever `rowActions != .never`, and `ProviderRow` drew
    /// them only `if provider.isAuthenticated`. So a row that had reported and
    /// whose session then died — which is precisely the state `Lines` keeps every
    /// other box open through — held the reservation and lost the drawing.
    /// Measured on a hosted row at 356pt, the row shrank **2pt at cozy/100%,
    /// 4pt at cozy/85% and 4pt at compact/85%**, and `SessionStore` clears
    /// `isAuthenticated` in the same main-actor turn it stores the failure in, so
    /// with the panel open that is `MenuBarExtra` resizing its window under the
    /// pointer — four rows of it moved the panel 8–16pt.
    ///
    /// `ProviderRow.titleLine` and `AppearancePane`'s sample row now both hold
    /// their first line at this number, so what is on that line can change
    /// freely — buttons, a `Sign in` word, a spinner, a three-digit reading —
    /// without any of it reaching the row's height. It is a floor and not a
    /// frame: a text line at the top of the scale range measures a fraction over
    /// its box, and a row would rather be a point tall than clip a descender.
    public let titleLineHeight: CGFloat

    /// The row's height, its own vertical padding included and the gap to the
    /// next row excluded.
    ///
    /// Reserved, and reserved generously in one place: the title line is held at
    /// the height of the action buttons whenever the setting can ever draw them,
    /// whether or not this particular row is in a state that has anything to
    /// refresh. With `rowActions == .never` they are neither drawn nor reserved.
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

    /// The most further-window lines this type will reserve, whatever it is
    /// handed.
    ///
    /// It is the stepper's own ceiling — `secondaryWindowLimit` is clamped to
    /// `1...6` on write and again by `normalize()` at the end of
    /// `AppearanceSettings.init`, so a hand-edited defaults file carrying `10000`
    /// is already a 6 by the time any row reads it. This is the second line of
    /// defence and not the only one, and it is the line that covers what the
    /// settings cannot: `secondaryLines` is a bare `Int` on a public initialiser
    /// with three callers, and the day one of them works its count out from a
    /// payload rather than from the stepper — which is exactly the mistake this
    /// parameter exists to prevent — the row would take whatever the payload had
    /// in it. Twenty lines of arithmetic is a 400pt row and `Int.max` is a frame
    /// no layout survives, which is the same class of untrusted input
    /// `positive(_:)` guards a NaN against and deserves the same treatment rather
    /// than a comment saying it cannot happen.
    public static let secondaryLineCeiling = 6

    /// - Parameter secondaryLines: How many further-window lines the row holds
    ///   open. A *setting* — `secondaryWindowLimit` under
    ///   `secondaryWindows == .expanded`, zero under every other style — and
    ///   never `data.secondary.count`. See the block that spends it below.
    public init(
        metrics: AppearanceSettings.Metrics,
        showsPercentage: Bool,
        meterStyle: AppearanceSettings.MeterStyle,
        logoStyle: AppearanceSettings.LogoStyle,
        logoSize: CGFloat,
        panelWidth: CGFloat,
        rowActions: AppearanceSettings.RowActionVisibility = .onHover,
        // Ahead of `lines` rather than after it, and defaulted, so no existing
        // call site has to be touched to gain it — the same courtesy
        // `ProviderRow.init` extends its three stores.
        secondaryLines: Int = 0,
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
        //
        // "Whichever of them a given row happens to draw" is the whole of it, and
        // it is why `titleLineHeight` is published: the row's *state* decides
        // what lands on this line — buttons on a live row, the word `Sign in` on
        // a dead one, a spinner, a warning triangle, a reading — and none of that
        // may reach the height. `ProviderRow` floors its first line at this and
        // is therefore free to put whatever the state calls for on it.
        //
        // The rail's glyph square is not in this max and does not need to be:
        // `Metrics.figureSize` floors at 11, so `lineBox(figureSize)` is at least
        // 14, which is exactly `ProviderRow.railGlyph`. The triangle, the dot and
        // the spinner all draw inside a box this line has already paid for — by
        // arithmetic rather than by coincidence, which is worth stating here
        // because the two constants live in different files.
        var titleHeight = max(
            Tokens.lineBox(metrics.titleSize),
            Tokens.lineBox(metrics.figureSize)
        )
        if rowActions != .never {
            titleHeight = max(titleHeight, Tokens.Control.rowIconButton)
        }
        titleLineHeight = titleHeight

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

        // The further windows, one line each, at the full pitch from the meter
        // block and from each other. The count is the *setting* and never
        // `data.secondary.count`, and that distinction is the whole of why this
        // parameter exists: under `.expanded` the row used to draw one line per
        // window the fetch happened to return, so a service that answered with
        // three of them grew its row about 60pt the moment the answer landed —
        // and the panel, which `MenuBarExtra` sizes to its content, moved under
        // the pointer. The Dashboard preset ships `.expanded` with a limit of
        // six, so this was default-on for anyone who chose that preset.
        //
        // Reserving the ceiling rather than the count is the trade, and it is
        // the same one the meter slot and the trace already make: a service that
        // reports one window under a limit of six holds five empty lines. That
        // is the price of a height that cannot move, and there are two things to
        // say for it beyond "the alternative is the bug". The first is that the
        // stepper is the remedy and it is the control the user already has —
        // under `.expanded` it now means exactly "how many further-window lines
        // every row makes room for", which is a rule that can be stated. The
        // second is that it finishes an argument the drawing was already making:
        // `ProviderRow.secondaryWindows` puts these on the enclosing stack's own
        // pitch precisely so "the third window of one service sits on the same
        // line as the third of the next", and a ladder of the same depth on every
        // row is what makes that true of rows with different numbers of windows.
        let secondaryLineCount = min(max(0, secondaryLines), Self.secondaryLineCeiling)
        // `detailSize` and not `captionSize`: every one of these lines is a
        // `MetricCaption(isSecondary: true)` or a `SecondaryValue`, and both hold
        // themselves at `lineBox(detailSize)`.
        let secondaryHeight = CGFloat(secondaryLineCount)
            * (metrics.contentSpacing + Tokens.lineBox(metrics.detailSize))

        // A sibling of the meter block and of the further windows, at the full pitch
        // from both: the trace is a reading of the same window the meter reads,
        // taken over a day instead of at an instant, and a block of its own is
        // what says so. Reserved at `Metrics.sparklineHeight` exactly — not a
        // floor, unlike the text lines: a text line at the top of the scale range
        // can measure a fraction over its box and the row would rather be a point
        // tall than clip a descender, where a `Path` in a fixed frame has no such
        // fraction and reserving slack for one would be 1pt of dead air on every
        // row.
        let sparklineHeight = lines.contains(.sparkline) ? Self.positive(metrics.sparklineHeight) : 0

        // The budget block, last of the four because it is drawn last: the user's
        // own number goes under every window the service itself reports. Its two
        // parts sit at `captionGap` rather than at `contentSpacing` for the same
        // reason the meter and its caption do — the line names the track above it,
        // so the two are one block — and `BudgetMeter` sets its own stack at
        // exactly that. `secondaryBarHeight` and not `barHeight`: a budget is
        // drawn at the thinner weight so it cannot outrank the quota above it.
        //
        // Reserved from `Lines.budget`, which is a setting. The argument for that
        // is written out on the flag; the arithmetic is 3 + 3 + 14 = 20pt at
        // cozy/100%, and it measures to the point against a hosted row.
        let budgetHeight = lines.contains(.budget)
            ? Self.positive(metrics.secondaryBarHeight)
                + metrics.captionGap
                + Tokens.lineBox(metrics.detailSize)
            : 0

        var textHeight = titleHeight
        if meterBlock > 0 { textHeight += metrics.contentSpacing + meterBlock }
        // Between the meter block and the further windows because that is the
        // order the row draws them. Addition commutes, so the sum does not care;
        // a reservation that reads in a different order from the drawing is how
        // the two come apart when somebody next edits one of them.
        if sparklineHeight > 0 { textHeight += metrics.contentSpacing + sparklineHeight }
        // Its own pitch is already inside the term — one `contentSpacing` per
        // line, which is what a stack of `n` children inside a stack costs.
        textHeight += secondaryHeight
        // Last, under the ladder, because that is the order the row draws them.
        if budgetHeight > 0 { textHeight += metrics.contentSpacing + budgetHeight }

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
        // Three cells at `.regular`, which is what `OverflowChip` draws "+99" in
        // — and `+` measures exactly a digit in this face, so three cells is the
        // string rather than an estimate of it. The weight is named because under
        // the mono face this parameter did not exist and could not have been
        // wrong: one advance served every weight. Here a cell cut at a weight the
        // run does not take is either slack or an overflow, and which one it is
        // depends on which way it is wrong. `OverflowChip` is `fixedSize`, so
        // this side is the overflow.
        let overflowChip = Tokens.figureWidth(size, digits: 3, weight: .regular)
            + Tokens.Space.medium
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
        // At `.regular`, because a chip's label is prose and `SecondaryChip` sets
        // it there. Cells of the figure face for a run that is not a figure, as
        // above — the cell is a unit of measure here rather than a claim about
        // what is in it.
        Tokens.figureWidth(positive(chipSize), digits: 8, weight: .regular)
    }

    /// A window's reading: "61%", "12/100", "1.0k/1.0k", "9767.2M".
    ///
    /// Nine cells, and the string that used to justify them is gone. It was
    /// `9767.2M/0` — `ClaudeCodeProvider` reports its token windows at `limit: 0`,
    /// and the chip rendered "no ceiling" as a fraction over zero. A window with
    /// no cap now reads as the bare value, so that reading is seven characters
    /// and not nine.
    ///
    /// Nine stays, and not out of inertia: what is left at the wide end is a
    /// *capped* count with both halves formatted. `CursorProvider` reports request
    /// buckets as counts, and `UsageMetric.format` renders a thousand of them as
    /// `1.0k` — so `1.0k/1.0k` is nine characters, and nine cells is what holds
    /// it. That is the reading this rail is cut for. The arithmetic that used to
    /// be quoted here — 9 × 6.8035 = 61.23pt against the 62 nine cells reserve —
    /// was SF Mono's single advance; the cell is measured off the real face at
    /// the weight the reading is drawn in now, so the count is the claim and the
    /// points are not. A wider pair truncates against the ceiling `chipRuns` hands the run
    /// rather than overhanging it, which is the direction this whole section was
    /// rebuilt to fail in.
    private static func chipReadingRail(_ chipSize: CGFloat) -> CGFloat {
        // At `titleWeight`, which is where `SecondaryChip` sets its reading.
        Tokens.figureWidth(positive(chipSize), digits: 9, weight: Tokens.Ramp.titleWeight)
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
        // Each run at the weight `SpendFigure` sets it in: the amount at
        // `titleWeight`, because it is the reading; the `est.` qualifier and the
        // middle dot after it at `.regular`, because they are the caption's own
        // words. The amount is the term that matters — it is the widest and it is
        // the one drawn heaviest, and reserving it at the caption's weight would
        // be 3.5% short of the thing `layoutPriority(1)` guarantees will be drawn
        // whatever else has to give.
        return Tokens.figureWidth(size, digits: 9, weight: Tokens.Ramp.titleWeight)
            + Tokens.Space.snug
            + Tokens.figureWidth(size, digits: 3, weight: .regular)
            + Tokens.Space.snug
            + Tokens.unitWidth(size, weight: .regular)
    }

    /// A length, with a NaN answering 0 rather than surviving the arithmetic.
    /// `min`/`max` both lose to a NaN, so one reaching a frame width would take
    /// the layout with it.
    private static func positive(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
