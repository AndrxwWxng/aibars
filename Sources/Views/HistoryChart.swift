import SwiftUI

// ---------------------------------------------------------------------------
// What this file needs from the history store behind it, written down because
// it is the only contract between them and nothing here may widen it.
//
// `HistorySample`, per bucket:
//     at: Date          when the bucket is
//     percent: Double   0...1, the reading for that bucket
//
// And one assumption about the shape of a series, which is what makes a pointer
// x answerable as an index at all: a series is *regular* — one sample per
// bucket, evenly spaced across `range`, oldest first. That is how the store
// buckets (an hour, a day), and it is why `index(atX:in:count:)` divides the
// rail evenly instead of searching dates. A series handed over with holes
// punched in it still draws; it just reads a neighbouring bucket under the
// pointer.
//
// Retention, bucketing and what a bucket's number means — peak, last, mean —
// all belong to the store. This decides where the ink goes and what the pointer
// reads.
// ---------------------------------------------------------------------------

/// One line on the chart: a service's usage over the window being shown.
///
/// The colour arrives from the caller rather than being derived here. Which
/// service is which is the history view's decision — it may paint by brand or
/// by the usage ramp, and this has no business having an opinion about either.
public struct HistoryChartSeries: Identifiable, Equatable {
    /// The row's id — "claude#2", not "claude". Two accounts of one service
    /// have their own histories and are drawn as two lines.
    public let id: String
    public let title: String
    public let colour: Color
    /// Oldest first. Empty is allowed and draws nothing: a service with no
    /// history is not a service that sat at zero.
    public let points: [HistorySample]

    public init(id: String, title: String, colour: Color, points: [HistorySample]) {
        self.id = id
        self.title = title
        self.colour = colour
        self.points = points
    }
}

/// Where the marks go.
///
/// Separated from the view so the geometry can be asserted without hosting
/// anything: every position on the chart — a sample, a gridline, the threshold
/// rule, the bucket under the pointer — comes out of these functions, so a test
/// that pins them pins the picture.
///
/// `rect` is the plot area in the chart's own coordinates: the whole view minus
/// the axis gutter on the left and the label strip along the bottom. It is
/// passed in rather than computed here because only the view knows how much
/// room its labels took.
public enum HistoryChartLayout {

    /// Where one sample lands.
    public static func point(
        for sample: HistorySample,
        in rect: CGRect,
        range: ClosedRange<Date>
    ) -> CGPoint {
        CGPoint(x: x(for: sample.at, in: rect, range: range),
                y: y(for: sample.percent, in: rect))
    }

    /// Which sample the pointer is over, or nil when it is not over the plot.
    ///
    /// Nil rather than a clamped edge index: a pointer in the axis gutter is
    /// not reading anything, and answering "sample 0" for it would leave a
    /// figure on screen claiming the user is looking at a bucket they aren't.
    public static func index(atX x: CGFloat, in rect: CGRect, count: Int) -> Int? {
        guard count > 0, rect.width > 0 else { return nil }
        guard x >= rect.minX, x <= rect.maxX else { return nil }
        // One sample owns the whole rail; `count - 1` here would divide by
        // nothing.
        guard count > 1 else { return 0 }
        let fraction = (x - rect.minX) / rect.width
        let slot = Int((fraction * CGFloat(count - 1)).rounded())
        return min(max(slot, 0), count - 1)
    }

    /// The x of an instant. Internal rather than public: the axis and the
    /// gridlines need it, and a caller outside this file only ever has samples.
    static func x(for date: Date, in rect: CGRect, range: ClosedRange<Date>) -> CGFloat {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        // A range of one instant is not a rail. Everything in it lands on the
        // leading edge rather than on a division by zero.
        guard span > 0 else { return rect.minX }
        let fraction = date.timeIntervalSince(range.lowerBound) / span
        return rect.minX + rect.width * CGFloat(min(max(fraction, 0), 1))
    }

    /// The y of a 0...1 reading. Clamped, because an overage a provider reports
    /// is still drawn at the cap rather than above the plot.
    static func y(for ratio: Double, in rect: CGRect) -> CGFloat {
        guard ratio.isFinite else { return rect.maxY }
        return rect.maxY - rect.height * CGFloat(min(max(ratio, 0), 1))
    }
}

/// Usage over time, as lines on a shared 0–100% axis, with a readout that
/// follows the pointer.
///
/// Drawn with `Shape`s rather than Swift Charts. Charts is a system framework
/// at exactly the macOS 13 floor, so it would break no rule — but
/// `chartXSelection`, `chartScrollPosition` and every other interactive part of
/// it arrived in macOS 14, and hovering to read one bucket is this chart's whole
/// point. The interaction has to be hand-written either way, and once it is, the
/// axes are three lines of arithmetic that no longer justify the framework.
/// `Canvas` is not used for the reason it is never used for content: it exposes
/// nothing inside it to VoiceOver, so a chart drawn into one is a blank
/// rectangle to a screen reader.
///
/// Fixed height, flexible width. The caller chooses which services to plot and
/// over what window; it does not choose how tall the plot is, because the
/// gridline spacing and the axis strip are tuned against each other.
///
/// Two rules the chart is held to, both of them the app's rather than this
/// view's. Every number in here is SF Mono inside a reserved rail — the axis
/// gutter, the threshold label and the hover readout are three fixed columns, and
/// nothing mono is set outside one; the legend, the series names and the time
/// stamps are prose and are SF Pro with tabular digits. And nothing in here is
/// translucent: the plot is an opaque well, because a contrast ratio measured
/// against a named ground is a statement and the same ink over a material with
/// someone's wallpaper behind it is a hope.
public struct HistoryChart: View {
    public let series: [HistoryChartSeries]
    /// The window being shown, and the whole of the x axis. Given rather than
    /// derived from the samples, so a range with nothing in it draws as an empty
    /// window instead of collapsing onto whatever few points exist.
    public let range: ClosedRange<Date>
    /// Where the panel starts warning, drawn as a reference rule. Passed in
    /// rather than read from `AppearanceSettings`: this view is geometry over
    /// given data, and one that reached for a shared settings object could not
    /// be drawn twice with two different thresholds.
    public let warningThreshold: Double

    /// How far along the rail the pointer is, 0...1, or nil when it has left.
    ///
    /// A fraction rather than an x, because the readout line sits outside the
    /// `GeometryReader` and has no rect to measure against — this way it indexes
    /// a series through the same function the dots inside the reader use, rather
    /// than through a second copy of the same rounding.
    @State private var hoverFraction: Double?

    /// Read from the environment rather than taken as an argument: the caller has
    /// nothing to say about it that the environment has not already said. Three
    /// marks in here are hairlines — the frame, the threshold rule and the hover
    /// rule — and a hairline is the first thing a low-contrast display loses, so
    /// each is stepped up rather than drawn at its resting weight.
    @Environment(\.colorSchemeContrast) private var contrast

    public init(series: [HistoryChartSeries], range: ClosedRange<Date>, warningThreshold: Double) {
        self.series = series
        self.range = range
        self.warningThreshold = warningThreshold
    }

    // MARK: - Geometry

    /// Six steps of the spacing scale. Tall enough that the quarter gridlines
    /// stay around 30pt apart once the axis strip is off the bottom, which is
    /// where four lines read as a grid rather than as hatching.
    private static let chartHeight: CGFloat = Tokens.Space.huge * 6

    /// Room for "100%" at the axis size, plus the gap to the plot. Reserved
    /// whether or not a label is drawn in it, so two charts stacked in a pane
    /// start their plots at the same x.
    private static var gutterWidth: CGFloat {
        axisFigureWidth + Tokens.Space.small
    }

    /// The chart's one figure rail: "100" and the percent sign beside it, both at
    /// the axis size. Reserved rather than measured — a rail sized from the label
    /// currently in it is how "50%" and "100%" come to start the plot at two
    /// different x, which is the shift tabular figures were adopted to prevent.
    /// The threshold figure inside the plot is set in this rail too, because it is
    /// the same recipe.
    ///
    /// Three cells, a hairline and one more cell, which is the same arithmetic
    /// every rail in the panel is reserved by. It used to be four cells flat,
    /// because the unit was a smaller tick and fitted in the fourth; the tick is
    /// now the same size as the digits it annotates and no longer does.
    private static var axisFigureWidth: CGFloat {
        Tokens.figureWidth(Tokens.Ramp.caption, digits: 3)
            + Tokens.Space.hairline
            + Tokens.figureWidth(Tokens.Ramp.caption, digits: 1)
    }

    /// The strip under the plot that the time labels sit in.
    private static var axisStripHeight: CGFloat {
        Tokens.Space.snug + Tokens.lineBox(Tokens.Ramp.caption)
    }

    /// The plot area inside the chart's own bounds.
    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: gutterWidth,
            y: 0,
            // Never negative: a pane narrower than its own gutter would
            // otherwise hand every layout function an inverted rect.
            width: max(0, size.width - gutterWidth),
            height: max(0, size.height - axisStripHeight)
        )
    }

    /// The rail as a fraction, so a hover fraction and an x resolve through one
    /// function. `index(atX:in:count:)` rejects anything off the rail, which is
    /// also how a pointer in the gutter is refused.
    private static let unitRail = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 1.5pt: a hairline disappears against the well over these line lengths,
    /// and 2pt with several overlapping series is a smear.
    private static let lineWidth: CGFloat = 1.5
    /// The dot marking a series' sample under the pointer.
    private static let dotRadius: CGFloat = 2.5
    /// The ink both reference rules take — the threshold and the pointer.
    ///
    /// `notchColour(increased:)` used to answer this. The pace riser it was named
    /// for has gone, and neither of these marks may take a colour anyway: hue on
    /// this plot names a service, so a rule carrying one reads as one more
    /// service. The one neutral ink is what is left, and it clears the well by
    /// more than the resting notch pair did, so only the width still steps.
    private static let ruleInk = Tokens.Ink.muted
    /// A rule's width, stepped up under increased contrast, because colour alone
    /// cannot rescue a hairline on a display that is losing hairlines.
    private var ruleWidth: CGFloat {
        contrast == .increased ? 2 : Tokens.Control.hairline
    }
    /// Quarters. Five lines, four gaps — enough to read a height off without
    /// the grid becoming the picture.
    private static let gridStops: [Double] = [0, 0.25, 0.5, 0.75, 1]
    /// Only every other gridline gets a figure. Five of them down a 127pt gutter
    /// is a column of numbers beside a chart with four points in it.
    private static let labelledStops: [Double] = [0, 0.5, 1]
    /// Where a long window starts being read as dates rather than as clock
    /// times. Two days, because that is the point at which the same hour label
    /// appears twice on one axis.
    private static let clockSpan: TimeInterval = 48 * 60 * 60

    /// The series with something to draw. A series with no samples is not a
    /// series at zero, so it is dropped rather than flattened onto the floor.
    private var plotted: [HistoryChartSeries] {
        series.filter { !$0.points.isEmpty }
    }

    /// The series the pointer snaps to: the one with the most buckets, so the
    /// rule lands on a real sample rather than between two of them. Ties go to
    /// the first, which is the order the caller chose.
    private var rail: HistoryChartSeries? {
        plotted.max { $0.points.count < $1.points.count }
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            readoutLine
            plot
        }
        .padding(Tokens.Space.large)
        // One stroke, no shadow and no inner highlight, like every other edge in
        // the app. Read through `borderOpacity(increased:)` rather than off
        // `Fill.border`: the border steps up under increased contrast, and a
        // direct read is a border that quietly doesn't.
        .overlay(
            Tokens.surface(Tokens.Radius.panel)
                .strokeBorder(
                    Tokens.quiet(Tokens.borderOpacity(increased: contrast == .increased)),
                    lineWidth: Tokens.Control.hairline
                )
        )
    }

    private var plot: some View {
        GeometryReader { geo in
            let rect = Self.plotRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                // The plot is one of the three wells the palette names, and it is
                // opaque. The panel's own material is the only translucency in the
                // application, and this chart carries numbers: an axis figure and
                // a readout have to sit on a ground whose contrast can be
                // measured rather than on one that borrows whatever wallpaper is
                // behind the window.
                Tokens.surface(Tokens.Radius.chip)
                    .fill(Tokens.Surface.well)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                gridlines(in: rect)
                axisFigures(in: rect)
                timeLabels(in: rect)

                if plotted.isEmpty {
                    emptyState(in: rect)
                } else {
                    thresholdRule(in: rect)
                    lines(in: rect)
                    hoverMarks(in: rect)
                }
            }
            // The whole plot is the hover target, gutter included, or the
            // pointer stops reading the moment it crosses a gridline label.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Stored unclamped. Off the rail is a value the index
                    // function already refuses, and refusing it twice is two
                    // places for the bounds to disagree.
                    hoverFraction = rect.width > 0
                        ? Double((location.x - rect.minX) / rect.width)
                        : nil
                case .ended:
                    hoverFraction = nil
                @unknown default:
                    hoverFraction = nil
                }
            }
        }
        .frame(height: Self.chartHeight)
        // The lines carry the reading and say nothing out loud. Each one is made
        // an element below; this is the box they live in.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage history")
    }

    // MARK: - The grid

    private func gridlines(in rect: CGRect) -> some View {
        ForEach(Self.gridStops, id: \.self) { stop in
            Rectangle()
                .fill(Tokens.Meter.track)
                .frame(width: rect.width, height: Tokens.Control.hairline)
                .position(x: rect.midX, y: HistoryChartLayout.y(for: stop, in: rect))
        }
    }

    /// The panel's warning level, as a reference.
    ///
    /// Dashed, and drawn in the neutral ink rather than in the ramp's red: colour
    /// on this chart says which service a line belongs to, so a second red thing
    /// running across the plot would read as one more service. It is a mark on the
    /// frame rather than a reading, so it takes the frame's ink.
    private func thresholdRule(in rect: CGRect) -> some View {
        let y = HistoryChartLayout.y(for: warningThreshold, in: rect)
        let labelHeight = Tokens.lineBox(Tokens.Ramp.caption)
        // Above its own rule by default, and under it when the threshold sits so
        // high that the label would go off the ceiling — a threshold of 100% is
        // allowed, and a figure clipped in half is not a reading.
        let labelY = y - labelHeight / 2 < rect.minY
            ? y + labelHeight / 2
            : y - labelHeight / 2

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            .stroke(
                // The width steps up under increased contrast: a 1pt dashed mark
                // is what such a display loses first, and this one is the only
                // thing on the plot saying where the panel starts warning.
                Self.ruleInk,
                style: StrokeStyle(lineWidth: ruleWidth, dash: [3, 3])
            )

            figure(warningThreshold, size: Tokens.Ramp.caption, tint: Tokens.Ink.muted)
                // The same recipe as an axis figure, so the same rail. A
                // threshold of 9% and one of 100% are one column, and mono
                // outside a reserved rail is a font choice rather than a column.
                // `fixedSize` first, as on the axis: the rail is sized for the
                // widest reading it can hold, and it reserves the width rather
                // than being allowed to compress the run inside it.
                .fixedSize()
                .frame(width: Self.axisFigureWidth, alignment: .trailing)
                // Held inside the trailing edge, where a usage line is least
                // likely to be passing through it: a series near its cap runs
                // along the top of the plot, and this rule is drawn under that.
                .position(
                    x: rect.maxX - Tokens.Space.small - Self.axisFigureWidth / 2,
                    y: labelY
                )
        }
    }

    // MARK: - The lines

    private func lines(in rect: CGRect) -> some View {
        ForEach(plotted) { entry in
            Polyline(points: entry.points.map {
                HistoryChartLayout.point(for: $0, in: rect, range: range)
            })
            .stroke(
                entry.colour,
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            )
            // One bucket has no line in it, so it is drawn as the dot it is.
            // Without this a service with a single reading looks like a service
            // with none, which is the one thing this chart must not say.
            .overlay(singlePointMark(entry, in: rect))
            .accessibilityElement()
            .accessibilityLabel(entry.title)
            .accessibilityValue(Self.summary(of: entry))
        }
    }

    @ViewBuilder
    private func singlePointMark(_ entry: HistoryChartSeries, in rect: CGRect) -> some View {
        if entry.points.count == 1, let only = entry.points.first {
            Circle()
                .fill(entry.colour)
                .frame(width: Self.dotRadius * 2, height: Self.dotRadius * 2)
                .position(HistoryChartLayout.point(for: only, in: rect, range: range))
        }
    }

    // MARK: - Hover

    /// The rule and the dots under the pointer.
    ///
    /// Nothing is drawn when the pointer is off the plot, and nothing reserves
    /// space for it: the readout line above already holds its height with the
    /// legend, so the pane cannot resize under the pointer that summoned it.
    @ViewBuilder
    private func hoverMarks(in rect: CGRect) -> some View {
        if let rail, let slot = self.slot(in: rail) {
            let x = HistoryChartLayout.point(
                for: rail.points[slot], in: rect, range: range
            ).x

            Rectangle()
                // The same mark as the threshold rule, stepped up the same way:
                // this is the line the reading on the readout belongs to, and a
                // vertical hairline over a well is the frailest thing here.
                .fill(Self.ruleInk)
                .frame(width: ruleWidth, height: rect.height)
                .position(x: x, y: rect.midY)

            ForEach(plotted) { entry in
                if let sample = self.sample(in: entry) {
                    Circle()
                        .fill(entry.colour)
                        .frame(width: Self.dotRadius * 2, height: Self.dotRadius * 2)
                        .position(HistoryChartLayout.point(for: sample, in: rect, range: range))
                }
            }
        }
    }

    /// Which of a series' own buckets the pointer is over.
    ///
    /// Each series is indexed against its own count rather than against the
    /// rail's, so a service connected halfway through the window reads its own
    /// buckets instead of an offset neighbour's.
    private func slot(in entry: HistoryChartSeries) -> Int? {
        guard let hoverFraction else { return nil }
        return HistoryChartLayout.index(
            atX: CGFloat(hoverFraction), in: Self.unitRail, count: entry.points.count
        )
    }

    private func sample(in entry: HistoryChartSeries) -> HistorySample? {
        guard let slot = slot(in: entry) else { return nil }
        return entry.points[slot]
    }

    // MARK: - The readout

    /// One line above the plot, in two states and one height: the legend at
    /// rest, and what the pointer is over while it is over something. The same
    /// line for both, because a readout that appears on hover would grow the
    /// pane it appeared in.
    private var readoutLine: some View {
        HStack(spacing: Tokens.Space.large) {
            if let stamp = hoveredStamp {
                Text(stamp)
                    // A stamp can carry a month, or a meridiem in the locales
                    // that write one, so it is SF Pro with tabular digits rather
                    // than mono: a run with a word in it is not a figure, and a
                    // run of unpredictable length could not be given the rail
                    // mono is only ever set inside.
                    .font(.system(size: Tokens.Ramp.detail, weight: Tokens.Ramp.emphasisWeight))
                    .monospacedDigit()
                    // `.foregroundColor` and never `.foregroundStyle` on a `Text`:
                    // with a `Text` receiver the compiler binds the macOS 14
                    // overload that returns `Text` and silently raises the app's
                    // floor past the stated minimum. Same trap as
                    // `Text.monospaced()`, and the same way out.
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: Tokens.Space.snug)

                ForEach(plotted) { entry in
                    hoveredFigure(for: entry)
                }
            } else {
                ForEach(plotted) { entry in
                    legendKey(for: entry)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: Tokens.lineBox(Tokens.Ramp.title), alignment: .leading)
    }

    /// The one place in the app where the tenth of a percent the panel drops
    /// survives. The panel refuses it because a tenth on a five-hour window is
    /// noise nobody can act on; here the user has asked one bucket a specific
    /// question, and rounding the answer to a whole percent makes two
    /// neighbouring hours read as the same hour.
    @ViewBuilder
    private func hoveredFigure(for entry: HistoryChartSeries) -> some View {
        if let sample = sample(in: entry) {
            figure(sample.percent, size: Tokens.Ramp.title, tint: entry.colour, fractionDigits: 1)
                // Reserved, not measured: "9.4%" and "100.0%" must not walk the
                // neighbouring service's figure sideways as the pointer moves.
                .frame(width: Self.readoutWidth, alignment: .trailing)
        }
    }

    private func legendKey(for entry: HistoryChartSeries) -> some View {
        HStack(spacing: Tokens.Space.snug) {
            Capsule(style: Tokens.Radius.style)
                .fill(entry.colour)
                .frame(width: Tokens.Space.medium, height: Self.lineWidth)
            // A series name is a word, so SF Pro: the legend names lines and
            // carries no reading.
            Text(entry.title)
                .font(.system(size: Tokens.Ramp.detail))
                .foregroundColor(Tokens.Ink.muted)
                .lineLimit(1)
        }
        // A key that truncates has stopped naming its line. Past a handful of
        // series the line runs out of room, and choosing what to plot is the
        // caller's job rather than this view's.
        .fixedSize()
    }

    /// Width held for a readout figure: "100.0" and the percent sign after it,
    /// reserved by the same three-part arithmetic as the axis rail.
    private static var readoutWidth: CGFloat {
        Tokens.figureWidth(Tokens.Ramp.title, digits: 5)
            + Tokens.Space.hairline
            + Tokens.figureWidth(Tokens.Ramp.title, digits: 1)
    }

    // MARK: - Axes

    /// The y axis: mono figures, trailing-aligned in the reserved gutter, so 0, 50
    /// and 100 share one right edge and the plot beside them starts at one x.
    private func axisFigures(in rect: CGRect) -> some View {
        ForEach(Self.labelledStops, id: \.self) { stop in
            figure(stop, size: Tokens.Ramp.caption, tint: Tokens.Ink.muted)
                .fixedSize()
                .frame(width: Self.axisFigureWidth, alignment: .trailing)
                .position(x: Self.axisFigureWidth / 2,
                          y: HistoryChartLayout.y(for: stop, in: rect))
        }
    }

    /// Three stamps under the plot: where the window starts, its middle, and
    /// where it ends. Not one per bucket — a ninety-day range would be ninety
    /// labels, and the pointer readout is what answers "which day is this".
    private func timeLabels(in rect: CGRect) -> some View {
        let middle = range.lowerBound.addingTimeInterval(rangeSpan / 2)
        return HStack(spacing: 0) {
            timeLabel(range.lowerBound).frame(maxWidth: .infinity, alignment: .leading)
            timeLabel(middle).frame(maxWidth: .infinity, alignment: .center)
            timeLabel(range.upperBound).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: rect.width)
        .position(
            x: rect.midX,
            y: rect.maxY + Tokens.Space.snug + Tokens.lineBox(Tokens.Ramp.caption) / 2
        )
    }

    /// SF Pro with tabular digits, for the same reason the hovered stamp is: a
    /// formatted date is a run with a word in it wherever the locale puts a month
    /// or a meridiem in it, and mono is only ever set inside a reserved rail. The
    /// three cells of the stack above are that reservation for the layout — each
    /// is a third of the plot whatever the stamp measures — so the plot cannot
    /// shift as the window changes resolution.
    ///
    /// `Ink.muted` and not a rank below it: one axis, one ink. The figures up the
    /// left are muted, and a bottom axis a rank fainter than them read as a
    /// lesser kind of label rather than as the other half of the same frame. The
    /// panel has no third ink to reach for in any case.
    private func timeLabel(_ date: Date) -> some View {
        Text(Self.stamp(for: date, span: rangeSpan))
            .font(.system(size: Tokens.Ramp.caption))
            .monospacedDigit()
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
    }

    /// Said in the plot rather than instead of it. The grid and the axis stay
    /// drawn, so an empty window reads as a window with nothing in it — which is
    /// not the same as a service sitting at zero, and must not be drawn as one.
    private func emptyState(in rect: CGRect) -> some View {
        Text("No history yet")
            .font(.system(size: Tokens.Ramp.title))
            .foregroundColor(Tokens.Ink.muted)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Figures

    /// A percentage set the way every figure in this app is set: one mono run at
    /// one size, on one baseline, with the digits carrying the reading and the
    /// percent sign neutral beside them.
    ///
    /// The sign used to be a smaller tick raised onto the digits' baseline. It is
    /// the same size as them now — `92` with a tiny lifted `%` after it is fussy
    /// where a plain `92%` is not, and the unit was never small enough to be
    /// ignored nor large enough to be read, which is the worst of both.
    ///
    /// Built from a `FormatStyle` rather than interpolated, so the decimal
    /// separator stays the reader's. `.number` over a scaled ratio rather than
    /// `.percent`, because `.percent` writes the sign into the run and the sign
    /// is the part being set separately here.
    ///
    /// Two `Text`s in a stack rather than one concatenation: the digits take the
    /// reading's tint and the sign is always `Ink.muted`, and giving two runs of
    /// one `Text` two colours needs macOS 14.
    ///
    /// The sign is neutral in every state and under every ramp, which is the rule
    /// the whole app follows: the unit annotates the number rather than being part
    /// of the reading, and holding it neutral is what leaves the digits as the only
    /// run that can gain a colour.
    private func figure(
        _ ratio: Double,
        size: CGFloat,
        tint: Color,
        fractionDigits: Int = 0
    ) -> some View {
        let value = (ratio.isFinite ? min(max(ratio, 0), 1) : 0) * 100
        return HStack(spacing: 0) {
            Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                .font(.system(size: size,
                              weight: Tokens.Ramp.emphasisWeight,
                              design: Tokens.Ramp.figureDesign))
                .foregroundColor(tint)
            // Verbatim: this is a unit, not a word to be looked up, and a
            // localised percent sign arrives with the number it belongs to.
            Text(verbatim: "%")
                .font(.system(size: size,
                              weight: .regular,
                              design: Tokens.Ramp.figureDesign))
                .foregroundColor(Tokens.Ink.muted)
        }
    }

    // MARK: - Derived state

    private var rangeSpan: TimeInterval {
        range.upperBound.timeIntervalSince(range.lowerBound)
    }

    /// When the bucket under the pointer is, taken off the rail so every figure
    /// on the readout line is stamped with one time rather than with its own.
    private var hoveredStamp: String? {
        guard let rail, let slot = slot(in: rail) else { return nil }
        return Self.stamp(for: rail.points[slot].at, span: rangeSpan)
    }

    // MARK: - Copy

    /// A time label at the resolution the window deserves: a clock time inside
    /// two days, a date beyond it. Formatted rather than interpolated, so the
    /// order of the parts is the reader's and not this file's.
    static func stamp(for date: Date, span: TimeInterval) -> String {
        span <= clockSpan
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// What VoiceOver reads off one line. The shape of a curve cannot be spoken,
    /// so the two numbers anyone would read off it are.
    static func summary(of entry: HistoryChartSeries) -> String {
        guard let last = entry.points.last else { return "No history" }
        let peak = entry.points.map(\.percent).max() ?? last.percent
        return "latest \(percentSpoken(last.percent)) percent, peak \(percentSpoken(peak)) percent"
    }

    private static func percentSpoken(_ ratio: Double) -> String {
        let value = (ratio.isFinite ? min(max(ratio, 0), 1) : 0) * 100
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    // MARK: - Shapes

    /// The line through a series' samples, in the chart's own coordinates.
    ///
    /// The points arrive already placed, so `path(in:)` ignores the rect it is
    /// handed: this shape fills the whole plot layer, and the arithmetic that
    /// decides where a sample goes lives in `HistoryChartLayout` where it can be
    /// tested. A shape that re-derived positions from its own frame would be a
    /// second copy of that arithmetic, free to disagree with the dots drawn over
    /// it.
    private struct Polyline: Shape {
        let points: [CGPoint]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard points.count > 1, let first = points.first else { return path }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
    }
}
