import SwiftUI

// ---------------------------------------------------------------------------
// What this file needs from the model behind it, written down because it is the
// only contract between them and nothing here may widen it.
//
// `RowSparklineStore` (@MainActor, `shared`, deliberately not observable):
//     func series(for providerID: String) -> RowSparklineStore.Series?
//         peaks: [Double?]   oldest first, one per hour, nil for an empty hour
//         takenAt: Date      unread here
//
// `HistoryQuery.resetDrop` — the fall that means a window rolled over.
//
// Which store the buckets came from, over what window and at what resolution
// are the store's. This decides where the ink goes and what is said about it.
// ---------------------------------------------------------------------------

/// Where the trace goes.
///
/// Separated from the view for the reason `HistoryChartLayout` is: every mark
/// the sparkline makes comes out of these two functions, so a test that pins
/// them pins the picture without hosting anything.
public enum SparklineLayout {

    /// The trace, cut into the runs it is actually drawn as.
    ///
    /// A run is a maximal stretch of consecutive buckets that carry a reading
    /// **and** do not step down across a window boundary. Two things cut it, and
    /// they are different facts:
    ///
    /// 1. **A gap.** A bucket nothing landed in is `nil`, never 0 — the rule the
    ///    store keeps and the reason it keeps it: a Mac that was asleep did not
    ///    spend a quiet night at the floor. Joining across the gap would draw
    ///    exactly that night.
    /// 2. **A reset.** A window rolling over drops the reading to near zero
    ///    between two adjacent hours. Joined, that is a vertical plunge through
    ///    the whole box — which reads as the app having crashed and lost the
    ///    data, not as a subscription renewing. Cut at `HistoryQuery.resetDrop`,
    ///    the same 0.30 the history chart splits its own line on, so the panel
    ///    and the settings window agree about where a window began.
    ///
    /// Indices into the array handed in, so the caller can place them on its own
    /// rail without a second copy of the arithmetic.
    public static func runs(_ peaks: [Double?], resetDrop: Double = HistoryQuery.resetDrop) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        var previous: Double?
        for (index, peak) in peaks.enumerated() {
            guard let peak, peak.isFinite else {
                if !current.isEmpty { runs.append(current); current = [] }
                previous = nil
                continue
            }
            // A drop of zero or less would ask for a cut at every hour that did
            // not rise, which is nobody's intent; it is read as "do not cut".
            if let previous, resetDrop > 0, previous - peak >= resetDrop {
                runs.append(current)
                current = []
            }
            current.append(index)
            previous = peak
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Where one bucket lands.
    ///
    /// The rail is divided by `count - 1`, so the first bucket sits on the
    /// leading edge and the last on the trailing one — the same division
    /// `HistoryChartLayout` uses, and for the same reason: the newest hour is the
    /// one the eye goes to, and a trace that stopped 13pt short of the row's own
    /// text edge would be the only thing in the panel that did.
    ///
    /// The y is a **fixed 0…1 axis** and is never scaled to the series' own
    /// maximum. This is the single most important line in the file: a trace
    /// normalised to its own peak draws a day that never went past 4% exactly
    /// like a day pinned at the cap, which turns the one drawing on the row that
    /// could report a shape into a drawing that reports nothing at all. The bar
    /// above it is on this axis; so is this.
    ///
    /// A one-bucket series owns the whole rail and is placed at its centre — the
    /// leading edge would read as a trace that has been truncated.
    public static func point(bucket: Int, of count: Int, peak: Double, in rect: CGRect) -> CGPoint {
        guard count > 1 else { return CGPoint(x: rect.midX, y: y(peak, in: rect)) }
        let slot = min(max(bucket, 0), count - 1)
        return CGPoint(
            x: rect.minX + rect.width * CGFloat(slot) / CGFloat(count - 1),
            y: y(peak, in: rect)
        )
    }

    /// The y of a 0...1 reading, flipped and clamped. An overage a provider
    /// reports is drawn at the cap rather than above the box, exactly as the
    /// chart does it; a non-finite reading answers the floor rather than
    /// surviving into a `Path`, which would take the whole row's layout with it.
    static func y(_ ratio: Double, in rect: CGRect) -> CGFloat {
        guard ratio.isFinite else { return rect.maxY }
        // Inset by half the stroke at each end so a reading of 0 and a reading of
        // 1 are drawn wholly inside the box rather than half outside it. Half a
        // point is not a reading anybody takes off a sparkline, and a clipped cap
        // is.
        let inset = Tokens.Control.sparklineStroke / 2
        let floor = rect.maxY - inset
        let ceiling = rect.minY + inset
        guard floor > ceiling else { return rect.midY }
        return floor - (floor - ceiling) * CGFloat(min(max(ratio, 0), 1))
    }
}

/// A row's last twenty-four hours, as one trace under its meter.
///
/// It is context and not a reading, and every decision here follows from that.
///
/// **One neutral ink, never the ramp.** The row already has exactly one thing
/// entitled to a colour — the bar, or the figure in the rail — and a second
/// coloured mark under it would be the panel spending its whole colour budget on
/// the least urgent object on the row. `Ink.muted` is the ink everything that is
/// context takes; the app has two hues, amber and red, both of them alarm, and
/// neither is available to a drawing about yesterday.
///
/// **Nothing at all when there is nothing to say.** No baseline rule, no dashed
/// placeholder, no "no history yet". A full-width horizontal hairline between a
/// caption and the next row is precisely the drawing `Tokens.Meter.hairline` was
/// deleted for: it appeared in four unrelated situations, distinguished none of
/// them, and read as a table rule in all of them. The slot keeps its height, so
/// no row moves; it simply holds nothing, which is what the meter slot does on a
/// row with no quota.
///
/// **No axis, no threshold rule, no fill under the curve.** All three were
/// considered and all three are the chart's furniture, on a chart the user went
/// looking for. This is 18pt tall on a row that is being glanced at.
public struct RowSparkline: View {
    /// Oldest first. Exactly `RowSparklineStore.buckets` long in the app; any
    /// length draws, because a test hands three.
    public let peaks: [Double?]
    public let height: CGFloat

    public init(peaks: [Double?], height: CGFloat) {
        self.peaks = peaks
        self.height = height
    }

    /// What the Appearance pane's sample row draws.
    ///
    /// A fixed series and not a random one, and not the real store either: the
    /// preview's job is to show what the setting does, and a preview that drew a
    /// blank box on a machine with no history yet would be indistinguishable from
    /// the setting being broken. It carries a gap at hours 6–8 and a reset
    /// between 15 and 16, because those are the two cases the drawing exists to
    /// handle and the pane is where a user finds out that it does.
    public static let sample: [Double?] = [
        0.04, 0.07, 0.09, 0.14, 0.18, 0.21, nil, nil, nil,
        0.34, 0.38, 0.45, 0.51, 0.58, 0.66, 0.71,
        0.05, 0.09, 0.16, 0.24, 0.31, 0.37, 0.42, 0.48
    ]

    public var body: some View {
        Trace(peaks: peaks)
            .stroke(
                Tokens.Ink.muted,
                style: StrokeStyle(
                    lineWidth: Tokens.Control.sparklineStroke,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            // Fixed, and equal to `Metrics.sparklineHeight` by construction: the
            // caller passes the same number `RowGeometry` reserved.
            .frame(height: height)
            // `maxWidth` and never `fixedSize`. This is the one thing on the row
            // that cannot widen the panel — the failure `SecondaryChipRun` has and
            // pays for with a truncated caption.
            //
            // `idealWidth: 0` is what makes that true, and it is measured rather
            // than assumed: SwiftUI gives a bare `Shape` a default ideal of 10×10,
            // so `maxWidth: .infinity` alone reports a 10pt ideal width and the row
            // acquires a 10pt floor it never asked for. Small, but it is a floor
            // that grows with nothing and shrinks with nothing, which is exactly
            // the kind of term the width contract exists to keep out. Stated at
            // zero, the trace asks for no width at all and takes whatever the text
            // column has left.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
            // The trace is a shape and says nothing on its own, so it is made an
            // element and given the two numbers anyone would read off it. An
            // all-empty trace draws nothing and therefore says nothing: an element
            // announcing "no readings" on every row of a fresh install is fifteen
            // sentences reporting the age of the app.
            .modifier(Spoken(value: Self.spoken(peaks)))
            // The width of a bucket is the resolution, and it is the one fact
            // about this drawing that cannot be read off it.
            .help("The last 24 hours, one point an hour, at the highest reading in it")
    }

    /// What VoiceOver reads off the trace, or nil when nothing is drawn.
    ///
    /// The shape of a curve cannot be spoken, so the three facts anyone would
    /// take off it are: where it ended, how high it got, and how much of the day
    /// is missing — that last one because a trace with eighteen empty hours in it
    /// is a claim about the Mac being asleep and not about the subscription, and a
    /// reader who cannot see the gaps has no other way to know.
    ///
    /// Static and pure so the copy can be asserted without hosting a view, which
    /// is the same arrangement `ForecastLine.text` and
    /// `MenuBarStripContent.accessibilityLabel` are in.
    public static func spoken(_ peaks: [Double?]) -> String? {
        let readings = peaks.compactMap { $0 }.filter(\.isFinite)
        guard let last = readings.last, let peak = readings.max() else { return nil }
        let missing = peaks.count - readings.count
        var sentence = readings.count == 1
            ? "one reading in the last 24 hours, \(percent(last)) percent"
            : "last 24 hours, latest \(percent(last)) percent, peak \(percent(peak)) percent"
        if missing > 0 {
            sentence += missing == 1
                ? ", 1 hour with no reading"
                : ", \(missing) hours with no reading"
        }
        return sentence
    }

    private static func percent(_ ratio: Double) -> String {
        let value = (ratio.isFinite ? min(max(ratio, 0), 1) : 0) * 100
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    /// An element with a value, or nothing said at all. A `ViewModifier` rather
    /// than a `@ViewBuilder` branch so the two cases are the same view with the
    /// same frame, which is what keeps the reserved height honest.
    private struct Spoken: ViewModifier {
        let value: String?

        @ViewBuilder
        func body(content: Content) -> some View {
            if let value {
                content
                    .accessibilityElement()
                    .accessibilityLabel("Usage over the last 24 hours")
                    .accessibilityValue(value)
            } else {
                content.accessibilityHidden(true)
            }
        }
    }

    /// The trace, in the box the layout gave it.
    ///
    /// Unlike `HistoryChart.Polyline` this shape *does* use the rect it is
    /// handed, and that is the difference between the two: the chart's points are
    /// placed against a plot area carved out of a larger view, where this one owns
    /// its whole frame. The arithmetic still lives in `SparklineLayout` so a test
    /// can pin it.
    ///
    /// Each run is its own subpath. A run of one bucket is a dot rather than a
    /// zero-length line, because a zero-length stroke with a round cap renders as
    /// a dot on some scales and as nothing on others — and an hour that is the
    /// only reading either side of two gaps is the one the reader most needs to
    /// see.
    private struct Trace: Shape {
        let peaks: [Double?]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard rect.width > 0, rect.height > 0, !peaks.isEmpty else { return path }
            let count = peaks.count
            let radius = Tokens.Control.sparklineDot / 2

            for run in SparklineLayout.runs(peaks) {
                let points = run.compactMap { index -> CGPoint? in
                    guard let peak = peaks[index] else { return nil }
                    return SparklineLayout.point(bucket: index, of: count, peak: peak, in: rect)
                }
                guard let first = points.first else { continue }
                if points.count == 1 {
                    path.addEllipse(in: CGRect(
                        x: first.x - radius, y: first.y - radius,
                        width: radius * 2, height: radius * 2
                    ))
                    continue
                }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            return path
        }
    }
}
