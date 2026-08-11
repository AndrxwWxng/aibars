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

/// The line costs nothing on the rows that will never have one.
///
/// `MenuBarExtra` sizes its window to the content, so anything the panel
/// reserves is paid for on every row. Most rows have no pace to report, which is
/// why this view is an `EmptyView` rather than a blank caption — and the only
/// way to know it stayed one is to measure it with nothing imposed, as
/// `PanelLayoutTests` does for the panel itself.
final class ForecastLineLayoutTests: XCTestCase {
    /// A rising series lands here, so the arrival date the view reads against
    /// its own `Date()` is still ahead of it while the test runs.
    private let now = Date()

    private func defaults(_ name: String) throws -> UserDefaults {
        // Removed first: the store persists its rings, and a suite left behind
        // by an earlier run would forecast a provider this test never fed.
        UserDefaults.standard.removePersistentDomain(forName: name)
        return try XCTUnwrap(UserDefaults(suiteName: name), "no scratch defaults domain \(name)")
    }

    @MainActor
    private func appearance(_ name: String) throws -> AppearanceSettings {
        AppearanceSettings(store: try defaults("forecast-line-appearance-\(name)"))
    }

    /// A store holding one ring, fed as the refresh loop feeds it. Percentages
    /// are five minutes apart because that is the shortest span the fit accepts.
    @MainActor
    private func trend(_ name: String, percents: [Double]) throws -> UsageTrendStore {
        let store = UsageTrendStore(store: try defaults("forecast-line-trend-\(name)"), now: { self.now })
        for (index, percent) in percents.enumerated() {
            let at = now.addingTimeInterval(-Double(percents.count - 1 - index) * 300)
            store.record(
                UsageData(
                    providerID: "claude",
                    fetchedAt: at,
                    primary: UsageMetric(label: "5h window", used: percent * 100, limit: 100, unit: "%")
                ),
                for: "claude"
            )
        }
        return store
    }

    @MainActor
    private func height(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// One caption line, measured the same way, so the ceiling follows the
    /// user's type size rather than a number that goes stale when it changes.
    @MainActor
    private func captionLineHeight(_ appearance: AppearanceSettings) -> CGFloat {
        height(
            Text("on pace to cap in 12m")
                .font(.system(size: appearance.metrics.captionSize))
                .lineLimit(1)
        )
    }

    @MainActor
    func testARowWithNoSamplesReservesNoHeight() throws {
        let line = ForecastLine(
            providerID: "grok",
            resetDate: nil,
            appearance: try appearance("empty"),
            trend: try trend("empty", percents: [])
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
        let store = try trend("unknown", percents: [0.10, 0.30, 0.50])
        let appearance = try appearance("unknown")
        for providerID in ["", "claude#2", "not-a-provider"] {
            let line = ForecastLine(
                providerID: providerID,
                resetDate: nil,
                appearance: appearance,
                trend: store
            )
            XCTAssertEqual(
                height(line), 0, accuracy: 0.01,
                "\"\(providerID)\" drew a line from another row's samples"
            )
        }
    }

    @MainActor
    func testAForecastFitsOnOneCaptionLine() throws {
        let store = try trend("caps", percents: [0.10, 0.30, 0.50])
        // Asserted rather than assumed: a nil projection would satisfy a height
        // ceiling by drawing nothing at all.
        guard case .capsAt? = store.projection(for: "claude")?.outcome else {
            return XCTFail("the rising series did not produce a cap to forecast")
        }

        let appearance = try appearance("caps")
        let drawn = height(
            ForecastLine(providerID: "claude", resetDate: nil, appearance: appearance, trend: store)
        )
        XCTAssertGreaterThan(drawn, 0, "the forecast is there but nothing was drawn for it")
        XCTAssertLessThanOrEqual(
            drawn, captionLineHeight(appearance) + 0.5,
            "the pace line wrapped past one caption line and has grown the row"
        )
    }

    @MainActor
    func testTheSettingTakesTheHeightWithIt() throws {
        let store = try trend("setting", percents: [0.10, 0.30, 0.50])
        store.showsPaceInPanel = false
        XCTAssertEqual(
            height(
                ForecastLine(
                    providerID: "claude",
                    resetDate: nil,
                    appearance: try appearance("setting"),
                    trend: store
                )
            ),
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
            height(
                ForecastLine(
                    providerID: "claude",
                    resetDate: nil,
                    appearance: try appearance("arrived"),
                    trend: store
                )
            ),
            0, accuracy: 0.01,
            "an arrival in the past is still holding a line open"
        )
    }
}
