import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The sentence, without hosting anything.
///
/// `ForecastLine.text` is the whole of the view's decision that a caption exists
/// at all — the wording comes from `UsageForecast` and the ink is chosen after
/// the fact — so it is the part worth pinning. The outcomes are built directly
/// rather than fitted from samples: what the line says about a `.capsAt` must
/// not depend on which series happened to produce one.
final class ForecastLineTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func projection(
        _ outcome: Outcome,
        pointsPerHour: Double = 40,
        sampleCount: Int = 6,
        span: TimeInterval = 900
    ) -> UsageProjection {
        UsageProjection(
            outcome: outcome,
            pointsPerHour: pointsPerHour,
            sampleCount: sampleCount,
            span: span
        )
    }

    private func text(_ projection: UsageProjection?, showsPace: Bool = true) -> String? {
        ForecastLine.text(projection: projection, now: now, showsPace: showsPace)
    }

    // MARK: - Refusals

    func testNoLineWithoutAProjection() {
        XCTAssertNil(text(nil))
    }

    func testNoLineWhileIdle() {
        XCTAssertNil(text(projection(.idle, pointsPerHour: 0)))
    }

    func testNoLineWhileFalling() {
        XCTAssertNil(text(projection(.falling, pointsPerHour: -30)))
    }

    func testNoLineBeyondTheHorizon() {
        XCTAssertNil(text(projection(.beyondHorizon, pointsPerHour: 0.2)))
    }

    /// The setting is the one refusal `ForecastLine` owns, so it has to beat
    /// every outcome, including the two that would otherwise have something to
    /// say.
    func testTheSettingSilencesEveryOutcome() {
        let outcomes: [Outcome] = [
            .idle,
            .falling,
            .beyondHorizon,
            .capsAt(now.addingTimeInterval(600)),
            .resetsFirst(now.addingTimeInterval(600))
        ]
        for outcome in outcomes {
            XCTAssertNil(
                text(projection(outcome), showsPace: false),
                "\(outcome) still drew a line with the pace setting off"
            )
        }
        XCTAssertNil(text(nil, showsPace: false))
    }

    // MARK: - Wording

    func testCapsAtSaysWhenThePaceGetsThere() {
        XCTAssertEqual(text(projection(.capsAt(now.addingTimeInterval(45 * 60)))), "on pace to cap in 45m")
    }

    /// The reassurance names the renewal, not the cap, or a row that is going to
    /// be fine reads like a row that is not.
    func testResetsFirstNamesTheResetInstead() {
        let line = text(projection(.resetsFirst(now.addingTimeInterval(90 * 60))))
        XCTAssertEqual(line, "resets in 1h 30m, you'll finish under")
        XCTAssertEqual(line?.contains("cap"), false, "the reassurance is naming the cap")
    }

    // MARK: - Boundaries

    /// Either side of the instant the line is measured from. An arrival that has
    /// already happened is not a countdown, and one landing exactly on `now` is
    /// the same reading a moment later.
    func testAnArrivalAtOrBeforeNowSaysNothing() {
        XCTAssertNil(text(projection(.capsAt(now.addingTimeInterval(-1)))))
        XCTAssertNil(text(projection(.capsAt(now))))
        XCTAssertNotNil(text(projection(.capsAt(now.addingTimeInterval(1)))))

        XCTAssertNil(text(projection(.resetsFirst(now.addingTimeInterval(-1)))))
        XCTAssertNil(text(projection(.resetsFirst(now))))
        XCTAssertNotNil(text(projection(.resetsFirst(now.addingTimeInterval(1)))))
    }

    /// Both sides of every step in the countdown's wording: the minute it starts
    /// counting, the hour it starts naming, and the whole hour that must not
    /// carry a trailing "0m".
    func testTheCountdownReadsCorrectlyAcrossItsSteps() {
        let expected: [(TimeInterval, String)] = [
            (1, "under a minute"),
            (29, "under a minute"),
            (30, "1m"),
            (60, "1m"),
            (90, "2m"),
            (59 * 60, "59m"),
            (3570, "1h"),
            (3600, "1h"),
            (3660, "1h 1m"),
            (12 * 3600, "12h")
        ]
        for (interval, phrase) in expected {
            XCTAssertEqual(
                text(projection(.capsAt(now.addingTimeInterval(interval)))),
                "on pace to cap in \(phrase)",
                "\(interval)s away"
            )
        }
    }

    /// The burn rate and the sample counts belong to the meter and the diagnostics,
    /// not to this sentence. A degenerate one — zero, negative, or the NaN a fit
    /// over a flat series can hand back — must not change a word of it, and must
    /// not crash on the way through.
    func testTheSentenceIgnoresTheRestOfTheProjection() {
        let rates = [0.0, -240.0, .nan, .infinity, -Double.infinity, .greatestFiniteMagnitude]
        for rate in rates {
            XCTAssertEqual(
                text(projection(.capsAt(now.addingTimeInterval(600)), pointsPerHour: rate)),
                "on pace to cap in 10m",
                "a burn rate of \(rate) changed the sentence"
            )
        }
        XCTAssertEqual(
            text(projection(.capsAt(now.addingTimeInterval(600)), sampleCount: 0, span: 0)),
            "on pace to cap in 10m"
        )
        XCTAssertEqual(
            text(projection(.capsAt(now.addingTimeInterval(600)), sampleCount: -1, span: -900)),
            "on pace to cap in 10m"
        )
        // And a rate that would be worth a line cannot talk an outcome that has
        // nothing to say into one.
        XCTAssertNil(text(projection(.idle, pointsPerHour: 400)))
    }
}

/// What the two measuring classes below both need: a scratch defaults domain, a
/// ring fed the way the refresh loop feeds one, and one hosted measurement.
///
/// Written once rather than once per class. Both classes draw the same view
/// under the same fixture and disagree only about which dimension they read, and
/// a fixture kept in two places is a fixture that drifts until the two
/// measurements are describing different pictures.
@MainActor
private enum Fixture {
    /// A row asks with its own account id — "claude", "claude#2" — so the ring
    /// every fixture fills is filed under one of those rather than a service
    /// name. Only the tests about a mistyped id spell a different one.
    static let providerID = "claude"

    /// A rise slow enough that the cap is days out, which is what leaves the
    /// renewal as the only thing worth naming and produces `.resetsFirst`. Still
    /// clear of the fit's own noise floor, or the outcome would be `.idle`.
    static let creep: [Double] = [0.10, 0.101, 0.102]

    /// A rise that reaches its cap inside the hour, which is `.capsAt` and the
    /// shorter of the two phrasings.
    static let climb: [Double] = [0.10, 0.30, 0.50]

    static func defaults(_ name: String) throws -> UserDefaults {
        // Removed first: the store persists its rings, and a suite left behind
        // by an earlier run would forecast a provider this test never fed.
        UserDefaults.standard.removePersistentDomain(forName: name)
        return try XCTUnwrap(UserDefaults(suiteName: name), "no scratch defaults domain \(name)")
    }

    static func appearance(_ name: String) throws -> AppearanceSettings {
        AppearanceSettings(store: try defaults("forecast-line-appearance-\(name)"))
    }

    /// A store holding one ring, fed as the refresh loop feeds it. Percentages
    /// are five minutes apart because that is the shortest span the fit accepts,
    /// and the last of them lands on `now` so the answer is not stale before it
    /// is read.
    ///
    /// `resetAt` rides on the metric exactly as a provider's own renewal does,
    /// because that is the only way to reach the `.resetsFirst` phrasing — and
    /// that phrasing is the longest sentence this view can be asked to carry.
    static func trend(
        _ name: String,
        now: Date,
        percents: [Double],
        resetAt: Date? = nil
    ) throws -> UsageTrendStore {
        let store = UsageTrendStore(store: try defaults("forecast-line-trend-\(name)"), now: { now })
        for (index, percent) in percents.enumerated() {
            let at = now.addingTimeInterval(-Double(percents.count - 1 - index) * 300)
            store.record(
                UsageData(
                    providerID: providerID,
                    fetchedAt: at,
                    primary: UsageMetric(
                        label: "5h window",
                        used: percent * 100,
                        limit: 100,
                        unit: "%",
                        resetDate: resetAt
                    )
                ),
                for: providerID
            )
        }
        return store
    }

    /// The line a row would draw for `trend`, under `appearance`.
    ///
    /// Built through `ForecastLine.text` rather than by handing the view a store,
    /// because that is now the only way a row builds one: the fold moved the
    /// claim onto the caption line, so the view takes a resolved string and the
    /// decision — the setting, and every refusal `UsageForecast` makes — happens
    /// once, above it. A helper that reached the store a second way would be
    /// asserting a path the app no longer has.
    static func line(_ trend: UsageTrendStore, _ appearance: AppearanceSettings) -> ForecastLine {
        ForecastLine(phrase: phrase(trend), appearance: appearance)
    }

    /// The sentence the row would resolve for `trend`, by the row's own route.
    static func phrase(_ trend: UsageTrendStore, id: String = providerID) -> String? {
        ForecastLine.text(
            projection: trend.projection(for: id),
            now: Date(),
            showsPace: trend.showsPaceInPanel
        )
    }

    /// The sentence the view is about to draw, read the way the view reads it.
    ///
    /// The clock moves between this and the measurement, but only by the
    /// milliseconds the test takes: a countdown rounded to the minute does not
    /// change over that, and a digit that did change would still be the same
    /// width in the tabular face the line is supposed to be set in.
    static func sentence(_ trend: UsageTrendStore) throws -> String {
        try XCTUnwrap(
            ForecastLine.text(projection: trend.projection(for: providerID), now: Date(), showsPace: true),
            "the fixture produced no sentence to measure"
        )
    }

    /// The intrinsic size, with nothing imposed but a width when a case names
    /// one. `MenuBarExtra` gives the panel no frame, so this is the measurement
    /// that matches what the real window does.
    static func size(_ view: some View, width: CGFloat? = nil) -> CGSize {
        let host: NSHostingView<AnyView>
        if let width {
            host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        } else {
            host = NSHostingView(rootView: AnyView(view))
        }
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}

/// What the line costs the row: nothing on the rows that will never have one,
/// and exactly one caption box on the rows that do.
///
/// `MenuBarExtra` sizes its window to the content, so anything the panel
/// reserves is paid for on every row. Most rows have no pace to report, which is
/// why this view is an `EmptyView` rather than a blank caption — and the only
/// way to know it stayed one is to measure it with nothing imposed, as
/// `PanelLayoutTests` does for the panel itself.
///
/// The other half is the row it does appear on. Of every line in a row this is
/// the one whose sentence changes length as it counts down, from "under a
/// minute" to "resets in 11h 59m, you'll finish under", so it is the line most
/// able to wrap and resize the panel under an open pointer. `RowGeometry`
/// reserves it at `Tokens.lineBox(captionSize)` and is given no content at all;
/// these cases are what make that reservation true of the view as well.
final class ForecastLineLayoutTests: XCTestCase {
    /// A rising series lands here, so the arrival date the view reads against
    /// its own `Date()` is still ahead of it while the test runs.
    private let now = Date()

    /// A width no phrasing fits in — the shortest sentence the line can carry is
    /// nearly a hundred points wide at the smallest caption size the settings
    /// allow. The box has to hold at a width like this or it is only holding
    /// because nothing was asking it to wrap.
    private static let hostileWidth: CGFloat = 60

    @MainActor
    private func appearance(_ name: String) throws -> AppearanceSettings {
        try Fixture.appearance(name)
    }

    @MainActor
    private func trend(
        _ name: String,
        percents: [Double],
        resetAt: Date? = nil
    ) throws -> UsageTrendStore {
        try Fixture.trend(name, now: now, percents: percents, resetAt: resetAt)
    }

    @MainActor
    private func height(_ view: some View, width: CGFloat? = nil) -> CGFloat {
        Fixture.size(view, width: width).height
    }

    /// One caption box, at whatever type size the settings are currently on.
    ///
    /// The tolerance is a rounding allowance in one direction only. `captionSize`
    /// is a density step times a text scale, so the box is rarely a whole number,
    /// and `fittingSize` answers in whole points — while a wrapped sentence would
    /// cost a second line, which is eleven points at the smallest caption size
    /// this can be drawn at.
    @MainActor
    private func assertOneCaptionBox(
        _ appearance: AppearanceSettings,
        _ trend: UsageTrendStore,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let box = Tokens.lineBox(appearance.metrics.captionSize)
        let drawn = height(Fixture.line(trend, appearance), width: Self.hostileWidth)
        XCTAssertGreaterThanOrEqual(
            drawn, box - 0.01,
            "\(what) drew \(drawn)pt for a \(box)pt caption box, so the row is holding less than it reserved",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            drawn, box + 2,
            "\(what) drew \(drawn)pt against a \(box)pt caption box — the sentence has wrapped and grown the row",
            file: file, line: line
        )
    }

    // MARK: - The rows with nothing to say

    @MainActor
    func testARowWithNoSamplesReservesNoHeight() throws {
        let line = Fixture.line(
            try trend("empty", percents: []),
            try appearance("empty")
        )
        XCTAssertEqual(
            height(line), 0, accuracy: 0.01,
            "a row with nothing to forecast is still holding space for a line"
        )
    }

    /// The id a row asks with is its own — "claude#2", not "claude" — so a
    /// mistyped or empty one must draw nothing rather than borrow a neighbour's
    /// pace.
    @MainActor
    func testAnUnknownOrEmptyProviderIDReservesNoHeight() throws {
        let store = try trend("unknown", percents: Fixture.climb)
        let appearance = try appearance("unknown")
        for providerID in ["", "claude#2", "not-a-provider"] {
            let line = ForecastLine(
                phrase: Fixture.phrase(store, id: providerID),
                appearance: appearance
            )
            XCTAssertEqual(
                height(line), 0, accuracy: 0.01,
                "\"\(providerID)\" drew a line from another row's samples"
            )
        }
    }

    @MainActor
    func testTheSettingTakesTheHeightWithIt() throws {
        let store = try trend("setting", percents: Fixture.climb)
        store.showsPaceInPanel = false
        XCTAssertEqual(
            height(Fixture.line(store, try appearance("setting"))),
            0, accuracy: 0.01,
            "switching the pace line off left its space behind"
        )
    }

    /// A meter already at its cap projects an arrival at the last sample, which
    /// is in the past by the time the row is drawn. The row is not told to say
    /// "capped a moment ago" — it is told to say nothing, and to take no room
    /// doing it.
    @MainActor
    func testAnArrivalAlreadyPassedReservesNoHeight() throws {
        let store = try trend("arrived", percents: [0.60, 0.80, 1.0])
        guard case .capsAt? = store.projection(for: "claude")?.outcome else {
            return XCTFail("a meter reaching its cap did not project an arrival")
        }
        XCTAssertEqual(
            height(Fixture.line(store, try appearance("arrived"))),
            0, accuracy: 0.01,
            "an arrival in the past is still holding a line open"
        )
    }

    // MARK: - The box

    @MainActor
    func testAForecastIsOneCaptionBoxTall() throws {
        let store = try trend("box", percents: Fixture.climb)
        // Asserted rather than assumed: a nil projection would satisfy a height
        // ceiling by drawing nothing at all.
        guard case .capsAt? = store.projection(for: "claude")?.outcome else {
            return XCTFail("the rising series did not produce a cap to forecast")
        }
        assertOneCaptionBox(try appearance("box"), store, "the shipped settings")
    }

    /// Every look the app ships, and both phrasings, against the same box.
    ///
    /// The presets are swept because the box follows `captionSize` and each of
    /// them names its own; the three densities at both ends of the text scale are
    /// swept after them because no preset reaches either end, and both ends are
    /// where the box stops being a whole number.
    @MainActor
    func testTheCaptionBoxHoldsAtEveryPresetAndBothPhrasings() throws {
        let capping = try trend("box-capping", percents: Fixture.climb)
        let renewing = try trend(
            "box-renewing",
            percents: Fixture.creep,
            resetAt: now.addingTimeInterval(11 * 3600 + 59 * 60)
        )
        guard case .capsAt? = capping.projection(for: "claude")?.outcome else {
            return XCTFail("the rising series did not produce a cap to forecast")
        }
        guard case .resetsFirst? = renewing.projection(for: "claude")?.outcome else {
            return XCTFail("the creeping series and its renewal did not produce the longest phrasing")
        }

        let appearance = try appearance("box-presets")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            assertOneCaptionBox(appearance, capping, "\(preset.id), on pace to cap")
            assertOneCaptionBox(appearance, renewing, "\(preset.id), resetting first")
        }
        for density in AppearanceSettings.Density.allCases {
            for scale in [0.85, 1.0, 1.30] {
                appearance.density = density
                appearance.textScale = scale
                assertOneCaptionBox(appearance, renewing, "\(density.rawValue) at \(scale)")
            }
        }
    }

    /// And the box is the same box for the longest sentence and the shortest.
    ///
    /// Stated as an equality rather than as two ceilings: a line that is one
    /// point taller when the countdown reaches an hour still moves every row
    /// under it, and it would pass both bounds above on its own.
    @MainActor
    func testTheLongestPhrasingIsTheSameHeightAsTheShortest() throws {
        let capping = try trend("same-capping", percents: Fixture.climb)
        let renewing = try trend(
            "same-renewing",
            percents: Fixture.creep,
            resetAt: now.addingTimeInterval(11 * 3600 + 59 * 60)
        )
        let short = try Fixture.sentence(capping)
        let long = try Fixture.sentence(renewing)
        XCTAssertGreaterThan(
            long.count, short.count,
            "both fixtures are carrying \"\(short)\", so this case is comparing one sentence with itself"
        )

        let appearance = try appearance("same")
        for density in AppearanceSettings.Density.allCases {
            appearance.density = density
            XCTAssertEqual(
                height(Fixture.line(capping, appearance), width: Self.hostileWidth),
                height(Fixture.line(renewing, appearance), width: Self.hostileWidth),
                "\(density.rawValue) drew \"\(long)\" at a different height from \"\(short)\""
            )
        }
    }
}

/// Which face the sentence is set in, measured rather than read off the source.
///
/// §3.1 splits the two faces by content: a run containing a word is SF Pro with
/// tabular digits, and SF Mono belongs to figures inside a reserved rail. This
/// line is prose with a countdown in it — the longest prose in the panel — so it
/// is SF Pro, and a mono pace line is the terminal pastiche the direction rules
/// out. The two faces are far enough apart in advance width to tell apart by
/// measurement: "resets in 11h 59m, you'll finish under" is 180pt in SF Pro at
/// 10pt and 235pt in SF Mono, so nothing here has to reach into the view's font.
///
/// Widths are compared as differences between two sentences rather than as
/// absolutes, so any padding or leading the caption picks up on its way into a
/// row cancels out and the case keeps measuring the face.
final class ForecastLineFaceTests: XCTestCase {
    /// The same clock the layout cases use, and for the same reason: the arrival
    /// dates have to still be ahead of the view's own `Date()`.
    private let now = Date()

    /// The type scales the sweeps run at: unscaled, and at the largest the
    /// settings allow, which is where the two faces are furthest apart and any
    /// tolerance below is doing the least work.
    private static let scales: [Double] = [1.0, 1.30]

    /// The three faces one sentence could be set in: the one §3.1 asks for, and
    /// the two it rules out. `proportional` is SF Pro with the figures it comes
    /// with, which is what forgetting `monospacedDigit()` leaves behind.
    private enum Face {
        case proportional
        case tabular
        case mono
    }

    @MainActor
    private func width(_ view: some View) -> CGFloat {
        Fixture.size(view).width
    }

    /// One sentence, set in one of the three faces, measured the same way the
    /// view is.
    @MainActor
    private func reference(_ sentence: String, size: CGFloat, in face: Face) -> CGFloat {
        switch face {
        case .proportional:
            return width(Text(sentence).font(.system(size: size)).lineLimit(1))
        case .tabular:
            return width(Text(sentence).font(.system(size: size)).monospacedDigit().lineLimit(1))
        case .mono:
            // `Font.system(design:)` rather than `Text.monospaced()`, which is
            // macOS 13.3 and would raise the floor past the stated minimum.
            return width(Text(sentence).font(.system(size: size, design: .monospaced)).lineLimit(1))
        }
    }

    /// SF Pro's own figures are proportional, so a "1" is narrower than an "8".
    /// Without tabular digits asked for, the same sentence changes width as it
    /// counts down, and the words after the figure shuffle sideways every minute
    /// on every row that has a pace.
    @MainActor
    func testTheCountdownIsSetInTabularDigits() throws {
        // Two renewals whose sentences are the same length, one written in the
        // narrowest digits SF Pro has and one in its widest: "1h 11m" against
        // "8h 44m".
        let narrow = try Fixture.trend(
            "face-narrow", now: now,
            percents: Fixture.creep,
            resetAt: now.addingTimeInterval(3600 + 11 * 60)
        )
        let wide = try Fixture.trend(
            "face-wide", now: now,
            percents: Fixture.creep,
            resetAt: now.addingTimeInterval(8 * 3600 + 44 * 60)
        )
        let narrowLine = try Fixture.sentence(narrow)
        let wideLine = try Fixture.sentence(wide)
        XCTAssertEqual(
            narrowLine.count, wideLine.count,
            "\"\(narrowLine)\" and \"\(wideLine)\" are not the same length, so a width difference would prove nothing"
        )

        let appearance = try Fixture.appearance("face-tabular")
        for density in AppearanceSettings.Density.allCases {
            for scale in Self.scales {
                appearance.density = density
                appearance.textScale = scale
                let size = appearance.metrics.captionSize
                let context = "\(density.rawValue) at \(scale)"

                // The control. If the two sentences measure the same in
                // proportional figures then this case cannot see the difference
                // it is claiming to test.
                XCTAssertGreaterThan(
                    abs(reference(wideLine, size: size, in: .proportional)
                        - reference(narrowLine, size: size, in: .proportional)),
                    2,
                    "\(context): proportional figures set both sentences at one width, so this case is blind"
                )

                XCTAssertEqual(
                    width(Fixture.line(narrow, appearance)),
                    width(Fixture.line(wide, appearance)),
                    accuracy: 0.5,
                    "\(context): \"\(narrowLine)\" and \"\(wideLine)\" came out different widths, "
                        + "so the digits are not tabular and the sentence twitches as it counts down"
                )
            }
        }
    }

    @MainActor
    func testTheSentenceIsSetInSFProRatherThanSFMono() throws {
        let short = try Fixture.trend("face-short", now: now, percents: Fixture.climb)
        let long = try Fixture.trend(
            "face-long", now: now,
            percents: Fixture.creep,
            resetAt: now.addingTimeInterval(11 * 3600 + 59 * 60)
        )
        let shortLine = try Fixture.sentence(short)
        let longLine = try Fixture.sentence(long)
        XCTAssertGreaterThan(
            longLine.count, shortLine.count,
            "both fixtures are carrying \"\(shortLine)\", so there is no difference in width to read"
        )

        let appearance = try Fixture.appearance("face-pro")
        for density in AppearanceSettings.Density.allCases {
            for scale in Self.scales {
                appearance.density = density
                appearance.textScale = scale
                let size = appearance.metrics.captionSize
                let context = "\(density.rawValue) at \(scale)"

                let pro = reference(longLine, size: size, in: .tabular)
                    - reference(shortLine, size: size, in: .tabular)
                let mono = reference(longLine, size: size, in: .mono)
                    - reference(shortLine, size: size, in: .mono)
                // Mono sets every character at one advance, so the same extra
                // seventeen characters cost it a good deal more than SF Pro. If
                // they ever cost the same the comparison below means nothing.
                XCTAssertGreaterThan(
                    mono - pro, 10,
                    "\(context): the two faces measure these sentences too closely for this case to separate them"
                )

                let drawn = width(Fixture.line(long, appearance))
                    - width(Fixture.line(short, appearance))
                XCTAssertEqual(
                    drawn, pro, accuracy: 2,
                    "\(context): the sentence grew by \(drawn)pt where SF Pro grows by \(pro)pt"
                )
                XCTAssertLessThan(
                    drawn, pro + (mono - pro) / 2,
                    "\(context): the sentence is set in SF Mono — prose belongs to SF Pro, and mono outside a rail "
                        + "is the terminal pastiche the direction rules out"
                )
            }
        }
    }
}
