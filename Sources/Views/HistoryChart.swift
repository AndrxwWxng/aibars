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
/// The colour arrives from the caller rather than being derived here, and under
/// the app's one colour rule — chroma means measurement or state, identity is
/// drawn in ink — what arrives is a reading and not a badge: the caller hands
/// over the usage ramp's tint for this window, or, where the user has opted into
/// provider colour, that provider's banded ink. Either way the hue on this plot
/// belongs to the trace. Nothing else in the chart may carry any: the grid, the
/// two reference rules, the axis, the stamps and every figure are neutral, so
/// the one coloured thing on the plot is the line being read.
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
/// Four rules the chart is held to, every one of them the app's rather than this
/// view's. Every number in here is SF Mono inside a reserved rail — the axis
/// gutter, the threshold label and the hover readout are three fixed columns, and
/// nothing mono is set outside one; the legend, the series names and the time
/// stamps are prose and are SF Pro with tabular digits. Nothing in here is
/// translucent: the plot is an opaque well, because a contrast ratio measured
/// against a named ground is a statement and the same ink over a material with
/// someone's wallpaper behind it is a hope. The trace is the only thing on the
/// plot allowed a hue, because chroma means measurement and everything else here
/// is frame. And there are two weights: a reading, and everything that labels
/// one, a step lighter — a reading at or over the warning threshold takes the
/// third, which is the panel's own way of saying near-cap without saying it in
/// colour alone.
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

    /// Read for the same reason, and used for every line on the plot: a grid is
    /// nine hairlines, and a hairline whose position falls between two device
    /// pixels is resampled across both at half strength. That is what turns four
    /// quarter lines into grey fog and it is why the grid used to read as
    /// hatching. Every rule in here is snapped through `Tokens.Control.snap`.
    @Environment(\.displayScale) private var displayScale

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
    /// The ground the hover dot is ringed with, so it clears the trace and the
    /// rule it is always sitting on. One point: half of it and the ring is a
    /// resampled smudge, twice it and the dot is a badge.
    private static let dotRing: CGFloat = 1
    /// The ink both reference rules take — the threshold and the pointer.
    ///
    /// `notchColour(increased:)` used to answer this, then `Tokens.Ink.muted`
    /// did. Neither of these marks may take a colour: hue on this plot names a
    /// service, so a rule carrying one reads as one more service. But `muted` is
    /// an *ink* — the rung captions are set at, 6.21:1 light and 8.29:1 dark on
    /// the well these are drawn on — and a rule at caption strength was only ever
    /// survivable because the trace beside it carried a hue. It no longer does
    /// below caution: the usage ramp's resting stop is `Ink.muted` now, so a
    /// resting trace and these two rules were about to be the same grey at the
    /// same weight. A reference line drawn as loudly as the reading it is a
    /// reference for is the plot arguing with itself.
    ///
    /// So it is furniture now, at the panel's own rule opacity, which puts every
    /// rule in the application on one accessor. On `Surface.well` it resolves to
    /// `#DADBDF` light and `#151618` dark — 1.170:1 and 1.132:1 — stepping to
    /// `#C5C6CA` / `#2B2C2F` (1.443 / 1.468) under increased contrast. That is
    /// quieter than the gridlines, which are `Meter.track` at 1.242 / 1.532, and
    /// deliberately so: the grid is the plot's ruling and these two are marks on
    /// it. What tells them apart is not weight but shape — the threshold rule is
    /// dashed 3-on-3-off and the pointer rule is the only vertical line in the
    /// well — and `ruleWidth` below doubles both on a display that is losing
    /// hairlines, which is the case where a difference in opacity would not have
    /// helped anyway.
    ///
    /// An instance property rather than a `static let`, because it reads the
    /// environment now: an opacity that steps under increased contrast cannot be
    /// resolved once at type level.
    private var ruleInk: Color {
        Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased))
    }
    /// A rule's width, stepped up under increased contrast, because colour alone
    /// cannot rescue a hairline on a display that is losing hairlines.
    private var ruleWidth: CGFloat {
        contrast == .increased ? 2 : Tokens.Control.hairline
    }

    /// A line's centre moved so that the line itself lands on whole pixels.
    ///
    /// The edge is what has to be snapped, not the centre: a `Rectangle` is
    /// filled from its edges outward, so snapping the middle of a one-point line
    /// puts both edges on half pixels — the blur this is meant to remove. The
    /// thickness stays a point rather than dropping to `Control.hair`: the grid
    /// is drawn in `Meter.track`, which is the quietest ink in the app on the
    /// quietest ground in it, and halving the line would halve what is already
    /// only just a line.
    private func snapped(_ centre: CGFloat, thickness: CGFloat) -> CGFloat {
        Tokens.Control.snap(centre - thickness / 2, scale: displayScale) + thickness / 2
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
        // The stroked panel that used to be around all of this is gone, and the
        // palette's own rule is why: a well is a recess and `raised` is the one
        // plane that takes a border. What was drawn was two concentric rounded
        // rectangles — a 10pt stroked box holding a 6pt filled well twelve points
        // inside it — for one object, which is the surest sign of a chart
        // assembled out of parts. One recess, no edge. What is left is vertical
        // air, so the legend does not sit on the picker above it and the grain
        // note does not sit on the plot; the horizontal margin is the form row's,
        // which is also what puts the axis rail on the same left edge as the
        // labels of the controls above it.
        .padding(.vertical, Tokens.Space.small)
    }

    private var plot: some View {
        GeometryReader { geo in
            let rect = Self.plotRect(in: geo.size)
            // Two layers: the plot, cut to its own recess, and the axis, which is
            // the frame around it rather than anything in it and is drawn in the
            // gutter and the strip where no clip reaches.
            ZStack(alignment: .topLeading) {
                plotLayer(in: rect)
                axisFigures(in: rect)
                timeLabels(in: rect)
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

    // MARK: - The plot's ground and grid

    /// The plot: its ground, its grid, its two reference rules and the traces, all
    /// cut to the recess they belong to.
    ///
    /// The plot is one of the three wells the palette names, and it is opaque. The
    /// panel's own material is the only translucency in the application, and this
    /// chart carries numbers: an axis figure and a readout have to sit on a ground
    /// whose contrast can be measured rather than on one that borrows whatever
    /// wallpaper is behind the window. It takes no border either — a well is a
    /// recess and `raised` is the one plane in the palette that has an edge.
    ///
    /// Everything in here runs to the plot's edges, and the corners curve away from
    /// them, so unclipped it all leaked: the 0% and 100% gridlines left four grey
    /// whiskers past the recess, a trace at the cap ran six points out over the
    /// corner on the ground outside, and the hover rule did the same at the first
    /// and last bucket. One clip for the lot, including the markers — a marker
    /// carries a ring of the ground and a ring that escaped the recess would be a
    /// pale blob on the pane. A reading at 0% is cut by the same edge that cuts its
    /// own trace's vertex, which is the only way the two can agree.
    private func plotLayer(in rect: CGRect) -> some View {
        let shape = WellShape(rect: rect, radius: Tokens.Radius.chip)
        return ZStack(alignment: .topLeading) {
            shape.fill(Tokens.Surface.well)
            gridlines(in: rect)

            if plotted.isEmpty {
                emptyState(in: rect)
            } else {
                thresholdRule(in: rect)
                lines(in: rect)
                hoverRule(in: rect)
                markers(in: rect)
            }
        }
        .clipShape(shape)
    }

    private func gridlines(in rect: CGRect) -> some View {
        let thickness = Tokens.Control.hairline
        return ForEach(Self.gridStops, id: \.self) { stop in
            Rectangle()
                .fill(Tokens.Meter.track)
                .frame(width: rect.width, height: thickness)
                .position(x: rect.midX, y: gridY(for: stop, in: rect, thickness: thickness))
        }
    }

    /// Where a gridline goes: on the pixel grid, and wholly inside the well.
    ///
    /// The 0% and 100% stops are the plot's own edges. Drawn on their exact y,
    /// half of each line hangs outside the well and is cut by its rounded corners,
    /// so the two lines that frame the plot are the two that look frayed. They are
    /// pulled in by half their own thickness — the only place the grid is not
    /// mathematically on its stop, and half a point is not a reading anybody takes
    /// off a gridline.
    private func gridY(for stop: Double, in rect: CGRect, thickness: CGFloat) -> CGFloat {
        let y = HistoryChartLayout.y(for: stop, in: rect)
        let inset = min(max(y, rect.minY + thickness / 2), rect.maxY - thickness / 2)
        return snapped(inset, thickness: thickness)
    }

    /// The panel's warning level, as a reference.
    ///
    /// Dashed, and drawn in the neutral ink rather than in the ramp's red. Red is
    /// the ramp's, and the ramp is what the trace is drawn in: a red rule across
    /// this plot would read as a second trace sitting at a constant 85%. A mark on
    /// the frame takes the frame's ink, and what says this rule is not a gridline
    /// is that it is dashed, a point heavier, and labelled.
    private func thresholdRule(in rect: CGRect) -> some View {
        let y = snapped(HistoryChartLayout.y(for: warningThreshold, in: rect), thickness: ruleWidth)
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
                ruleInk,
                style: StrokeStyle(lineWidth: ruleWidth, dash: [3, 3])
            )

            figure(
                warningThreshold,
                size: Tokens.Ramp.caption,
                tint: Tokens.Ink.muted,
                weight: .regular
            )
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
            // A one-bucket series has no line in it and is drawn as the dot it is —
            // in `markers(in:)`, with the pointer's dots, because both are one
            // reading drawn as a point and a clip must not bite either. The shape
            // here still carries the series' voice: it is the accessibility element
            // for the line whether or not there is a path in it.
            .accessibilityElement()
            .accessibilityLabel(entry.title)
            .accessibilityValue(Self.summary(of: entry))
        }
    }

    // MARK: - Markers

    /// Every sample this chart draws as a point rather than as part of a line: the
    /// single reading a one-bucket series is, and whatever the pointer is over.
    ///
    /// Drawn last, so a marker is over its own trace, over the hover rule and over
    /// the threshold — it is the answer to the question the pointer asked and
    /// nothing on the plot may cross it.
    @ViewBuilder
    private func markers(in rect: CGRect) -> some View {
        ForEach(plotted) { entry in
            if entry.points.count == 1, let only = entry.points.first {
                marker(entry.colour, at: HistoryChartLayout.point(for: only, in: rect, range: range))
            }
            if let sample = self.sample(in: entry) {
                marker(entry.colour, at: HistoryChartLayout.point(for: sample, in: rect, range: range))
            }
        }
    }

    /// One sample, as a point.
    ///
    /// Ringed in the plot's own ground, so the marker reads where it is always
    /// drawn: on the crossing of its own trace and the hover rule. Without the ring
    /// a 5pt dot in the trace's colour sitting on the trace is a thickening of the
    /// line rather than a point on it. The ground rather than an ink, because the
    /// ring separates the dot from what is under it and is not a mark of its own.
    private func marker(_ colour: Color, at point: CGPoint) -> some View {
        Circle()
            .fill(colour)
            .frame(width: Self.dotRadius * 2, height: Self.dotRadius * 2)
            .padding(Self.dotRing)
            .background(Circle().fill(Tokens.Surface.well))
            .position(point)
    }

    // MARK: - Hover

    /// The rule under the pointer, on the bucket the readout is reading.
    ///
    /// Nothing is drawn when the pointer is off the plot, and nothing reserves
    /// space for it: the readout line above already holds its height with the
    /// legend, so the pane cannot resize under the pointer that summoned it.
    @ViewBuilder
    private func hoverRule(in rect: CGRect) -> some View {
        if let rail, let slot = self.slot(in: rail) {
            let x = HistoryChartLayout.point(
                for: rail.points[slot], in: rect, range: range
            ).x

            Rectangle()
                // The same mark as the threshold rule, stepped up the same way:
                // this is the line the reading on the readout belongs to, and a
                // vertical hairline over a well is the frailest thing here. Snapped
                // like every other line on the plot — this one moves with the
                // pointer, so it is the one that would smear at every second
                // bucket.
                .fill(ruleInk)
                .frame(width: ruleWidth, height: rect.height)
                .position(x: snapped(x, thickness: ruleWidth), y: rect.midY)
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
                    //
                    // `.regular`, and written down rather than inherited: this is
                    // the label on the reading beside it, and the panel's two
                    // weights are a reading at `titleWeight` and everything that
                    // annotates one a step lighter. It used to be set at the same
                    // weight as the figure, which left the line with two subjects.
                    .font(.system(size: Tokens.Ramp.detail, weight: .regular))
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
    ///
    /// The digits are `Ink.body` and never the trace's colour, which is a defect
    /// as much as a rule: the colour handed over is the tint of the *window* —
    /// the ramp read off its highest bucket — so hovering a quiet 2% bucket on a
    /// window that peaked at 99% printed `2.0%` in warning red. A figure and the
    /// measurement beside it may not disagree. What the reading carries instead is
    /// the panel's own signal: `alertWeight` at or above the warning threshold,
    /// which is a channel that survives being read by someone who cannot see the
    /// difference between the ramp's two ends. The identity the tint used to carry
    /// moves to the key beside it, which is the same mark the legend uses.
    @ViewBuilder
    private func hoveredFigure(for entry: HistoryChartSeries) -> some View {
        if let sample = sample(in: entry) {
            HStack(spacing: Tokens.Space.snug) {
                seriesKey(for: entry)
                figure(
                    sample.percent,
                    size: Tokens.Ramp.title,
                    tint: Tokens.Ink.body,
                    weight: sample.percent >= warningThreshold
                        ? Tokens.Ramp.alertWeight
                        : Tokens.Ramp.titleWeight,
                    fractionDigits: 1
                )
                // Reserved, not measured: "9.4%" and "100.0%" must not walk the
                // neighbouring service's figure sideways as the pointer moves.
                .frame(width: Self.readoutWidth, alignment: .trailing)
            }
        }
    }

    /// The one mark that says which line a run belongs to: a stub of the line
    /// itself, at the line's own width. Drawn by the legend and by the readout, so
    /// a reading is tied to its trace by the same shape in both states rather than
    /// by a colour in one of them.
    private func seriesKey(for entry: HistoryChartSeries) -> some View {
        Capsule(style: Tokens.Radius.style)
            .fill(entry.colour)
            .frame(width: Tokens.Space.medium, height: Self.lineWidth)
    }

    private func legendKey(for entry: HistoryChartSeries) -> some View {
        HStack(spacing: Tokens.Space.snug) {
            seriesKey(for: entry)
            // A series name is a word, so SF Pro: the legend names lines and
            // carries no reading, so it is set at `.regular` beside a reading's
            // `titleWeight`.
            Text(entry.title)
                .font(.system(size: Tokens.Ramp.detail, weight: .regular))
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
    ///
    /// Set at `.regular` and centred on the gridline it names. An axis stop is a
    /// label on the frame, and the frame being a weight lighter than the reading is
    /// what leaves the readout as the heaviest run on the chart — the whole of the
    /// hierarchy here, since every one of these is the same size and the same ink.
    private func axisFigures(in rect: CGRect) -> some View {
        ForEach(Self.labelledStops, id: \.self) { stop in
            figure(stop, size: Tokens.Ramp.caption, tint: Tokens.Ink.muted, weight: .regular)
                .fixedSize()
                .frame(width: Self.axisFigureWidth, alignment: .trailing)
                .position(x: Self.axisFigureWidth / 2,
                          y: gridY(for: stop, in: rect, thickness: Tokens.Control.hairline))
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
            .font(.system(size: Tokens.Ramp.caption, weight: .regular))
            .monospacedDigit()
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
    }

    /// Said in the plot rather than instead of it. The grid and the axis stay
    /// drawn, so an empty window reads as a window with nothing in it — which is
    /// not the same as a service sitting at zero, and must not be drawn as one.
    private func emptyState(in rect: CGRect) -> some View {
        Text("No history yet")
            .font(.system(size: Tokens.Ramp.title, weight: .regular))
            .foregroundColor(Tokens.Ink.muted)
            // The plot's centre is also where the 50% gridline is, so the sentence
            // was being struck through by it. It carries the ground with it and the
            // grid passes behind, which is the same trick every axis label in a
            // chart uses and cheaper than moving the sentence off centre.
            .padding(.horizontal, Tokens.Space.small)
            .background(Tokens.Surface.well)
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
    ///
    /// The weight is the caller's, and it is the panel's two-weight rule reaching
    /// the chart: a reading is set at `titleWeight`, a reading at or over the
    /// warning threshold at `alertWeight`, and a figure that labels the frame — the
    /// axis stops, the threshold's own value — at `.regular`, because it is a label
    /// and not a reading. Mono advances do not move with weight, so nothing set in
    /// a reserved rail changes width when the weight changes.
    private func figure(
        _ ratio: Double,
        size: CGFloat,
        tint: Color,
        weight: Font.Weight = Tokens.Ramp.titleWeight,
        fractionDigits: Int = 0
    ) -> some View {
        let value = (ratio.isFinite ? min(max(ratio, 0), 1) : 0) * 100
        return HStack(spacing: 0) {
            Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                .font(.system(size: size,
                              weight: weight,
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

    /// The plot's recess, in the chart's own coordinates.
    ///
    /// Ignores the rect it is handed, for the same reason `Polyline` does: this
    /// shape is placed over the whole chart while the plot is a region inside it,
    /// so the geometry comes from `plotRect(in:)` rather than from whatever frame
    /// the layout gave the shape. One definition, both filled with and clipped to,
    /// so the ground and the edge the grid is cut against cannot disagree.
    private struct WellShape: Shape {
        let rect: CGRect
        let radius: CGFloat

        func path(in _: CGRect) -> Path {
            Path(roundedRect: rect, cornerRadius: radius, style: Tokens.Radius.style)
        }
    }

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
