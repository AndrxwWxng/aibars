import XCTest
import SwiftUI
import AppKit
import SQLite3
@testable import aibarsCore

/// The History pane is two things bolted together, and they are tested two ways.
///
/// `HistoryRange` is pure — four spans, their grain, their bucket count and the
/// interval each one produces — so it is asserted directly, including at the
/// clocks and calendars nobody types in by hand: the epoch, a distant past, a
/// distant future, and the twenty-three-hour day a spring-forward makes.
///
/// The view around it is measured the way `AlertsPaneTests` measures its own:
/// by counting the AppKit controls SwiftUI actually instantiated and by the
/// size the form reports — its height for what it drew, and its width for the
/// figure rail, which is the one thing in the pane that must not move. A Form
/// nested in a hosting view snapshots blank in this harness whether or not it
/// built anything, so pixels prove nothing.
///
/// Two things nothing here is allowed to touch. `UsageHistoryStore.shared` opens
/// the real history in Application Support, so every store below is built on a
/// scratch directory and a scratch defaults domain — which is also why
/// `HistoryPane()` with no argument is never called: its whole job is to reach
/// for `shared`. And `AppState.shared` is only ever read, never signed in or out
/// of; the pane asks it for display names and gets nothing back, which is the
/// state a history that outlived a sign-out is in anyway.
final class HistoryPaneTests: XCTestCase {

    // MARK: - Harness

    private var directory = FileManager.default.temporaryDirectory

    /// Real wall-clock now, taken once. The pane builds its own interval from
    /// `Date()` at render time, so a seeded reading has to sit near the actual
    /// present or it falls outside the window the pane is looking at.
    private var anchor = Date()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-pane-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        anchor = Date()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A directory of its own per store. Two stores in one folder are two
    /// handles on one file, and a test that compared an "empty" store with a
    /// stocked one would be comparing a store with itself.
    private func folder() -> URL {
        directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A store on a scratch file, with a clock that does not run behind the
    /// seeding. `record` stamps a reading at `min(fetchedAt, now())`, so a store
    /// whose clock sat in the past would collapse every seeded reading onto one
    /// timestamp and the minimum-interval rule would then drop all but the first.
    @MainActor
    private func store(
        _ label: String = #function,
        in folder: URL? = nil,
        now: Date? = nil
    ) throws -> UsageHistoryStore {
        let name = "aibars.history.tests.\(label).\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let clock = now ?? anchor.addingTimeInterval(1)
        return try UsageHistoryStore(
            directory: folder ?? self.folder(),
            now: { clock },
            defaults: defaults
        )
    }

    @MainActor
    private func hosted<V: View>(_ view: V, height: CGFloat = 520) -> NSView {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 660, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return host
    }

    private func controls(in view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        if let control = view as? NSControl { found.append(control) }
        for subview in view.subviews { found.append(contentsOf: controls(in: subview)) }
        return found
    }

    /// The range picker. A `.segmented` Picker is one of the few things in a
    /// Form that AppKit still draws, which is what makes the pane's default
    /// span readable from out here at all — the buttons beside it are drawn by
    /// SwiftUI and never become `NSButton`s to ask.
    private func segments(in view: NSView) -> [NSSegmentedControl] {
        controls(in: view).compactMap { $0 as? NSSegmentedControl }
    }

    /// One provider's readings, `count` of them a minute apart ending at the
    /// anchor. A minute rather than the thirty seconds the store insists on, so
    /// a rounded stamp cannot put two readings inside the minimum interval and
    /// lose one.
    ///
    /// Every window named goes into one payload, which is how a sweep records
    /// them: the first is the primary and the rest are secondary, and each
    /// becomes a series of its own.
    @MainActor
    private func seed(
        _ store: UsageHistoryStore,
        provider: String,
        windows: [String],
        readings count: Int = 4
    ) {
        for step in 0..<count {
            let at = anchor.addingTimeInterval(-Double(count - step) * 60)
            let metrics = windows.enumerated().map { index, label in
                UsageMetric(
                    label: label,
                    used: Double((step + 1) * 10 + index),
                    limit: 100,
                    unit: "messages",
                    resetDate: at.addingTimeInterval(3600)
                )
            }
            guard let primary = metrics.first else { return }
            store.record(
                UsageData(
                    providerID: provider,
                    fetchedAt: at,
                    planName: "Max",
                    primary: primary,
                    secondary: Array(metrics.dropFirst())
                ),
                for: provider
            )
        }
    }

    /// `HistoryRange.Grain` carries no payload and declares no conformance, so
    /// it is matched rather than compared: a test should not be the reason a
    /// production type has to be Equatable.
    private func isReadings(_ grain: HistoryRange.Grain) -> Bool {
        if case .readings = grain { return true }
        return false
    }

    private func noon(
        _ year: Int, _ month: Int, _ day: Int,
        in calendar: Calendar
    ) throws -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 12
        return try XCTUnwrap(calendar.date(from: parts), "\(year)-\(month)-\(day) is not a date")
    }

    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        return calendar
    }

    // MARK: - The spans

    /// The four the segmented control offers, in the order it offers them, with
    /// the labels it prints. `week` is second, which is what the pane's default
    /// selection points at.
    func testTheRangeOffersFourSpansInOrder() {
        XCTAssertEqual(
            HistoryRange.allCases.map(\.title), ["24h", "7d", "30d", "90d"],
            "the range labels or their order moved"
        )
        XCTAssertEqual(HistoryRange.allCases.map(\.days), [1, 7, 30, 90])
        XCTAssertEqual(
            Set(HistoryRange.allCases.map(\.id)).count, HistoryRange.allCases.count,
            "two spans share an id, so ForEach would draw one of them twice"
        )
        // Raw values are what a stored selection would be filed under the day
        // this becomes a preference, and the round trip has to survive it.
        for span in HistoryRange.allCases {
            XCTAssertEqual(HistoryRange(rawValue: span.rawValue), span)
        }
        XCTAssertEqual(HistoryRange.week.title, "7d", "the pane's default span must read as a week")
    }

    /// The grain is derived from what the store actually keeps rather than
    /// decided per case, so this asserts the rule and not the four answers: a
    /// span longer than the readings survive cannot be drawn from readings.
    ///
    /// Which pins the boundary either side of the retention constant too — if
    /// `HistoryRetention.sample` moves, the case that changes grain has to move
    /// with it or this fails.
    func testGrainFollowsWhatTheStoreKeeps() {
        for span in HistoryRange.allCases {
            let seconds = Double(span.days) * 24 * 60 * 60
            XCTAssertEqual(
                isReadings(span.grain), seconds <= HistoryRetention.sample,
                "\(span.title) spans \(seconds)s against a \(HistoryRetention.sample)s retention "
                    + "and is drawn at the wrong grain"
            )
        }
        // The four the app ships with, stated outright, so a retention change
        // that silently turned every chart into daily peaks is visible here.
        XCTAssertTrue(isReadings(HistoryRange.day.grain))
        XCTAssertTrue(isReadings(HistoryRange.week.grain))
        XCTAssertFalse(isReadings(HistoryRange.month.grain))
        XCTAssertFalse(isReadings(HistoryRange.quarter.grain))
    }

    /// The bucket count divides an interval and indexes an array, so a zero or a
    /// negative one is a division by zero in the grain note and an empty rail in
    /// the chart. Total over every case, including the two that never ask for it.
    func testEveryBucketCountIsPositive() {
        for span in HistoryRange.allCases {
            XCTAssertGreaterThan(span.bucketCount, 0, "\(span.title) would divide by zero")
            let interval = span.interval(ending: anchor)
            let bucket = interval.duration / Double(span.bucketCount)
            XCTAssertTrue(bucket.isFinite && bucket > 0, "\(span.title) has no bucket width")
        }
    }

    /// A rolling twenty-four hours, on purpose: this is the range picked to see
    /// what has happened since this morning, and snapping it to midnight would
    /// leave it nearly empty at 00:05. It therefore must not depend on the
    /// calendar it is handed at all.
    func testTheDayRangeIsARollingTwentyFourHours() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var kathmandu = Calendar(identifier: .gregorian)
        // Three-quarters of an hour off the hour, which is where a day boundary
        // computed the wrong way shows itself.
        kathmandu.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu"))

        let interval = HistoryRange.day.interval(ending: now, calendar: try utcCalendar())
        XCTAssertEqual(interval.end, now)
        XCTAssertEqual(interval.start, now.addingTimeInterval(-24 * 60 * 60))
        XCTAssertEqual(
            interval, HistoryRange.day.interval(ending: now, calendar: kathmandu),
            "the rolling day is being snapped to somebody's midnight"
        )
    }

    /// The longer spans start at a midnight, because they are read as a table of
    /// days: a rolling 7×24h shows eight of them with the first and last at half
    /// height for no reason a reader can see.
    func testTheLongerRangesStartAtMidnightAndCountTodayIn() throws {
        let calendar = try utcCalendar()
        let now = Date(timeIntervalSince1970: 1_700_012_345)

        for span in [HistoryRange.week, .month, .quarter] {
            let interval = span.interval(ending: now, calendar: calendar)
            XCTAssertEqual(interval.end, now)
            XCTAssertEqual(
                calendar.startOfDay(for: interval.start), interval.start,
                "\(span.title) does not start at a midnight"
            )
            XCTAssertEqual(
                calendar.dateComponents(
                    [.day], from: interval.start, to: calendar.startOfDay(for: now)
                ).day,
                span.days - 1,
                "\(span.title) covers the wrong number of days, counting today"
            )
        }
    }

    /// A day that is not twenty-four hours long is the ordinary case twice a
    /// year, and it is what catches a span built by multiplying instead of by
    /// asking the calendar. Both transitions, in a zone that has them.
    func testTheRangesSurviveADaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        let transitions = [
            try noon(2024, 3, 10, in: calendar),   // the 23-hour day
            try noon(2024, 11, 3, in: calendar)    // the 25-hour day
        ]
        for now in transitions {
            for span in HistoryRange.allCases {
                let interval = span.interval(ending: now, calendar: calendar)
                XCTAssertGreaterThan(interval.duration, 0)
                if span == .day {
                    XCTAssertEqual(
                        interval.duration, 24 * 60 * 60, accuracy: 0.001,
                        "the rolling day changed length across a clock change"
                    )
                } else {
                    XCTAssertEqual(
                        calendar.startOfDay(for: interval.start), interval.start,
                        "\(span.title) lost its midnight across a clock change"
                    )
                    XCTAssertEqual(
                        calendar.dateComponents(
                            [.day], from: interval.start, to: calendar.startOfDay(for: now)
                        ).day,
                        span.days - 1,
                        "\(span.title) lost or gained a day across a clock change"
                    )
                }
            }
        }
    }

    /// `DateInterval` traps outright when its end precedes its start, so the one
    /// thing every clock has to produce is an interval that is not backwards.
    /// These are the dates a machine actually hands over: the epoch, a clock
    /// nobody set, and the two ends of `Date` itself.
    func testNoClockProducesABackwardsInterval() throws {
        let calendar = try utcCalendar()
        let clocks: [(String, Date)] = [
            ("epoch", Date(timeIntervalSince1970: 0)),
            ("before the epoch", Date(timeIntervalSince1970: -1_000_000_000)),
            ("reference date", Date(timeIntervalSinceReferenceDate: 0)),
            ("distant past", .distantPast),
            ("distant future", .distantFuture),
            ("now", anchor)
        ]
        for (name, now) in clocks {
            for span in HistoryRange.allCases {
                let interval = span.interval(ending: now, calendar: calendar)
                XCTAssertLessThanOrEqual(
                    interval.start, interval.end,
                    "\(span.title) at the \(name) produced a backwards interval"
                )
                XCTAssertTrue(
                    interval.duration.isFinite && interval.duration >= 0,
                    "\(span.title) at the \(name) has a duration of \(interval.duration)"
                )
            }
        }
    }

    // MARK: - The pane builds

    /// Nothing recorded is the state every fresh install opens this pane in, and
    /// it still has to be a form with the recording switch in it rather than a
    /// blank sheet.
    @MainActor
    func testThePaneBuildsWithAnEmptyStore() throws {
        let store = try store()
        XCTAssertTrue(store.series().isEmpty, "a scratch store is not empty")

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the empty store collapsed the pane")
        XCTAssertGreaterThanOrEqual(
            controls(in: host).count, 1,
            "the recording switch is not being built when there is nothing to show"
        )
    }

    /// Three series over two providers: a service with two windows and a service
    /// with one, which is the shape the panel is usually in.
    @MainActor
    func testThePaneBuildsWithThreeSeriesAcrossTwoProviders() throws {
        let store = try store()
        seed(store, provider: "claude", windows: ["5-hour messages", "Weekly limit"])
        seed(store, provider: "gemini", windows: ["Daily prompts"])

        let series = store.series()
        XCTAssertEqual(series.count, 3, "two providers with three windows must be three series")
        XCTAssertEqual(
            Set(series.map(\.providerID)), ["claude", "gemini"],
            "the series are not keyed by the account they came from"
        )

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the pane collapsed with history in it")
        XCTAssertGreaterThan(
            controls(in: host).count, 1,
            "a stocked store draws no more controls than an empty one — the pickers are missing"
        )
    }

    /// A pane with history in it is taller than the same pane with none: the
    /// chart, the pickers and the day table are all in the surplus. The control
    /// count alone cannot see the chart, which SwiftUI draws itself.
    @MainActor
    func testHistoryMakesThePaneTallerThanTheEmptyState() throws {
        let empty = try store("empty")
        let full = try store("full")
        seed(full, provider: "claude", windows: ["5-hour messages"])

        let bare = hosted(HistoryPane(store: empty))
        let stocked = hosted(HistoryPane(store: full))

        XCTAssertGreaterThan(
            stocked.fittingSize.height, bare.fittingSize.height,
            "the pane is \(stocked.fittingSize.height)pt with history against "
                + "\(bare.fittingSize.height)pt without — the chart and the table are not drawn"
        )
    }

    /// The pane opens on a week. Read off the segmented control rather than the
    /// private `@State` behind it, which is the only place the default is
    /// visible from outside.
    @MainActor
    func testTheRangePickerStartsOnSevenDays() throws {
        let store = try store()
        seed(store, provider: "claude", windows: ["5-hour messages"])
        let host = hosted(HistoryPane(store: store))

        let ranges = segments(in: host).filter { $0.segmentCount == HistoryRange.allCases.count }
        XCTAssertFalse(
            ranges.isEmpty,
            "no four-segment control was built, so the range picker is missing — or AppKit has "
                + "stopped drawing segmented pickers and this test can no longer see one"
        )
        for control in ranges {
            let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
            XCTAssertEqual(labels, HistoryRange.allCases.map(\.title), "the range picker's labels moved")
            XCTAssertEqual(
                control.label(forSegment: control.selectedSegment), HistoryRange.week.title,
                "the pane did not open on 7d"
            )
        }
    }

    /// Every span has something to draw over the same seeded fortnight, at
    /// whichever grain it asks for. The pane's own range is private state that
    /// cannot be set from out here, so this asserts against the two reads the
    /// pane makes — the bucketed readings and the day rollups — which is where a
    /// span that drew an empty chart would actually be empty.
    @MainActor
    func testEverySpanHasAChartToDraw() throws {
        let store = try store()
        // Fourteen days of readings, inside the fortnight the store keeps them
        // for, so both grains have a range that is genuinely covered.
        for dayOffset in stride(from: 13, through: 0, by: -1) {
            let at = anchor.addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60)
            store.record(
                UsageData(
                    providerID: "claude",
                    fetchedAt: at,
                    primary: UsageMetric(label: "5-hour messages", used: 40, limit: 100, unit: "messages")
                ),
                for: "claude"
            )
        }
        let series = try XCTUnwrap(store.series().first, "the seeding recorded nothing")

        // A minute past the newest reading, because a sample stamped exactly on
        // the end of the interval is one rounding away from falling out of the
        // last bucket, and this test is not about that edge.
        let end = anchor.addingTimeInterval(120)

        for span in HistoryRange.allCases {
            let interval = span.interval(ending: end)
            switch span.grain {
            case .readings:
                let peaks = HistoryQuery.buckets(
                    store.samples(for: series, since: interval.start),
                    from: interval.start,
                    to: interval.end,
                    count: span.bucketCount
                )
                XCTAssertEqual(peaks.count, span.bucketCount, "\(span.title) produced no rail")
                XCTAssertTrue(
                    peaks.contains(where: { $0 != nil }),
                    "\(span.title) bucketed a fortnight of readings into nothing"
                )
            case .dailyPeaks:
                XCTAssertFalse(
                    store.days(for: series, since: interval.start).isEmpty,
                    "\(span.title) has no daily rollups to draw"
                )
            }
        }
    }

    // MARK: - The figure rail

    /// The day table's figure columns are reserved, not measured, and this is the
    /// pane's half of that: the same table showing a one-, a two- and a
    /// three-digit reading reports the same width.
    ///
    /// Tabular figures fix the width of a digit and not the length of a string,
    /// so `5%` still reflows to `100%` and drags whatever sits beside it. A
    /// column that sized itself to its content would therefore step sideways
    /// every time a reading crossed 9% or 99%, and a table whose right edge moves
    /// while it is being read looks like it is being retyped. The column width
    /// itself is a private constant in the pane and cannot be reached from out
    /// here, so what is asserted is its consequence.
    ///
    /// Three stores rather than one restated: the pane reads its store as it
    /// renders, and there is no way to change a reading under a hosted view. They
    /// are seeded at the same instants with the same window, so the dates down
    /// the first column, the number of rows, and every word in the pane are
    /// identical between them — the digits are the only thing left varying. The
    /// pane's prose is safe to hold constant that way: the grain note, the
    /// footers and the retention sentence are written from the range and the
    /// store's own constants, never from a reading.
    ///
    /// Width and not height: a cell is held to one line, so a rail too narrow
    /// truncates rather than wrapping and the height would never show it.
    @MainActor
    func testTheFigureRailDoesNotMoveBetweenOneTwoAndThreeDigitReadings() throws {
        var measured: [(used: Double, width: CGFloat)] = []

        for used in [5.0, 50.0, 100.0] {
            let store = try store("digits-\(Int(used))")
            // Four readings a minute apart at one figure, so the peak and the
            // average print the same number of digits as each other and the
            // reading count prints the same 4 in all three panes. The reset
            // count is 0 against the 1 the store counts at the cap, which is one
            // digit either way.
            for step in 0..<4 {
                store.record(
                    UsageData(
                        providerID: "claude",
                        fetchedAt: anchor.addingTimeInterval(-Double(4 - step) * 60),
                        primary: UsageMetric(label: "5-hour messages", used: used, limit: 100)
                    ),
                    for: "claude"
                )
            }
            XCTAssertFalse(store.series().isEmpty, "\(Int(used))% of the cap recorded nothing")
            let host = hosted(HistoryPane(store: store))
            measured.append((used: used, width: host.fittingSize.width))
        }

        // Pulled out rather than mapped inside the message: a key path cannot
        // name a tuple element, and a closure inside a string interpolation is
        // a worse read than two lines.
        let widths = measured.map { $0.width }
        let levels = measured.map { $0.used }
        XCTAssertEqual(
            Set(widths).count, 1,
            "the pane measures \(widths) at \(levels) percent of the cap — a figure column "
                + "is sizing itself to its content, so the table's edge moves with the reading "
                + "in it"
        )
    }

    /// The other half, which reserving cannot supply on its own: the column has
    /// to be wide enough for what goes in it. A rail narrower than its string
    /// truncates, and a reserved rail truncates just as readily as a measured one.
    ///
    /// Stated through `Tokens.figureWidth` rather than read off the table, whose
    /// width is private, so what this pins is the arithmetic the design names for
    /// a history figure: three cells at `Ramp.title`, a hairline, and one cell at
    /// `Ramp.caption` for the unit. A table that reserves more than this has room
    /// to spare; one that reserves less has to answer to these strings.
    ///
    /// Measured at `Ramp.title` — the largest face any cell in the table is set
    /// in — and at `medium`, which is `Ramp.emphasisWeight`, the heavier of the
    /// two weights the columns use. A rail that fits a lighter face is not a rail
    /// that fits this one.
    func testTheReservedFigureRailHoldsEveryFigureTheTablePrints() {
        let rail = Tokens.figureWidth(Tokens.Ramp.title, digits: 3)
            + Tokens.Control.hairline
            + Tokens.figureWidth(Tokens.Ramp.caption, digits: 1)
        let font = NSFont.monospacedSystemFont(ofSize: Tokens.Ramp.title, weight: .medium)

        // A day recorded at the store's own floor is the most readings a column
        // can ever carry, and so the longest count it can ever print.
        let busiest = Int((24 * 60 * 60) / HistoryRetention.minimumInterval)
        let figures = ["0%", "5%", "50%", "100%", "0", "1", "31", "288", "\(busiest)"]
        for figure in figures {
            let drawn = (figure as NSString).size(withAttributes: [.font: font]).width
            XCTAssertGreaterThanOrEqual(
                rail, drawn,
                "\(figure) measures \(drawn)pt in a \(rail)pt column, so the table truncates it"
            )
        }
    }

    // MARK: - Recording switched off

    /// Off with nothing stored is the state that has to say so and offer the
    /// switch rather than draw an empty chart. The absence of the chart is
    /// measured through the controls: with no series there are no pickers, so
    /// there is no range control to find.
    @MainActor
    func testWithRecordingOffAndNothingStoredThePaneStillOffersTheSwitch() throws {
        let store = try store()
        store.isEnabled = false

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the pane collapsed with recording off")
        XCTAssertGreaterThanOrEqual(
            controls(in: host).count, 1,
            "recording is off and there is no switch to turn it back on"
        )
        XCTAssertTrue(
            segments(in: host).allSatisfy { $0.segmentCount != HistoryRange.allCases.count },
            "a range picker was drawn over a chart with nothing in it"
        )
    }

    /// The switch is the store's, and the store's is a preference. It has to
    /// write through to the domain the store was given and to nowhere else — a
    /// pane that reached `UserDefaults.standard` would be editing the settings
    /// of whoever ran the suite.
    @MainActor
    func testTheRecordingSwitchWritesThroughToTheInjectedDefaults() throws {
        let name = "aibars.history.tests.switch.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let key = "aibars.history.enabled"
        let clock = anchor.addingTimeInterval(1)
        let store = try UsageHistoryStore(directory: folder(), now: { clock }, defaults: defaults)

        let standardBefore = UserDefaults.standard.object(forKey: key) as? Bool
        XCTAssertTrue(store.isEnabled, "recording ships on, or a fresh install records nothing")
        XCTAssertNil(defaults.object(forKey: key), "the default was persisted before anyone touched it")

        _ = hosted(HistoryPane(store: store))
        store.isEnabled = false

        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false, "the switch did not write through")
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Bool, standardBefore,
            "the pane wrote to UserDefaults.standard instead of the store it was given"
        )
    }

    /// And it has to mean it: nothing is recorded while it is off, so the pane's
    /// "nothing recorded, and recording is switched off" is a true sentence
    /// rather than a race with the next refresh.
    @MainActor
    func testNothingIsRecordedWhileTheSwitchIsOff() throws {
        let store = try store()
        store.isEnabled = false
        seed(store, provider: "claude", windows: ["5-hour messages"])
        XCTAssertTrue(store.series().isEmpty, "readings were stored with recording switched off")

        store.isEnabled = true
        seed(store, provider: "claude", windows: ["5-hour messages"])
        XCTAssertEqual(store.series().count, 1, "switching recording back on did not resume it")
    }

    // MARK: - The archive

    /// Nothing to export is a real state and both archive buttons are dead in
    /// it. The disabled flag itself cannot be read from out here — SwiftUI draws
    /// a Form's buttons and none of them becomes an `NSButton` to ask — so what
    /// is pinned is the predicate the pane disables on, `store.series().isEmpty`,
    /// and the fact that makes it the right predicate: an empty archive exports
    /// a header and no rows, so there is nothing a save panel could write.
    @MainActor
    func testTheArchiveIsDeadWhenThereIsNothingToExport() throws {
        let store = try store()
        let interval = HistoryRange.week.interval(ending: anchor)

        XCTAssertTrue(store.series().isEmpty, "the buttons are disabled on exactly this, and it is false")

        let empty = store.exportCSV(since: interval.start)
        XCTAssertEqual(
            empty.split(separator: "\n", omittingEmptySubsequences: true).count, 1,
            "an empty archive exported rows: \(empty)"
        )
        XCTAssertTrue(empty.hasPrefix("grain,"), "the CSV lost its header")

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the dead archive collapsed the pane")
    }

    /// And it comes alive once there is something: the same predicate the other
    /// way round, and a CSV with rows under the header naming the account they
    /// came from.
    @MainActor
    func testTheArchiveComesAliveOnceSomethingIsStored() throws {
        let store = try store()
        seed(store, provider: "claude", windows: ["5-hour messages"])
        let interval = HistoryRange.week.interval(ending: anchor)

        XCTAssertFalse(store.series().isEmpty, "the seeding recorded nothing to export")

        let csv = store.exportCSV(since: interval.start)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThan(lines.count, 1, "a stocked archive exported nothing but a header")
        XCTAssertTrue(
            lines.dropFirst().allSatisfy { $0.contains("claude") },
            "the export does not name the account its rows came from"
        )
    }

    /// Clearing is `forget` once per account, and the pane offers it for every
    /// account at once. What matters is that it empties the store without
    /// touching the switch: recording carries on, so the record starts again at
    /// the next refresh.
    @MainActor
    func testClearingEveryAccountEmptiesTheStoreAndLeavesRecordingOn() throws {
        let store = try store()
        seed(store, provider: "claude", windows: ["5-hour messages", "Weekly limit"])
        seed(store, provider: "gemini", windows: ["Daily prompts"])
        XCTAssertEqual(store.series().count, 3)

        for provider in Set(store.series().map(\.providerID)).sorted() {
            store.forget(provider)
        }
        XCTAssertTrue(store.series().isEmpty, "clearing left series behind")
        XCTAssertTrue(store.isEnabled, "clearing the archive switched recording off")

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the pane collapsed after a clear")
    }

    // MARK: - Readings that were never meant to be there

    /// A provider's figures are untrusted, and these are the ones that reach the
    /// store: no ceiling, a negative ceiling, and figures that are not numbers.
    /// None of them is a usage window, so none is recorded — a fortnight of a
    /// flat line at zero is an assertion about usage rather than an absence of
    /// one — and the pane stays in its empty state.
    @MainActor
    func testUnusableReadingsAreNotRecordedAndThePaneStaysEmpty() throws {
        let store = try store()
        let unusable: [(String, Double, Double)] = [
            ("no ceiling", 10, 0),
            ("negative ceiling", 10, -100),
            ("ceiling is not a number", 10, .nan),
            ("infinite ceiling", 10, .infinity),
            ("figure is not a number", .nan, 100),
            ("infinite figure", .infinity, 100),
            ("neither is a number", .nan, .nan)
        ]
        for (index, sample) in unusable.enumerated() {
            store.record(
                UsageData(
                    providerID: "capless-\(index)",
                    fetchedAt: anchor,
                    primary: UsageMetric(label: sample.0, used: sample.1, limit: sample.2)
                ),
                for: "capless-\(index)"
            )
        }
        XCTAssertTrue(
            store.series().isEmpty,
            "a window with no usable cap was recorded and will draw a flat line at zero"
        )

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "unusable readings collapsed the pane")
    }

    /// The readings that are usable but absurd: below zero, at zero, either side
    /// of the cap threshold the rollup counts a hit at, and well past the cap.
    /// All of them are recorded — the pair is what the provider said — and the
    /// percentage is clamped where it is read back. The pane draws every one.
    @MainActor
    func testExtremeReadingsAreRecordedAndDrawn() throws {
        let store = try store()
        let figures: [Double] = [-50, 0, 0.5, 98, 98.9, 99, 99.1, 100, 250]
        for (step, used) in figures.enumerated() {
            store.record(
                UsageData(
                    providerID: "claude",
                    fetchedAt: anchor.addingTimeInterval(-Double(figures.count - step) * 60),
                    primary: UsageMetric(label: "5-hour messages", used: used, limit: 100)
                ),
                for: "claude"
            )
        }
        let series = try XCTUnwrap(store.series().first, "nothing was recorded")
        let samples = store.samples(for: series, since: anchor.addingTimeInterval(-86_400))
        XCTAssertEqual(
            samples.count, figures.count,
            "a reading outside 0...100% was refused rather than clamped"
        )
        for sample in samples {
            XCTAssertTrue(
                (0...1).contains(sample.percent),
                "a reading came back as \(sample.percent), which is not a percentage"
            )
        }

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "an extreme reading collapsed the pane")
    }

    /// A reading stamped in the future is the ordinary result of a clock skew,
    /// and it must not be filed ahead of the present: a sample past the end of
    /// the interval falls outside every bucket, and the newest reading vanishing
    /// off the chart is the one failure a user would spot immediately.
    @MainActor
    func testAReadingFromTheFutureIsFiledAtTheStoresOwnClock() throws {
        let clock = anchor.addingTimeInterval(1)
        let store = try store(now: clock)
        store.record(
            UsageData(
                providerID: "claude",
                fetchedAt: clock.addingTimeInterval(365 * 24 * 60 * 60),
                primary: UsageMetric(label: "5-hour messages", used: 40, limit: 100)
            ),
            for: "claude"
        )
        let series = try XCTUnwrap(store.series().first, "the future reading was dropped entirely")
        let interval = HistoryRange.week.interval(ending: clock.addingTimeInterval(120))
        XCTAssertEqual(
            store.samples(for: series, since: interval.start).count, 1,
            "the reading was filed outside the week it was taken in"
        )
    }

    /// Enough days to overflow the table's own limit, which is where the pane
    /// stops listing and accounts for the rest in a line instead. The store has
    /// to hold more days than the table prints or that line is never exercised,
    /// and the pane has to build with the overflow in it.
    @MainActor
    func testAQuarterOfRollupsOverflowsTheTableWithoutBreakingThePane() throws {
        let store = try store()
        for dayOffset in stride(from: 40, through: 0, by: -1) {
            store.record(
                UsageData(
                    providerID: "claude",
                    fetchedAt: anchor.addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60),
                    primary: UsageMetric(label: "5-hour messages", used: Double(dayOffset), limit: 100)
                ),
                for: "claude"
            )
        }
        let series = try XCTUnwrap(store.series().first, "the seeding recorded nothing")
        let quarter = HistoryRange.quarter.interval(ending: anchor.addingTimeInterval(120))
        XCTAssertGreaterThan(
            store.days(for: series, since: quarter.start).count, 31,
            "forty-one days of readings produced no more rows than the table prints, so the "
                + "overflow line is never exercised"
        )

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "a quarter of rollups collapsed the pane")
    }

    // MARK: - A history file this app did not write

    /// History outlives the version that wrote it, so what comes back off disk
    /// is untrusted input like any other. This writes the rows no honest run
    /// produces — an infinite peak, a peak above one and one below zero, a day
    /// with no readings behind its mean, a window with no name, a cap of zero, a
    /// stamp in the far past and one in the year 5000 — and opens the pane on
    /// them.
    ///
    /// Two things worth saying. NaN is absent because SQLite has no way to carry
    /// one: a NaN bound to a REAL column is stored as NULL, and these columns are
    /// NOT NULL, so a figure reaching the pane from disk is a real number by
    /// construction. And the fixture is written against schema version 1 — if
    /// the store's schema moves, `series()` comes back empty and this fails
    /// rather than passing over a file nothing read.
    @MainActor
    func testAMalformedHistoryFileStillOpensThePane() throws {
        let folder = folder()
        try writeMalformedHistory(in: folder)

        let store = try store(in: folder)
        XCTAssertFalse(
            store.series().isEmpty,
            "the fixture was not read back — the schema it is written against has moved"
        )

        let host = hosted(HistoryPane(store: store))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "a malformed history file collapsed the pane")
        XCTAssertGreaterThanOrEqual(
            controls(in: host).count, 1,
            "a malformed history file took the form with it"
        )
    }

    /// The same file, read the way the pane reads it: every figure it hands out
    /// has to be one a row can print. The store divides `used` by `cap` and
    /// `total` by `samples`, and both divisors are zero somewhere in this file.
    @MainActor
    func testAMalformedHistoryFileYieldsNoUnusableFigures() throws {
        let folder = folder()
        try writeMalformedHistory(in: folder)
        let store = try store(in: folder)
        let series = try XCTUnwrap(store.series().first, "the fixture was not read back")

        let samples = store.samples(for: series, since: .distantPast)
        XCTAssertFalse(samples.isEmpty, "the fixture's readings were not read back")
        for sample in samples {
            XCTAssertTrue(
                (0...1).contains(sample.percent),
                "a stored reading came back as \(sample.percent), which is not a percentage"
            )
        }

        // The whole file, at whichever grain survived, has to come out as text:
        // this is what the export button hands to a save panel.
        let csv = store.exportCSV(since: .distantPast)
        XCTAssertTrue(csv.hasPrefix("grain,"), "the export of a malformed file lost its header")
        XCTAssertFalse(
            csv.lowercased().contains("nan"),
            "the export carried a figure no spreadsheet can read"
        )
    }

    /// A file written by a schema this build does not know about is refused
    /// rather than migrated, because opening it would mean writing rows a shape
    /// we have never seen has to make sense of. Asserted on the store, because
    /// the pane's unavailable branch is reached through a nil store and there is
    /// no way to ask for one deliberately — which is right: it is a state of the
    /// machine, not a setting.
    @MainActor
    func testAHistoryFileFromALaterVersionIsRefusedRatherThanOpened() throws {
        let folder = folder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.sqlite")

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        let database = try XCTUnwrap(handle)
        exec(database, "PRAGMA user_version = 9999;")
        sqlite3_close(database)

        let clock = anchor
        XCTAssertThrowsError(
            try UsageHistoryStore(directory: folder, now: { clock }, defaults: .standard)
        ) { error in
            XCTAssertTrue(error is HistoryError, "got \(type(of: error)) rather than a history error")
        }
    }

    // MARK: - The malformed fixture

    /// Schema v1, and rows a running app would never write. In one place so both
    /// tests above read the same file.
    private func writeMalformedHistory(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                folder.appendingPathComponent("history.sqlite").path,
                &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
            ),
            SQLITE_OK
        )
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }

        exec(database, """
            CREATE TABLE series (
                id INTEGER PRIMARY KEY, provider TEXT NOT NULL, window_key TEXT NOT NULL,
                label TEXT NOT NULL, unit TEXT, last_ts INTEGER NOT NULL DEFAULT 0,
                last_pct REAL NOT NULL DEFAULT 0, last_reset INTEGER NOT NULL DEFAULT 0,
                UNIQUE (provider, window_key));
            """)
        exec(database, """
            CREATE TABLE sample (
                series INTEGER NOT NULL, ts INTEGER NOT NULL, used REAL NOT NULL,
                cap REAL NOT NULL, boundary INTEGER NOT NULL DEFAULT 0, UNIQUE (series, ts));
            """)
        exec(database, "CREATE INDEX sample_ts ON sample (ts);")
        exec(database, """
            CREATE TABLE day (
                series INTEGER NOT NULL, day INTEGER NOT NULL, peak REAL NOT NULL,
                total REAL NOT NULL, peak_used REAL NOT NULL, cap REAL NOT NULL,
                samples INTEGER NOT NULL, hits INTEGER NOT NULL, resets INTEGER NOT NULL,
                UNIQUE (series, day));
            """)

        // Series are handed back ordered by provider then window key, so the
        // unnamed one sorts first and is the one the pane resolves to and draws.
        // The second is filed under a provider that no longer exists, which is
        // the ordinary state of a history that outlived a sign-out.
        exec(database, """
            INSERT INTO series (id, provider, window_key, label, unit) VALUES
                (1, '', '', '· · ·', ''),
                (2, 'ghost', 'window', '', NULL);
            """)

        // `9e999` overflows to an infinity, which is the only non-finite value
        // SQLite can hold at all.
        let today = Int64(anchor.timeIntervalSince1970.rounded())
        let midnight = today - today % 86_400
        exec(database, """
            INSERT INTO sample (series, ts, used, cap, boundary) VALUES
                (1, \(midnight), 40, 0, 0),
                (1, \(midnight + 60), -40, 100, 0),
                (1, \(midnight + 120), 9e999, 100, 0),
                (1, \(midnight + 180), 400, -100, 1),
                (1, \(midnight + 240), 50, 9e999, 0),
                (1, \(midnight + 300), 400, 100, 0),
                (1, 0, 10, 100, 0),
                (1, -2000000000, 10, 100, 0),
                (1, 95617584000, 10, 100, 0);
            """)
        exec(database, """
            INSERT INTO day (series, day, peak, total, peak_used, cap, samples, hits, resets) VALUES
                (1, \(midnight), 9e999, 9e999, 9e999, 0, 0, -1, -1),
                (1, \(midnight - 86400), -1.5, -100, -100, 100, 3, 0, 0),
                (1, \(midnight - 172800), 5.0, 500, 5000, 100, 1, 99, 99),
                (1, 95617584000, 0.5, 0.5, 50, 100, 1, 0, 0),
                (2, \(midnight), 0.5, 0.5, 50, 100, 1, 0, 0);
            """)
        exec(database, "PRAGMA user_version = 1;")
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        if status != SQLITE_OK {
            XCTFail("fixture failed: \(message.map { String(cString: $0) } ?? "code \(status)")")
        }
        sqlite3_free(message)
    }
}
