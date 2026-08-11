import XCTest
@testable import aibarsCore

/// A spend row is the one thing in the panel that looks like an invoice, so it
/// is held to an invoice's standard: the figure is exact, the ceiling is either
/// real or absent, and a cent is never invented on the way to the screen.
///
/// These tests are mostly about the refusals. Every wrong answer available here
/// is a plausible-looking one — an uncapped balance drawn as 0% of something, a
/// ceiling we failed to parse read as "no ceiling", a rate scaled by the wrong
/// power of ten — and each would be presented to the user with exactly as much
/// confidence as a correct one.
///
/// `SpendReport` is a value with no clock and no I/O, so there is nothing to
/// stub and nothing to tidy up.
final class SpendReportTests: XCTestCase {

    // MARK: - Builders

    private func usd(
        _ amountMinor: Int,
        limit: Int? = nil,
        exponent: Int = 2,
        period: SpendReport.Period = .month,
        confidence: SpendReport.Confidence = .measured,
        resetDate: Date? = nil
    ) -> SpendReport {
        SpendReport(
            amountMinor: amountMinor,
            currency: "USD",
            exponent: exponent,
            limitMinor: limit,
            period: period,
            confidence: confidence,
            resetDate: resetDate
        )
    }

    /// The style `display` is built from, so a test can state the fraction range
    /// it expects without also stating the currency symbol of whichever region
    /// the machine running it happens to be set to.
    private func formatted(
        _ value: Decimal,
        code: String = "USD",
        places: ClosedRange<Int>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(places)).locale(locale))
    }

    /// An expectation parsed from digits rather than written as a float literal.
    /// `Decimal` takes a float literal through a `Double`, which is the exact
    /// imprecision these tests exist to catch, so an expectation must not go
    /// that way itself. The locale is fixed because the literals here are typed
    /// with a point.
    private func decimal(_ literal: String) throws -> Decimal {
        try XCTUnwrap(Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")), literal)
    }

    /// Two readers who write the same amount differently. Neither is the machine
    /// running the test, which is the point of naming them.
    private let american = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    // MARK: - The amount

    func testMinorUnitsBecomeMajorUnitsExactly() throws {
        XCTAssertEqual(usd(3284).amount, try decimal("32.84"))
        XCTAssertEqual(usd(0).amount, 0)
        XCTAssertEqual(usd(1).amount, try decimal("0.01"))
        XCTAssertEqual(usd(4300, exponent: 6).amount, try decimal("0.0043"))
        XCTAssertEqual(usd(1234, exponent: 0).amount, 1234)
    }

    func testTheArithmeticIsDecimalRatherThanBinary() throws {
        // The whole reason the storage is integral: three dimes add to thirty
        // cents here and to 0.30000000000000004 in a Double, and a spend pane
        // adds these up before it prints them.
        let dime = usd(10).amount
        XCTAssertEqual(dime + dime + dime, try decimal("0.30"))

        let tenth = usd(10, exponent: 2).amount
        let fifth = usd(20, exponent: 2).amount
        XCTAssertEqual(tenth + fifth, try decimal("0.30"))
    }

    func testTheAmountSurvivesTheEndsOfItsOwnRange() {
        // A corrupt file can hold either of these. Neither may trap, and both
        // have to come out of the formatter as something printable.
        XCTAssertFalse(usd(.max, exponent: 9).display.isEmpty)
        XCTAssertFalse(usd(.min, exponent: 2).display.isEmpty)
        XCTAssertLessThan(usd(.min).amount, 0)
        XCTAssertGreaterThan(usd(.max).amount, 0)
    }

    // MARK: - Display

    func testCentsDisplayAsMajorUnitsToTwoPlaces() throws {
        let report = usd(3284)
        // Digits rather than the whole string, so this says nothing about the
        // region the test is running in: 3284 minor units is 32.84 major ones,
        // to two places, and no thousands digit has appeared from anywhere.
        XCTAssertEqual(report.display.filter(\.isNumber), "3284")
        XCTAssertEqual(report.display, formatted(try decimal("32.84"), places: 2...2))
        // And for an American reader, in full.
        XCTAssertEqual(formatted(try decimal("32.84"), places: 2...2, locale: american), "$32.84")
    }

    func testDisplayIsLocalisedRatherThanInterpolated() throws {
        // The same value and the same precision put through the same style for
        // two readers. An interpolated "\(major).\(minor)" would hand the German
        // one a decimal point, which is a different number in his notation.
        let here = formatted(try decimal("32.84"), places: 2...2, locale: american)
        let there = formatted(try decimal("32.84"), places: 2...2, locale: german)
        XCTAssertTrue(here.contains("."), here)
        XCTAssertFalse(here.contains(","), here)
        XCTAssertTrue(there.contains(","), there)
        XCTAssertFalse(there.contains("."), there)

        // And `display` is whichever of those the reader is owed, because it
        // states no separator of its own.
        XCTAssertEqual(usd(3284).display, formatted(try decimal("32.84"), places: 2...2))
    }

    func testASubUnitAmountKeepsThePlacesItsExponentAsksFor() throws {
        // A 0.43-cent API charge shown as $0.00 is a lie about zero, so the
        // extra places survive for exactly as long as they change the reading.
        XCTAssertEqual(usd(43, exponent: 3).display.filter(\.isNumber), "0043")
        XCTAssertEqual(usd(43, exponent: 3).display, formatted(try decimal("0.043"), places: 2...3))
        XCTAssertEqual(usd(4300, exponent: 6).display, formatted(try decimal("0.0043"), places: 2...6))
    }

    func testAnExponentAboveTwoStillReadsAsMoneyOnceTheAmountIsWholeUnits() throws {
        // Either side of the boundary that decides whether the extra places are
        // information or noise. Below one major unit they are the whole reading;
        // at and above it they are six digits nobody acts on.
        XCTAssertEqual(
            formatted(try decimal("0.999999"), places: 2...6, locale: american),
            "$0.999999"
        )
        XCTAssertEqual(usd(999_999, exponent: 6).display.filter(\.isNumber), "0999999")
        XCTAssertEqual(usd(1_000_000, exponent: 6).display.filter(\.isNumber), "100")
        XCTAssertEqual(usd(32_840, exponent: 3).display.filter(\.isNumber), "3284")
    }

    func testACurrencyWithNoMinorUnitShowsNoFraction() {
        // Yen has no cents, and two zeroes after a yen figure is not a rounding
        // choice, it is a unit that does not exist.
        let yen = SpendReport(
            amountMinor: 1234,
            currency: "JPY",
            exponent: 0,
            period: .month,
            confidence: .measured
        )
        XCTAssertEqual(yen.display.filter(\.isNumber), "1234")
        XCTAssertEqual(yen.display, formatted(1234, code: "JPY", places: 0...0))
    }

    func testZeroAndNegativeAmountsAreShownRatherThanSuppressed() {
        // A measured zero is an answer, and a credit balance is a real state of
        // an account. Both have to print.
        XCTAssertEqual(usd(0).display, formatted(0, places: 2...2))
        XCTAssertEqual(formatted(0, places: 2...2, locale: american), "$0.00")
        XCTAssertEqual(formatted(-1, places: 2...2, locale: american), "-$1.00")
        XCTAssertEqual(usd(-100).display.filter(\.isNumber), "100")
    }

    func testABlankCurrencyStillPrintsTheFigure() {
        // A report with no code should never have been built — the parsers treat
        // a missing currency as a parse failure — but one can come off disk, and
        // a formatter that returned nothing would erase the amount as well as
        // the symbol.
        let unnamed = SpendReport(
            amountMinor: 3284,
            currency: "   ",
            period: .month,
            confidence: .measured
        )
        XCTAssertEqual(unnamed.currency, "")
        XCTAssertEqual(unnamed.display.filter(\.isNumber), "3284")
    }

    // MARK: - Normalising what the initialiser is handed

    func testCurrencyIsTrimmedAndUpperCased() {
        XCTAssertEqual(
            SpendReport(amountMinor: 1, currency: " usd ", period: .day, confidence: .measured).currency,
            "USD"
        )
        XCTAssertEqual(
            SpendReport(amountMinor: 1, currency: "eur", period: .day, confidence: .measured).currency,
            "EUR"
        )
        // Which makes two spellings of one currency the same report, so a total
        // cannot be split in half by a provider that shouts and one that does not.
        XCTAssertEqual(
            SpendReport(amountMinor: 1, currency: "usd", period: .day, confidence: .measured),
            SpendReport(amountMinor: 1, currency: "USD", period: .day, confidence: .measured)
        )
    }

    func testExponentIsClampedToSomethingADecimalCanHold() {
        // Nine places is past any real minor unit; beyond it the amount stops
        // being a number rather than becoming a more precise one.
        XCTAssertEqual(usd(1, exponent: 12).exponent, 9)
        XCTAssertEqual(usd(1, exponent: .max).exponent, 9)
        XCTAssertEqual(usd(1, exponent: -3).exponent, 0)
        XCTAssertEqual(usd(1, exponent: .min).exponent, 0)

        // And the amount follows the exponent that was kept, not the one asked
        // for: a clamp that only moved the field would leave the money wrong.
        XCTAssertEqual(usd(1, exponent: -3).amount, 1)
        XCTAssertEqual(usd(1, exponent: 12).amount, usd(1, exponent: 9).amount)
    }

    func testTheDefaultExponentIsTwo() {
        // Every provider aibars reads bills in a two-place currency, so the
        // default is the common case and not a guess made per call site.
        XCTAssertEqual(
            SpendReport(amountMinor: 3284, currency: "USD", period: .month, confidence: .measured).exponent,
            2
        )
    }

    // MARK: - Percent

    func testAnUncappedReportHasNoPercent() {
        // Not 0 and not 1: both of those are readings, and this row was never
        // given anything to be a fraction of. A meter drawn from either would be
        // a made-up instrument.
        XCTAssertNil(usd(3284).percent)
        XCTAssertNil(usd(0).percent)
    }

    func testACappedPercentIsAmountOverLimit() throws {
        XCTAssertEqual(try XCTUnwrap(usd(2500, limit: 5000).percent), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(usd(1, limit: 4).percent), 0.25, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(usd(0, limit: 5000).percent), 0, accuracy: 1e-12)
    }

    func testPercentClampsAtTheCapAndNotBefore() throws {
        // Either side of full, then past it. Going over is real — a monthly API
        // bill can exceed the ceiling before the provider cuts it off — but the
        // meter this feeds is 0...1 and a value above it draws outside the track.
        XCTAssertEqual(try XCTUnwrap(usd(4999, limit: 5000).percent), 0.9998, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(usd(5000, limit: 5000).percent), 1)
        XCTAssertEqual(try XCTUnwrap(usd(5001, limit: 5000).percent), 1)
        XCTAssertEqual(try XCTUnwrap(usd(1_000_000, limit: 5000).percent), 1)
    }

    func testPercentClampsAtZeroForACreditBalance() throws {
        // An account in credit is below zero spent, not below zero of a meter.
        XCTAssertEqual(try XCTUnwrap(usd(-100, limit: 5000).percent), 0)
        XCTAssertEqual(try XCTUnwrap(usd(.min, limit: 5000).percent), 0)
    }

    func testACeilingOfZeroOrLessIsNotACeiling() {
        // Dividing by it is either a crash or an infinity, and "the limit is
        // zero" is not a fact any provider has ever meant to state.
        XCTAssertNil(usd(3284, limit: 0).percent)
        XCTAssertNil(usd(0, limit: 0).percent)
        XCTAssertNil(usd(3284, limit: -1).percent)
        XCTAssertNil(usd(3284, limit: .min).percent)
    }

    func testPercentStaysFiniteAtTheEndsOfIntAndInsideItsRange() throws {
        for report in [
            usd(.max, limit: 1),
            usd(.max, limit: .max),
            usd(.min, limit: .max),
            usd(1, limit: .max)
        ] {
            let percent = try XCTUnwrap(report.percent)
            XCTAssertTrue(percent.isFinite, "\(report.amountMinor)/\(report.limitMinor ?? 0) is \(percent)")
            XCTAssertTrue((0...1).contains(percent), "\(percent) is outside the meter")
        }
    }

    // MARK: - The parser's initialiser

    func testAnUnreadableCeilingPoisonsTheWholeReport() {
        // The one refusal that costs a row. Showing this spend with no ceiling,
        // next to a row whose ceiling parsed, reads as "this one is uncapped",
        // which is a claim the payload did not make.
        XCTAssertNil(
            SpendReport(
                amountMinor: 3284,
                currency: "USD",
                ceiling: .unreadable,
                period: .month,
                confidence: .measured
            )
        )
    }

    func testAnUncappedCeilingIsAReportWithNoLimit() throws {
        let report = try XCTUnwrap(
            SpendReport(
                amountMinor: 3284,
                currency: "USD",
                ceiling: .uncapped,
                period: .lifetime,
                confidence: .measured
            )
        )
        XCTAssertNil(report.limitMinor)
        XCTAssertNil(report.percent)
    }

    func testAReadCeilingBecomesTheLimitAndBothInitialisersAgree() throws {
        let parsed = try XCTUnwrap(
            SpendReport(
                amountMinor: 2500,
                currency: " usd ",
                exponent: 12,
                ceiling: .limit(5000),
                period: .month,
                confidence: .estimated
            )
        )
        XCTAssertEqual(parsed.limitMinor, 5000)
        XCTAssertEqual(try XCTUnwrap(parsed.percent), 0.5, accuracy: 1e-12)
        // The failable initialiser delegates rather than repeating itself, so
        // the trimming and the exponent clamp have to have happened here too.
        XCTAssertEqual(
            parsed,
            SpendReport(
                amountMinor: 2500,
                currency: "USD",
                exponent: 9,
                limitMinor: 5000,
                period: .month,
                confidence: .estimated
            )
        )
    }

    func testANonsenseCeilingIsKeptAndSimplyDoesNotMeasureAnything() throws {
        // `.limit(0)` is a ceiling the payload really did state. It is recorded
        // as given — inventing `nil` would lose the fact — and `percent` is
        // where the refusal lives.
        let report = try XCTUnwrap(
            SpendReport(
                amountMinor: 100,
                currency: "USD",
                ceiling: .limit(0),
                period: .day,
                confidence: .measured
            )
        )
        XCTAssertEqual(report.limitMinor, 0)
        XCTAssertNil(report.percent)
    }

    // MARK: - Equality

    func testTwoReportsDifferingOnlyInConfidenceAreNotEqual() {
        // The distinction the whole type exists to keep: one of these is the
        // provider's ledger and the other is arithmetic this app did. A row that
        // treated them as one value would present a guess as an invoice.
        let measured = usd(3284, confidence: .measured)
        let estimated = usd(3284, confidence: .estimated)
        XCTAssertNotEqual(measured, estimated)
        XCTAssertEqual(Set([measured, estimated]).count, 2)
    }

    func testIdenticalReportsAreEqualAndHashTogether() {
        let reset = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let one = usd(3284, limit: 5000, period: .rollingHours(720), resetDate: reset)
        let two = usd(3284, limit: 5000, period: .rollingHours(720), resetDate: reset)
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.hashValue, two.hashValue)
        XCTAssertEqual(Set([one, two]).count, 1)
    }

    func testEveryStoredFieldParticipatesInEquality() {
        let base = usd(3284, limit: 5000, period: .month, resetDate: nil)
        XCTAssertNotEqual(base, usd(3285, limit: 5000))
        XCTAssertNotEqual(base, usd(3284, limit: 5001))
        XCTAssertNotEqual(base, usd(3284))
        XCTAssertNotEqual(base, usd(3284, limit: 5000, exponent: 3))
        XCTAssertNotEqual(base, usd(3284, limit: 5000, period: .week))
        XCTAssertNotEqual(
            base,
            usd(3284, limit: 5000, resetDate: Date(timeIntervalSinceReferenceDate: 700_000_000))
        )
        XCTAssertNotEqual(
            base,
            SpendReport(amountMinor: 3284, currency: "EUR", limitMinor: 5000, period: .month, confidence: .measured)
        )
    }

    func testPeriodsAreDistinctFromEachOtherAndFromTheirLengths() {
        XCTAssertNotEqual(SpendReport.Period.rollingHours(24), .rollingHours(720))
        XCTAssertNotEqual(SpendReport.Period.rollingHours(24), .day)
        XCTAssertNotEqual(SpendReport.Period.day, .week)
        XCTAssertNotEqual(SpendReport.Period.month, .lifetime)
        XCTAssertEqual(SpendReport.Period.rollingHours(24), .rollingHours(24))
        XCTAssertEqual(Set([SpendReport.Period.day, .day, .week]).count, 2)
    }

    // MARK: - Codable

    func testEveryPeriodSurvivesARoundTrip() throws {
        let periods: [SpendReport.Period] = [
            .rollingHours(5), .rollingHours(24), .rollingHours(720), .day, .week, .month, .lifetime
        ]
        for period in periods {
            let report = usd(
                3284,
                limit: 5000,
                period: period,
                confidence: .estimated,
                resetDate: Date(timeIntervalSinceReferenceDate: 700_000_000)
            )
            let restored = try JSONDecoder().decode(SpendReport.self, from: JSONEncoder().encode(report))
            XCTAssertEqual(restored, report, "\(period)")
            XCTAssertEqual(restored.period, period)
        }
    }

    func testAPeriodIsWrittenAsANamedKindAndNotAsACompilerSpelling() throws {
        // `_0` is how the synthesised encoding spells an associated value, and
        // it is a detail of how the case is written today. A file on disk must
        // not depend on that surviving a rename.
        let period = try periodObject(of: usd(1, period: .rollingHours(24)))
        XCTAssertEqual(period["kind"] as? String, "rollingHours")
        XCTAssertEqual(period["hours"] as? Int, 24)
        XCTAssertEqual(Set(period.keys), ["kind", "hours"])
    }

    func testACalendarPeriodCarriesNoHours() throws {
        for period in [SpendReport.Period.day, .week, .month, .lifetime] {
            let written = try periodObject(of: usd(1, period: period))
            XCTAssertEqual(Set(written.keys), ["kind"], "\(period)")
        }
        XCTAssertEqual(try periodObject(of: usd(1, period: .lifetime))["kind"] as? String, "lifetime")
    }

    func testAbsentOptionalsAreWrittenAsAbsentRatherThanAsZero() throws {
        let written = try JSONEncoder().encode(usd(3284))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: written) as? [String: Any],
            "a report should encode as an object"
        )
        // A limit of null and a limit of zero read the same to a careless
        // decoder; neither may appear where there was no limit at all.
        XCTAssertNil(object["limitMinor"])
        XCTAssertNil(object["resetDate"])
        XCTAssertEqual(object["amountMinor"] as? Int, 3284)
        XCTAssertEqual(object["currency"] as? String, "USD")
        XCTAssertEqual(object["confidence"] as? String, "measured")
    }

    func testAReportWithNothingOptionalSurvivesARoundTrip() throws {
        let report = usd(0, period: .lifetime, confidence: .measured)
        let restored = try JSONDecoder().decode(SpendReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored, report)
        XCTAssertNil(restored.limitMinor)
        XCTAssertNil(restored.resetDate)
    }

    func testBothConfidencesSurviveARoundTrip() throws {
        for confidence in [SpendReport.Confidence.measured, .estimated] {
            let report = usd(3284, confidence: confidence)
            let restored = try JSONDecoder().decode(SpendReport.self, from: JSONEncoder().encode(report))
            XCTAssertEqual(restored.confidence, confidence)
        }
    }

    // MARK: - Helpers

    private func periodObject(of report: SpendReport) throws -> [String: Any] {
        let written = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        return try XCTUnwrap(object["period"] as? [String: Any], "a report must carry its period")
    }
}

/// Reports are persisted between launches, so they outlive the version that
/// wrote them and arrive as whatever an older shape, a half-finished write or a
/// hand-edited file left behind. A file is untrusted input like any other.
///
/// The contract these pin: a field that can be believed is clamped rather than
/// trusted, and a field that cannot be understood fails the decode rather than
/// being filled in. A spend row invented to keep a decode alive is a bill the
/// user never had, printed as confidently as a real one.
final class SpendReportPersistedInputTests: XCTestCase {

    private func decode(_ json: String) throws -> SpendReport {
        try JSONDecoder().decode(SpendReport.self, from: Data(json.utf8))
    }

    private func assertRefused(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), json, file: file, line: line)
    }

    // MARK: - What survives

    func testAWellFormedRecordDecodes() throws {
        let report = try decode("""
        {"amountMinor": 3284, "currency": "USD", "exponent": 2, "limitMinor": 5000,
         "period": {"kind": "rollingHours", "hours": 720},
         "confidence": "estimated", "resetDate": 700000000}
        """)
        XCTAssertEqual(report.amountMinor, 3284)
        XCTAssertEqual(report.limitMinor, 5000)
        XCTAssertEqual(report.period, .rollingHours(720))
        XCTAssertEqual(report.confidence, .estimated)
        XCTAssertEqual(report.resetDate, Date(timeIntervalSinceReferenceDate: 700_000_000))
        XCTAssertEqual(try XCTUnwrap(report.percent), 0.6568, accuracy: 1e-12)
    }

    func testAMissingOptionalDecodesAsNothingRatherThanAsZero() throws {
        let report = try decode("""
        {"amountMinor": 3284, "currency": "USD", "exponent": 2,
         "period": {"kind": "lifetime"}, "confidence": "measured"}
        """)
        XCTAssertNil(report.limitMinor)
        XCTAssertNil(report.resetDate)
        XCTAssertNil(report.percent)
    }

    func testAnExplicitNullReadsTheSameAsAnAbsentField() throws {
        let report = try decode("""
        {"amountMinor": 0, "currency": "USD", "exponent": 2, "limitMinor": null,
         "period": {"kind": "day"}, "confidence": "measured", "resetDate": null}
        """)
        XCTAssertNil(report.limitMinor)
        XCTAssertNil(report.resetDate)
    }

    func testKeysThisVersionDoesNotKnowAreIgnored() throws {
        // A file written by a later build has to stay readable by this one, or
        // a downgrade throws away the user's history.
        let report = try decode("""
        {"amountMinor": 3284, "currency": "USD", "exponent": 2,
         "period": {"kind": "month"}, "confidence": "measured",
         "providerID": "codex", "note": "hello", "limitMajor": 50}
        """)
        XCTAssertEqual(report.amountMinor, 3284)
        XCTAssertNil(report.limitMinor)
    }

    // MARK: - What is clamped

    func testAnExponentOffDiskIsClampedRatherThanTrusted() throws {
        // Decoding goes through the same clamping initialiser as everything
        // else, so a hand-edited exponent cannot push `Decimal` out of its own
        // range and turn the amount into something that is not a number.
        for (written, expected) in [(99, 9), (10, 9), (-4, 0), (0, 0), (6, 6)] {
            let report = try decode("""
            {"amountMinor": 1, "currency": "USD", "exponent": \(written),
             "period": {"kind": "day"}, "confidence": "measured"}
            """)
            XCTAssertEqual(report.exponent, expected, "exponent \(written)")
            XCTAssertFalse(report.display.isEmpty, "exponent \(written) printed nothing")
        }
    }

    func testACurrencyOffDiskIsNormalisedTheSameWayAsOneFromAParser() throws {
        let report = try decode("""
        {"amountMinor": 1, "currency": " usd ", "exponent": 2,
         "period": {"kind": "day"}, "confidence": "measured"}
        """)
        XCTAssertEqual(report.currency, "USD")
    }

    func testAnAbsurdAmountOffDiskStillProducesANumber() throws {
        let report = try decode("""
        {"amountMinor": 9223372036854775807, "currency": "USD", "exponent": 9,
         "limitMinor": 1, "period": {"kind": "lifetime"}, "confidence": "measured"}
        """)
        XCTAssertFalse(report.display.isEmpty)
        XCTAssertEqual(try XCTUnwrap(report.percent), 1)
    }

    func testARollingWindowKeepsWhateverLengthItWasGiven() throws {
        // Nothing divides by this: the hours name the window in a sentence and
        // are not a denominator. Rewriting a nonsense length would be inventing
        // a window the provider never described, so it is kept as written and
        // the sentence is the caller's problem.
        for hours in [0, -5, 1_000_000] {
            let report = try decode("""
            {"amountMinor": 1, "currency": "USD", "exponent": 2,
             "period": {"kind": "rollingHours", "hours": \(hours)}, "confidence": "measured"}
            """)
            XCTAssertEqual(report.period, .rollingHours(hours))
        }
    }

    // MARK: - What is refused

    func testAPeriodThisVersionCannotNameIsRefused() {
        // Not defaulted to `.month`. A lifetime total filed as a monthly one is
        // a number the user would read as this month's bill.
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "quarter"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": 5}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"hours": 24}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": "month", "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"rollingHours": {"_0": 24}}, "confidence": "measured"}"#)
    }

    func testARollingWindowWithoutItsHoursIsRefused() {
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "rollingHours"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "rollingHours", "hours": "24"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "rollingHours", "hours": null}, "confidence": "measured"}"#)
    }

    func testAConfidenceThisVersionCannotNameIsRefused() {
        // Defaulting an unknown confidence to `.measured` would promote a guess
        // written by some later build into the provider's own ledger.
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "day"}, "confidence": "guessed"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "day"}, "confidence": "Measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "day"}, "confidence": 0}"#)
    }

    func testAMissingRequiredFieldIsRefused() {
        assertRefused(#"{"currency": "USD", "exponent": 2, "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "exponent": 2, "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "day"}}"#)
        assertRefused("{}")
    }

    func testAFieldOfTheWrongTypeIsRefused() {
        assertRefused(#"{"amountMinor": "3284", "currency": "USD", "exponent": 2, "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 32.84, "currency": "USD", "exponent": 2, "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": 840, "exponent": 2, "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": "2", "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "limitMinor": "5000", "period": {"kind": "day"}, "confidence": "measured"}"#)
        assertRefused(#"{"amountMinor": 1, "currency": "USD", "exponent": 2, "period": {"kind": "day"}, "confidence": "measured", "resetDate": "tomorrow"}"#)
    }

    func testGarbageIsRefusedRatherThanCrashing() {
        assertRefused("not json at all")
        assertRefused("[]")
        assertRefused("null")
        assertRefused("[3284, \"USD\"]")
        assertRefused("")
    }

    // MARK: - Older files

    func testAUsageDataWrittenBeforeSpendExistedDecodesWithNoSpend() throws {
        // Snapshots are kept between launches, so files written by the build
        // before this feature are still on disk. The field is additive: an older
        // record decodes, and it reports no spend rather than a spend of zero.
        let older = """
        {"providerID": "claude", "fetchedAt": 700000000,
         "primary": {"label": "5h", "used": 42, "limit": 100},
         "secondary": []}
        """
        let data = try JSONDecoder().decode(UsageData.self, from: Data(older.utf8))
        XCTAssertNil(data.spend)
        XCTAssertEqual(data.providerID, "claude")
        XCTAssertEqual(data.primary.used, 42)
    }
}
