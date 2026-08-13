import XCTest
import SQLite3
@testable import aibarsCore

/// OpenCode is read off the disk rather than fetched, so the fixtures here are
/// real SQLite databases built to the schema the provider documents having
/// verified against a live `opencode.db`. That is deliberate: if OpenCode
/// renames a column the reader is meant to say "aibars cannot read this yet"
/// out loud rather than report a paying user's spend as zero, and that promise
/// is only as good as a test that would fail the moment the schema moved.
///
/// Every window is arithmetic on `now`, and `now` is a parameter everywhere it
/// matters, so none of this reads the clock.
final class OpenCodeParserTests: XCTestCase {
    /// A Wednesday, 15:00 UTC. Mid-week and mid-month so no window boundary is
    /// accidentally sitting on it; the tests that care about boundaries move
    /// `now` onto one deliberately.
    private let now = Date(timeIntervalSince1970: 1_786_546_800)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        // `AppDefaults.current`, which is the domain the provider itself reads
        // and writes: `.standard` in the app, and this process's own scratch
        // domain under XCTest. Naming `.standard` here used to be right and is
        // now a wipe of a key nothing in the run ever wrote.
        for key in ["aibars.opencode#unit-test.enabled", "aibars.opencode#unit-test.dismissed"] {
            AppDefaults.current.removeObject(forKey: key)
        }
    }

    // MARK: - The Go caps

    func testTheGoKeyDrawsTheThreePublishedCaps() throws {
        let rows = [
            // The anchor, and old enough to be outside every window below.
            try message("2026-06-20T09:30:00Z", cost: 6, tokens: 100),
            try message("2026-08-09T23:00:00Z", cost: 10, tokens: 200),
            try message("2026-08-10T08:00:00Z", cost: 7, tokens: 300),
            try message("2026-08-12T12:00:00Z", cost: 4, tokens: 400),
            try message("2026-08-12T14:00:00Z", cost: 5, tokens: 500)
        ]

        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now)

        XCTAssertEqual(data.providerID, "opencode")
        XCTAssertEqual(data.fetchedAt, now)
        XCTAssertEqual(data.planName, "Go")
        // Not an account name: these figures are one machine's view of a
        // subscription, and the reader has to be told which machine.
        XCTAssertEqual(data.accountLabel, "this Mac")
        XCTAssertEqual(metrics(data).prefix(3).map(\.label), ["Session", "Weekly", "Monthly"])

        let session = try XCTUnwrap(metric(data, "Session"))
        XCTAssertEqual(session.used, 9, accuracy: 0.0001)
        XCTAssertEqual(session.limit, 12)
        XCTAssertEqual(session.unit, "USD")
        XCTAssertEqual(session.windowLabel, "5h")
        XCTAssertEqual(session.percent, 0.75, accuracy: 0.0001)
        // A rolling window does not reset; the first moment the figure can fall
        // is when its oldest charge ages out.
        XCTAssertEqual(session.resetDate, try date("2026-08-12T17:00:00Z"))

        let weekly = try XCTUnwrap(metric(data, "Weekly"))
        XCTAssertEqual(weekly.used, 16, accuracy: 0.0001)
        XCTAssertEqual(weekly.limit, 30)
        XCTAssertEqual(weekly.windowLabel, "Week")
        XCTAssertEqual(weekly.resetDate, try date("2026-08-17T00:00:00Z"))

        let monthly = try XCTUnwrap(metric(data, "Monthly"))
        XCTAssertEqual(monthly.used, 26, accuracy: 0.0001)
        XCTAssertEqual(monthly.limit, 60)
        XCTAssertEqual(monthly.windowLabel, "Month")
        // Anchored to the 20th, the day of the earliest Go message.
        XCTAssertEqual(monthly.resetDate, try date("2026-08-20T00:00:00Z"))

        let spend = try XCTUnwrap(metric(data, "last 30 days", unit: "USD"))
        XCTAssertEqual(spend.used, 26, accuracy: 0.0001)
        let tokens = try XCTUnwrap(metric(data, "last 30 days", unit: "tokens"))
        XCTAssertEqual(tokens.used, 1_400, accuracy: 0.5)

        let raw = try summary(data)
        XCTAssertEqual(raw["messages"] as? Int, 5)
        XCTAssertEqual(raw["goMessages"] as? Int, 5)
        XCTAssertEqual(raw["capsShown"] as? Bool, true)
    }

    func testWithoutTheGoKeyThereAreNoCapMetersAtAll() throws {
        let rows = [
            try message("2026-08-12T12:00:00Z", cost: 4, provider: OpenCodeChannel.zen, tokens: 400),
            try message("2026-08-12T14:00:00Z", cost: 5, provider: OpenCodeChannel.zen, tokens: 500)
        ]

        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: false, now: now)

        XCTAssertEqual(data.planName, "Zen")
        for label in ["Session", "Weekly", "Monthly"] {
            XCTAssertNil(metric(data, label), "\(label) is a Go cap and this account has no Go")
        }
        // Prepaid credit has no ceiling, so nothing here may claim one. A cap
        // meter drawn at zero would be a limit the user does not have.
        for figure in metrics(data) {
            XCTAssertEqual(figure.limit, 0, "\(figure.label) invented a denominator")
            XCTAssertEqual(figure.percent, 0)
        }
        XCTAssertEqual(try XCTUnwrap(metric(data, "last 30 days", unit: "USD")).used, 9, accuracy: 0.0001)
    }

    func testZenSpendIsCountedButDoesNotFillTheGoCaps() throws {
        let rows = [
            try message("2026-08-12T12:00:00Z", cost: 4, tokens: 100),
            try message("2026-08-12T13:00:00Z", cost: 7, provider: OpenCodeChannel.zen, tokens: 900)
        ]

        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now)

        // The caps are the subscription's, and Zen is billed separately.
        XCTAssertEqual(try XCTUnwrap(metric(data, "Session")).used, 4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metric(data, "Weekly")).used, 4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metric(data, "Monthly")).used, 4, accuracy: 0.0001)
        // Spend is spend, whichever gateway charged it.
        XCTAssertEqual(try XCTUnwrap(metric(data, "last 30 days", unit: "USD")).used, 11, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metric(data, "last 30 days", unit: "tokens")).used, 1_000, accuracy: 0.5)
        XCTAssertEqual(try summary(data)["goMessages"] as? Int, 1)
    }

    /// The fallback that exists because this was written against a machine with
    /// Zen history and no Go login: if a subscriber's messages turn out to be
    /// recorded under the plain `opencode` id, the caps must still fill. It is
    /// gated on auth.json, so it can never reach a Zen-only account.
    func testGoRowsRecordedUnderTheZenIdStillFillTheCaps() throws {
        let rows = [
            try message("2026-08-12T12:00:00Z", cost: 4, provider: OpenCodeChannel.zen),
            try message("2026-08-12T14:00:00Z", cost: 5, provider: OpenCodeChannel.zen)
        ]

        let withKey = OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now)
        XCTAssertEqual(try XCTUnwrap(metric(withKey, "Session")).used, 9, accuracy: 0.0001)

        let withoutKey = OpenCodeUsageParser.parse(rows: rows, hasGo: false, now: now)
        XCTAssertNil(metric(withoutKey, "Session"), "the same rows must not fill caps without the key")
    }

    /// A lapsed subscriber keeps their history, so old Go rows alone must not
    /// bring the caps back. Usage inside the current cycle does.
    func testHistoricGoUsageAloneDoesNotRestoreTheCaps() throws {
        let lapsed = OpenCodeUsageParser.parse(
            rows: [try message("2026-02-03T09:00:00Z", cost: 40)],
            hasGo: false,
            now: now
        )
        XCTAssertNil(metric(lapsed, "Monthly"))
        // Nothing inside any reported period either, so the row falls back to
        // the sentence. The plan reads as Zen because that is all the remaining
        // history can be measured as: pay-as-you-go spend with no cap.
        XCTAssertEqual(lapsed.primary.label, "No spend recorded on this Mac")
        XCTAssertEqual(lapsed.planName, "Zen")

        let current = OpenCodeUsageParser.parse(
            rows: [try message("2026-08-12T14:00:00Z", cost: 2)],
            hasGo: false,
            now: now
        )
        XCTAssertEqual(current.planName, "Go")
        XCTAssertEqual(try XCTUnwrap(metric(current, "Monthly")).used, 2, accuracy: 0.0001)
    }

    /// The other side of "no card for an empty database": a subscription that
    /// exists but has not been used from this Mac has real caps at a real zero,
    /// and hiding them would hide the plan.
    func testAGoSubscriptionWithNoLocalUsageStillDrawsItsCaps() throws {
        let data = OpenCodeUsageParser.parse(rows: [], hasGo: true, now: now)

        XCTAssertEqual(data.planName, "Go")
        let session = try XCTUnwrap(metric(data, "Session"))
        XCTAssertEqual(session.used, 0)
        XCTAssertEqual(session.limit, 12)
        // Nothing has been charged, so nothing can age out yet.
        XCTAssertNil(session.resetDate)
        XCTAssertEqual(metrics(data).count, 3, "no spend tiles when there is no spend")
    }

    // MARK: - Window boundaries

    func testTheSessionWindowIncludesItsOwnEdgeAndNothingBefore() throws {
        let edge = now.addingTimeInterval(-5 * 3600)
        let rows = [
            OpenCodeMessage(createdAt: edge.addingTimeInterval(-1), providerID: OpenCodeChannel.go, cost: 8, tokens: 0),
            OpenCodeMessage(createdAt: edge, providerID: OpenCodeChannel.go, cost: 3, tokens: 0)
        ]

        let session = try XCTUnwrap(metric(OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now), "Session"))

        XCTAssertEqual(session.used, 3, accuracy: 0.0001)
        // The oldest charge in the window is exactly five hours old, so the
        // figure can first fall right now.
        XCTAssertEqual(session.resetDate, now)
    }

    func testTheWeeklyWindowStartsOnUtcMondayAndSundayNightIsThePreviousWeek() throws {
        let week = OpenCodeUsageParser.weeklyCycle(now: now)
        XCTAssertEqual(week.start, try date("2026-08-10T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(week.reset), try date("2026-08-17T00:00:00Z"))

        let rows = [
            try message("2026-08-09T23:00:00Z", cost: 10),   // Sunday night, UTC.
            try message("2026-08-10T00:00:00Z", cost: 3),    // The boundary itself.
            try message("2026-08-12T14:00:00Z", cost: 2)
        ]
        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now)

        XCTAssertEqual(try XCTUnwrap(metric(data, "Weekly")).used, 5, accuracy: 0.0001)
        // The Sunday row is not lost, only in a different window: the cycle is
        // anchored on the 9th, so the month still holds all three.
        XCTAssertEqual(try XCTUnwrap(metric(data, "Monthly")).used, 15, accuracy: 0.0001)
    }

    func testTheWeekTurnsOverAtMidnightUtcAndNotAMomentEarlier() throws {
        let monday = try date("2026-08-10T00:00:00Z")
        let onTheHour = OpenCodeUsageParser.weeklyCycle(now: monday)
        XCTAssertEqual(onTheHour.start, monday, "a week beginning now is this week, not last")
        XCTAssertEqual(try XCTUnwrap(onTheHour.reset), try date("2026-08-17T00:00:00Z"))

        let secondBefore = OpenCodeUsageParser.weeklyCycle(now: monday.addingTimeInterval(-1))
        XCTAssertEqual(secondBefore.start, try date("2026-08-03T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(secondBefore.reset), monday)
    }

    func testTheMonthlyCycleIsAnchoredToTheDayOfFirstGoUse() throws {
        let cycle = OpenCodeUsageParser.monthlyCycle(anchor: try date("2026-06-20T09:30:00Z"), now: now)

        // The 20th has not come round yet in August, so the current cycle began
        // on the 20th of July — not on the 1st of anything.
        XCTAssertEqual(cycle.start, try date("2026-07-20T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(cycle.reset), try date("2026-08-20T00:00:00Z"))

        // Past the anchor day, the cycle is the current month's.
        let later = OpenCodeUsageParser.monthlyCycle(
            anchor: try date("2026-06-20T09:30:00Z"),
            now: try date("2026-08-25T06:00:00Z")
        )
        XCTAssertEqual(later.start, try date("2026-08-20T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(later.reset), try date("2026-09-20T00:00:00Z"))

        // Standing exactly on the turnover: today is the new cycle, not the old.
        let onTheDay = OpenCodeUsageParser.monthlyCycle(
            anchor: try date("2026-06-17T09:30:00Z"),
            now: try date("2026-08-17T00:00:00Z")
        )
        XCTAssertEqual(onTheDay.start, try date("2026-08-17T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(onTheDay.reset), try date("2026-09-17T00:00:00Z"))
    }

    func testAnAnchorOnThe31stStillTurnsOverInFebruary() throws {
        let cycle = OpenCodeUsageParser.monthlyCycle(
            anchor: try date("2026-01-31T00:00:00Z"),
            now: try date("2026-02-28T12:00:00Z")
        )

        // February has no 31st, so the cycle clamps to its last day rather than
        // rolling into March and swallowing a month of spend.
        XCTAssertEqual(cycle.start, try date("2026-02-28T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(cycle.reset), try date("2026-03-31T00:00:00Z"))
    }

    func testWithNoGoHistoryTheCycleFallsBackToTheFirstOfTheMonth() throws {
        let cycle = OpenCodeUsageParser.monthlyCycle(anchor: nil, now: now)

        XCTAssertEqual(cycle.start, try date("2026-08-01T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(cycle.reset), try date("2026-09-01T00:00:00Z"))
    }

    // MARK: - The day tiles

    func testTheDayTilesSplitOnLocalMidnight() throws {
        // Derived from the user's own calendar rather than a fixed UTC time:
        // "today" is a question about where the user is, and this test must
        // give the same answer in every time zone the suite runs in.
        let dayStart = Calendar.current.startOfDay(for: now)
        let rows = [
            OpenCodeMessage(createdAt: dayStart.addingTimeInterval(-1), providerID: OpenCodeChannel.zen, cost: 3, tokens: 10),
            OpenCodeMessage(createdAt: dayStart, providerID: OpenCodeChannel.zen, cost: 2, tokens: 20)
        ]

        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: false, now: now)

        // Midnight itself belongs to the day it opens.
        XCTAssertEqual(try XCTUnwrap(metric(data, "today")).used, 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metric(data, "yesterday")).used, 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metric(data, "last 30 days", unit: "USD")).used, 5, accuracy: 0.0001)
    }

    func testAnEmptyDayIsLeftOutRatherThanShownAsZero() throws {
        let dayStart = Calendar.current.startOfDay(for: now)
        let rows = [
            OpenCodeMessage(createdAt: dayStart, providerID: OpenCodeChannel.zen, cost: 2, tokens: 0)
        ]

        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: false, now: now)

        XCTAssertNotNil(metric(data, "today"))
        // $0 yesterday reads as a measured zero when it is really no data.
        XCTAssertNil(metric(data, "yesterday"))
        // No tokens counted on any row, so no token figure either.
        XCTAssertNil(metric(data, "last 30 days", unit: "tokens"))
    }

    func testSpendIsReportedToTheCentAndSubHalfCentSpendIsNotReportedAtAll() throws {
        let dayStart = Calendar.current.startOfDay(for: now)
        let rounded = OpenCodeUsageParser.parse(
            rows: [
                OpenCodeMessage(createdAt: dayStart, providerID: OpenCodeChannel.zen, cost: 0.005, tokens: 0),
                OpenCodeMessage(createdAt: dayStart, providerID: OpenCodeChannel.zen, cost: 0.004, tokens: 0)
            ],
            hasGo: false,
            now: now
        )
        XCTAssertEqual(try XCTUnwrap(metric(rounded, "today")).used, 0.01, accuracy: 0.000_001)

        // Rounds to nothing, so there is nothing to say. The row falls back to
        // the sentence rather than showing "$0.00 today".
        let dust = OpenCodeUsageParser.parse(
            rows: [OpenCodeMessage(createdAt: dayStart, providerID: OpenCodeChannel.zen, cost: 0.001, tokens: 0)],
            hasGo: false,
            now: now
        )
        XCTAssertNil(metric(dust, "today"))
        XCTAssertEqual(dust.primary.label, "No spend recorded on this Mac")
        // Rows were seen, even if they rounded away, so the plan is still named.
        XCTAssertEqual(dust.planName, "Zen")
    }

    // MARK: - Nothing, and nonsense

    func testNoMessagesProducesASentenceRatherThanAZeroedMeter() throws {
        let data = OpenCodeUsageParser.parse(rows: [], hasGo: false, now: now)

        XCTAssertEqual(data.primary.label, "No spend recorded on this Mac")
        XCTAssertEqual(data.primary.used, 0)
        // No unit and no ceiling: a state, not a quota. "Reports nothing" has to
        // stay distinguishable from "is at 0%".
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertNil(data.primary.unit)
        XCTAssertNil(data.primary.resetDate)
        XCTAssertTrue(data.secondary.isEmpty)
        XCTAssertNil(data.planName)
        XCTAssertEqual(try summary(data)["messages"] as? Int, 0)
    }

    func testRowsFromOtherVendorsAreNotOpenCodeSpend() throws {
        let rows = [
            try message("2026-08-12T14:00:00Z", cost: 4),
            try message("2026-08-12T14:01:00Z", cost: 99, provider: "minimax"),
            // Close enough to pass the reader's LIKE filter, not close enough
            // to be one of OpenCode's own gateways.
            try message("2026-08-12T14:02:00Z", cost: 99, provider: "opencode-next"),
            try message("2026-08-12T14:03:00Z", cost: 99, provider: "")
        ]

        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now)

        XCTAssertEqual(try XCTUnwrap(metric(data, "Session")).used, 4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metric(data, "last 30 days", unit: "USD")).used, 4, accuracy: 0.0001)
        XCTAssertEqual(try summary(data)["messages"] as? Int, 1)
    }

    func testRowsInAnyOrderProduceTheSameWindows() throws {
        let rows = [
            try message("2026-08-12T14:00:00Z", cost: 5),
            try message("2026-06-20T09:30:00Z", cost: 6),
            try message("2026-08-12T12:00:00Z", cost: 4)
        ]

        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now)

        // The anchor is the earliest row, wherever it arrived in the array, and
        // the session's reset comes off the oldest charge still in the window.
        XCTAssertEqual(try XCTUnwrap(metric(data, "Monthly")).resetDate, try date("2026-08-20T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(metric(data, "Session")).resetDate, try date("2026-08-12T17:00:00Z"))
    }

    /// The database is untrusted input: it is written by another program and a
    /// user can edit it. A figure that cannot be drawn must not be drawn.
    func testNegativeAndNonFiniteCostsCannotProduceAMeter() throws {
        let negative = OpenCodeUsageParser.parse(
            rows: [OpenCodeMessage(createdAt: now.addingTimeInterval(-60), providerID: OpenCodeChannel.go, cost: -5, tokens: 0)],
            hasGo: true,
            now: now
        )
        let session = try XCTUnwrap(metric(negative, "Session"))
        XCTAssertEqual(session.used, -5, accuracy: 0.0001)
        // Negative spend is not a negative bar, and a negative day tile is not
        // shown at all.
        XCTAssertEqual(session.percent, 0)
        XCTAssertNil(metric(negative, "today"))
        XCTAssertNil(metric(negative, "last 30 days", unit: "USD"))

        let poisoned = OpenCodeUsageParser.parse(
            rows: [
                OpenCodeMessage(createdAt: now.addingTimeInterval(-60), providerID: OpenCodeChannel.go, cost: .infinity, tokens: 0),
                OpenCodeMessage(createdAt: now.addingTimeInterval(-30), providerID: OpenCodeChannel.go, cost: 5, tokens: 0)
            ],
            hasGo: true,
            now: now
        )
        // One unusable row refuses the whole sum rather than rendering as a
        // blank or a full bar; `Int(NaN)` traps at the call sites.
        let refused = try XCTUnwrap(metric(poisoned, "Session"))
        XCTAssertEqual(refused.used, 0)
        XCTAssertTrue(refused.used.isFinite)
        XCTAssertEqual(refused.percent, 0)
    }

    // MARK: - One billed message

    func testDecodesTheVerifiedMessageShape() throws {
        let created = try date("2026-08-12T14:00:00Z")
        let json = assistantJSON(
            provider: OpenCodeChannel.zen,
            cost: "0.0051474",
            createdMilliseconds: milliseconds(created),
            input: 26, output: 347, reasoning: 0, cacheRead: 78_720, cacheWrite: 0
        )

        let message = try XCTUnwrap(OpenCodeMessage.decode(dataColumn: json, createdAt: .distantPast))

        XCTAssertEqual(message.providerID, OpenCodeChannel.zen)
        XCTAssertEqual(message.cost, 0.0051474, accuracy: 0.000_000_1)
        // `tokens.total` is absent on some rows and the parts are present on
        // all of them, so the parts are what is added up.
        XCTAssertEqual(message.tokens, 79_093)
        // `time.created` wins over the column when it is there.
        XCTAssertEqual(message.createdAt, created)
    }

    func testFallsBackToTheColumnTimestampWhenTheJsonHasNoTime() throws {
        let column = try date("2026-08-12T14:00:00Z")
        let json = assistantJSON(provider: OpenCodeChannel.go, cost: "1", createdMilliseconds: nil)

        let message = try XCTUnwrap(OpenCodeMessage.decode(dataColumn: json, createdAt: column))

        // The column is declared NOT NULL; the JSON field is not.
        XCTAssertEqual(message.createdAt, column)
    }

    func testMessagesThatWereNotBilledOrCannotBeAttributedAreDropped() {
        let created = milliseconds(now)
        // A user turn carries no cost and no provider.
        XCTAssertNil(OpenCodeMessage.decode(
            dataColumn: "{\"role\":\"user\",\"providerID\":\"opencode\"}", createdAt: now
        ))
        // No provider at all, and a provider that is only an empty string.
        XCTAssertNil(OpenCodeMessage.decode(
            dataColumn: "{\"role\":\"assistant\",\"cost\":1}", createdAt: now
        ))
        XCTAssertNil(OpenCodeMessage.decode(
            dataColumn: assistantJSON(provider: "", cost: "1", createdMilliseconds: created), createdAt: now
        ))
        // Malformed persisted data: a truncated write, an empty column, a JSON
        // document that is not an object.
        XCTAssertNil(OpenCodeMessage.decode(dataColumn: "{\"role\":\"assist", createdAt: now))
        XCTAssertNil(OpenCodeMessage.decode(dataColumn: "", createdAt: now))
        XCTAssertNil(OpenCodeMessage.decode(dataColumn: "[]", createdAt: now))
        XCTAssertNil(OpenCodeMessage.decode(dataColumn: "null", createdAt: now))
    }

    func testUnusableNumbersDecodeToZeroRatherThanPoisoningTheSum() throws {
        // `Double("nan")` parses, so a string cost has to be checked after it is
        // coerced rather than trusted for having been a number at all.
        let notANumber = try XCTUnwrap(OpenCodeMessage.decode(
            dataColumn: assistantJSON(provider: OpenCodeChannel.zen, cost: "\"nan\"", createdMilliseconds: milliseconds(now)),
            createdAt: now
        ))
        XCTAssertEqual(notANumber.cost, 0)

        let infiniteTokens = try XCTUnwrap(OpenCodeMessage.decode(
            dataColumn: """
            {"role":"assistant","cost":"0.25","providerID":"opencode",\
            "tokens":{"input":"inf","output":12}}
            """,
            createdAt: now
        ))
        XCTAssertEqual(infiniteTokens.tokens, 0)
        // Money arriving as a string is ordinary and still counts.
        XCTAssertEqual(infiniteTokens.cost, 0.25, accuracy: 0.000_001)

        // A missing cost is zero, not a refusal: the message was still billed
        // through OpenCode and its tokens are real.
        let noCost = try XCTUnwrap(OpenCodeMessage.decode(
            dataColumn: "{\"role\":\"assistant\",\"providerID\":\"opencode-go\",\"tokens\":{\"output\":5}}",
            createdAt: now
        ))
        XCTAssertEqual(noCost.cost, 0)
        XCTAssertEqual(noCost.tokens, 5)
    }

    /// Decoding does not decide which gateway a row belongs to — the caller
    /// does. This keeps the two jobs separable and is why a third-party row can
    /// survive the decode and still be dropped by the reader.
    func testDecodingKeepsThirdPartyRowsForTheCallerToReject() throws {
        let json = assistantJSON(provider: "minimax", cost: "2", createdMilliseconds: milliseconds(now))

        let message = try XCTUnwrap(OpenCodeMessage.decode(dataColumn: json, createdAt: now))

        XCTAssertEqual(message.providerID, "minimax")
        XCTAssertFalse(OpenCodeChannel.isHosted(message.providerID))
        XCTAssertTrue(OpenCodeChannel.isHosted(OpenCodeChannel.go))
        XCTAssertTrue(OpenCodeChannel.isHosted(OpenCodeChannel.zen))
        XCTAssertFalse(OpenCodeChannel.isGo(OpenCodeChannel.zen))
    }

    // MARK: - auth.json

    func testOnlyAnOauthEntryCountsAsASubscription() {
        XCTAssertTrue(OpenCodeUsageParser.hasGoSubscription(
            authJSON: Data("{\"opencode\":{\"type\":\"oauth\",\"access\":\"a\",\"refresh\":\"r\"}}".utf8)
        ))
        // A pasted Zen key lives under the same id. Calling that a subscription
        // would put three cap meters on an account that has none.
        XCTAssertFalse(OpenCodeUsageParser.hasGoSubscription(
            authJSON: Data("{\"opencode\":{\"type\":\"api\",\"key\":\"sk-1\"}}".utf8)
        ))
        XCTAssertFalse(OpenCodeUsageParser.hasGoSubscription(
            authJSON: Data("{\"anthropic\":{\"type\":\"oauth\"}}".utf8)
        ))
        XCTAssertFalse(OpenCodeUsageParser.hasGoSubscription(authJSON: Data("{}".utf8)))
        // Malformed or unexpected shapes are "no Go", never a crash.
        XCTAssertFalse(OpenCodeUsageParser.hasGoSubscription(authJSON: Data()))
        XCTAssertFalse(OpenCodeUsageParser.hasGoSubscription(authJSON: Data("[]".utf8)))
        XCTAssertFalse(OpenCodeUsageParser.hasGoSubscription(authJSON: Data("{\"opencode\":\"oauth\"}".utf8)))
        XCTAssertFalse(OpenCodeUsageParser.hasGoSubscription(authJSON: Data("not json at all".utf8)))
    }

    func testTheSubscriptionIsReadFromAuthJsonBesideTheDatabase() throws {
        XCTAssertFalse(
            OpenCodeProvider.hasGoSubscription(in: directory),
            "no auth.json can only mean no Go, and Zen still stands on its own"
        )

        try Data("{\"opencode\":{\"type\":\"oauth\",\"access\":\"a\"}}".utf8)
            .write(to: directory.appendingPathComponent("auth.json"))

        XCTAssertTrue(OpenCodeProvider.hasGoSubscription(in: directory))
    }

    // MARK: - Where the files are

    func testDataDirectoryPrefersTheExplicitOverrideThenXdg() throws {
        XCTAssertEqual(
            OpenCodeProvider.dataDirectory(
                environment: ["OPENCODE_DATA_DIR": "/opt/oc", "XDG_DATA_HOME": "/ignored"],
                home: URL(fileURLWithPath: "/Users/nobody")
            ).path,
            "/opt/oc"
        )
        XCTAssertEqual(
            OpenCodeProvider.dataDirectory(
                environment: ["XDG_DATA_HOME": "/var/data"],
                home: URL(fileURLWithPath: "/Users/nobody")
            ).path,
            "/var/data/opencode"
        )
        XCTAssertEqual(
            OpenCodeProvider.dataDirectory(environment: [:], home: URL(fileURLWithPath: "/Users/nobody")).path,
            "/Users/nobody/.local/share/opencode"
        )
        // An exported-but-empty variable is not a setting.
        XCTAssertEqual(
            OpenCodeProvider.dataDirectory(
                environment: ["OPENCODE_DATA_DIR": "", "XDG_DATA_HOME": ""],
                home: URL(fileURLWithPath: "/Users/nobody")
            ).path,
            "/Users/nobody/.local/share/opencode"
        )
        // A tilde in the environment is a path the shell never expanded.
        let expanded = OpenCodeProvider.dataDirectory(
            environment: ["OPENCODE_DATA_DIR": "~/oc"],
            home: URL(fileURLWithPath: "/Users/nobody")
        ).path
        XCTAssertFalse(expanded.contains("~"))
        XCTAssertTrue(expanded.hasSuffix("/oc"))
    }

    func testEveryChannelDatabaseIsFoundAndNoSidecarIs() throws {
        for name in [
            "opencode.db", "opencode-next.db", "opencode.db-wal", "opencode.db-shm",
            "opencode.json", "other.db", "auth.json"
        ] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        XCTAssertEqual(
            OpenCodeProvider.databases(in: directory).map(\.lastPathComponent),
            ["opencode-next.db", "opencode.db"]
        )
        // A directory OpenCode has never written is not an error here; the
        // caller turns "nothing to read" into the sentence the user sees.
        XCTAssertTrue(OpenCodeProvider.databases(in: directory.appendingPathComponent("missing")).isEmpty)
    }

    // MARK: - Reading a real database

    func testReadsAMessageDatabaseBuiltToTheVerifiedSchema() async throws {
        let created = try date("2026-08-12T14:00:00Z")
        let database = try makeDatabase(named: "opencode.db", rows: [
            (id: "m1", created: created, data: assistantJSON(
                provider: OpenCodeChannel.go, cost: "1.5", createdMilliseconds: milliseconds(created),
                input: 10, output: 20, reasoning: 5, cacheRead: 0, cacheWrite: 0
            ))
        ])

        let rows = try await OpenCodeReader().rows(in: [database], since: .distantPast)

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.providerID, OpenCodeChannel.go)
        XCTAssertEqual(row.cost, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(row.tokens, 35)
        XCTAssertEqual(row.createdAt, created)
    }

    func testTheTwoChannelDatabasesAreReadAsOneHistory() async throws {
        let stable = try date("2026-08-12T12:00:00Z")
        let next = try date("2026-08-12T14:00:00Z")
        let databases = [
            try makeDatabase(named: "opencode.db", rows: [
                (id: "s1", created: stable, data: assistantJSON(
                    provider: OpenCodeChannel.go, cost: "4", createdMilliseconds: milliseconds(stable)
                ))
            ]),
            try makeDatabase(named: "opencode-next.db", rows: [
                (id: "n1", created: next, data: assistantJSON(
                    provider: OpenCodeChannel.zen, cost: "7", createdMilliseconds: milliseconds(next)
                ))
            ])
        ]

        let rows = try await OpenCodeReader().rows(in: databases, since: .distantPast)

        // Oldest first, whichever file it came out of: the windows downstream
        // read the first element to decide when a charge ages out.
        XCTAssertEqual(rows.map(\.providerID), [OpenCodeChannel.go, OpenCodeChannel.zen])
        XCTAssertEqual(rows.map(\.createdAt), [stable, next])

        // And the two channels compose into one row: the subscription cap sees
        // only its own charge, the spend figure sees both.
        let data = OpenCodeUsageParser.parse(rows: rows, hasGo: true, now: now)
        XCTAssertEqual(try XCTUnwrap(metric(data, "Session")).used, 4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(metric(data, "last 30 days", unit: "USD")).used, 11, accuracy: 0.0001)
    }

    func testRowsOutsideTheWindowAndRowsFromOtherVendorsNeverLeaveSqlite() async throws {
        let old = try date("2025-01-01T00:00:00Z")
        let recent = try date("2026-08-12T14:00:00Z")
        let database = try makeDatabase(named: "opencode.db", rows: [
            (id: "old", created: old, data: assistantJSON(
                provider: OpenCodeChannel.go, cost: "99", createdMilliseconds: milliseconds(old)
            )),
            (id: "vendor", created: recent, data: assistantJSON(
                provider: "minimax", cost: "99", createdMilliseconds: milliseconds(recent)
            )),
            // Passes the LIKE filter on a prefix, fails the real check.
            (id: "lookalike", created: recent, data: assistantJSON(
                provider: "opencode-preview", cost: "99", createdMilliseconds: milliseconds(recent)
            )),
            (id: "user", created: recent, data: "{\"role\":\"user\",\"providerID\":\"opencode\"}"),
            (id: "torn", created: recent, data: "{\"role\":\"assist"),
            (id: "good", created: recent, data: assistantJSON(
                provider: OpenCodeChannel.zen, cost: "2", createdMilliseconds: milliseconds(recent)
            ))
        ])

        let rows = try await OpenCodeReader().rows(
            in: [database],
            since: try date("2026-08-01T00:00:00Z")
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try XCTUnwrap(rows.first).cost, 2, accuracy: 0.000_001)
    }

    func testAnEmptyDatabaseIsNoRowsRatherThanAFailure() async throws {
        let database = try makeDatabase(named: "opencode.db", rows: [])

        let rows = try await OpenCodeReader().rows(in: [database], since: .distantPast)

        XCTAssertTrue(rows.isEmpty)
        // And an empty history is a sentence, not a card of zeroes.
        XCTAssertEqual(
            OpenCodeUsageParser.parse(rows: rows, hasGo: false, now: now).primary.label,
            "No spend recorded on this Mac"
        )
    }

    func testARenamedColumnFailsLoudlyInsteadOfReportingZero() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        try withDatabase(at: database) { handle in
            // The same table with `data` renamed: exactly what an OpenCode
            // migration would look like from here.
            exec(handle, """
            CREATE TABLE `message` (
              `id` text PRIMARY KEY, `session_id` text NOT NULL,
              `time_created` integer NOT NULL, `time_updated` integer NOT NULL,
              `payload` text NOT NULL);
            """)
        }

        await assertThrowsConfiguration {
            _ = try await OpenCodeReader().rows(in: [database], since: .distantPast)
        }
    }

    func testADatabaseWithoutTheMessageTableIsAlsoRefused() async throws {
        let database = directory.appendingPathComponent("opencode.db")
        try withDatabase(at: database) { handle in
            exec(handle, "CREATE TABLE `session` (`id` text PRIMARY KEY);")
        }

        await assertThrowsConfiguration {
            _ = try await OpenCodeReader().rows(in: [database], since: .distantPast)
        }
    }

    func testOneUnreadableChannelDoesNotBlankOutTheOther() async throws {
        let created = try date("2026-08-12T14:00:00Z")
        let broken = directory.appendingPathComponent("opencode-broken.db")
        try Data("this is not a database".utf8).write(to: broken)
        let good = try makeDatabase(named: "opencode.db", rows: [
            (id: "m1", created: created, data: assistantJSON(
                provider: OpenCodeChannel.go, cost: "3", createdMilliseconds: milliseconds(created)
            ))
        ])

        let rows = try await OpenCodeReader().rows(in: [broken, good], since: .distantPast)
        XCTAssertEqual(rows.count, 1, "a locked or corrupt channel must not hide the other")

        // With nothing readable at all, the first failure is thrown so the row
        // can say why instead of showing a silent zero.
        await assertThrowsConfiguration {
            _ = try await OpenCodeReader().rows(in: [broken], since: .distantPast)
        }
    }

    func testTheCacheIsGivenUpAsSoonAsOpenCodeWritesMore() async throws {
        let first = try date("2026-08-12T12:00:00Z")
        let database = try makeDatabase(named: "opencode.db", rows: [
            (id: "m1", created: first, data: assistantJSON(
                provider: OpenCodeChannel.go, cost: "1", createdMilliseconds: milliseconds(first)
            ))
        ])
        let reader = OpenCodeReader()
        let before = try await reader.rows(in: [database], since: .distantPast)
        XCTAssertEqual(before.count, 1)

        // Enough rows that the file grows by pages, not just by a timestamp:
        // the cache is keyed on size and mtime together.
        try withDatabase(at: database) { handle in
            for index in 0..<64 {
                let created = first.addingTimeInterval(Double(index) + 1)
                exec(handle, insert(
                    id: "later-\(index)",
                    created: created,
                    data: assistantJSON(
                        provider: OpenCodeChannel.go, cost: "0.5",
                        createdMilliseconds: milliseconds(created)
                    )
                ))
            }
        }

        let rows = try await reader.rows(in: [database], since: .distantPast)
        XCTAssertEqual(rows.count, 65, "a session's worth of new messages was served from a stale cache")
    }

    // MARK: - The provider shell

    func testSigningOutIsRememberedAndConnectingAgainClearsIt() async throws {
        let provider = OpenCodeProvider(accountID: "unit-test")
        XCTAssertEqual(provider.id, "opencode#unit-test")
        XCTAssertEqual(provider.serviceID, "opencode")

        try await provider.signOut()
        XCTAssertFalse(provider.isAuthenticated)
        // A file cannot be un-written, so the choice has to survive a relaunch
        // on its own key: a fresh instance must still be signed out.
        XCTAssertFalse(OpenCodeProvider(accountID: "unit-test").isAuthenticated)

        do {
            try await provider.authenticate()
        } catch {
            // Whether this machine has an OpenCode database is not the point;
            // clearing the dismissal is, and that happens either way.
        }
        XCTAssertFalse(AppDefaults.current.bool(forKey: "aibars.opencode#unit-test.dismissed"))
    }

    func testPastingATokenIsRefusedWithSomewhereToLook() {
        let provider = OpenCodeProvider(accountID: "unit-test")

        XCTAssertThrowsError(try provider.saveTokenManually("sk-anything")) { error in
            guard case ProviderError.configuration(let message) = error else {
                return XCTFail("expected a configuration error, got \(error)")
            }
            // There is no credential to paste, so the message has to say what
            // aibars reads instead.
            XCTAssertTrue(message.contains("opencode"), message)
        }
    }

    // MARK: - Helpers

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ProviderDate.parse(iso), "\(iso) is not a date")
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func message(
        _ iso: String,
        cost: Double,
        provider: String = OpenCodeChannel.go,
        tokens: Int = 0
    ) throws -> OpenCodeMessage {
        OpenCodeMessage(createdAt: try date(iso), providerID: provider, cost: cost, tokens: tokens)
    }

    private func metrics(_ data: UsageData) -> [UsageMetric] {
        [data.primary] + data.secondary
    }

    /// Metrics are looked up by label because the order of the spend tiles
    /// depends on the time zone the suite runs in, and a test that pinned the
    /// index would pass in London and fail in Tokyo.
    private func metric(_ data: UsageData, _ label: String, unit: String? = nil) -> UsageMetric? {
        metrics(data).first { $0.label == label && (unit == nil || $0.unit == unit) }
    }

    private func summary(_ data: UsageData) throws -> [String: Any] {
        let encoded = try XCTUnwrap(data.rawJSON)
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        let object = try JSONSerialization.jsonObject(with: decoded)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// One `message.data` column in the shape the provider documents having
    /// read off a live database. `cost` is a raw JSON fragment so a test can
    /// hand it a string, a null, or something that is not a number at all.
    private func assistantJSON(
        provider: String,
        cost: String,
        createdMilliseconds: Int64?,
        input: Int = 26,
        output: Int = 347,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> String {
        let time = createdMilliseconds.map {
            ",\"time\":{\"created\":\($0),\"completed\":\($0 + 1200)}"
        } ?? ""
        return "{\"role\":\"assistant\",\"cost\":\(cost),\"providerID\":\"\(provider)\","
            + "\"modelID\":\"claude-sonnet-4-5\",\"sessionID\":\"ses_1\","
            + "\"tokens\":{\"input\":\(input),\"output\":\(output),\"reasoning\":\(reasoning),"
            + "\"cache\":{\"read\":\(cacheRead),\"write\":\(cacheWrite)}}"
            + time + "}"
    }

    /// The schema this whole provider depends on, typed out in full. If OpenCode
    /// migrates away from it, this fixture stops resembling the real file and
    /// the reader's tests fail here first — which is the point of building the
    /// database rather than stubbing the rows.
    private func makeDatabase(
        named name: String,
        rows: [(id: String, created: Date, data: String)]
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try withDatabase(at: url) { handle in
            exec(handle, """
            CREATE TABLE `message` (
              `id` text PRIMARY KEY, `session_id` text NOT NULL,
              `time_created` integer NOT NULL, `time_updated` integer NOT NULL,
              `data` text NOT NULL);
            """)
            for row in rows {
                exec(handle, insert(id: row.id, created: row.created, data: row.data))
            }
        }
        return url
    }

    private func insert(id: String, created: Date, data: String) -> String {
        let stamp = milliseconds(created)
        let escaped = data.replacingOccurrences(of: "'", with: "''")
        return "INSERT INTO `message` VALUES ('\(id)', 'ses_1', \(stamp), \(stamp), '\(escaped)');"
    }

    private func withDatabase(at url: URL, _ body: (OpaquePointer) -> Void) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        XCTAssertEqual(status, SQLITE_OK, "could not create \(url.lastPathComponent)")
        defer { sqlite3_close(handle) }
        body(try XCTUnwrap(handle))
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        if status != SQLITE_OK {
            XCTFail("\(sql) failed: \(error.map { String(cString: $0) } ?? "code \(status)")")
        }
        sqlite3_free(error)
    }

    private func assertThrowsConfiguration(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected a configuration error", file: file, line: line)
        } catch ProviderError.configuration(_) {
            // What the row needs: something it can say out loud.
        } catch {
            XCTFail("expected a configuration error, got \(error)", file: file, line: line)
        }
    }
}
