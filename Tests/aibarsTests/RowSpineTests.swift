import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// Whether a row spines, and why.
///
/// This is the whole of the bookmark's meaning — the view under it is a 2pt
/// capsule and has no opinion — so the decision is what has to be pinned. Two
/// things make it worth more than its size suggests. It is a ranking, and a
/// ranking is only correct at the pairs where two reasons are true at once; and
/// it is one of the three near-cap channels the design promises survive
/// greyscale, so "does this row spine" must not be answerable by looking at a
/// colour setting.
final class RowSpineReasonTests: XCTestCase {
    /// The shipped warning threshold. Named rather than repeated, because every
    /// boundary case below is stated as an offset from this one number.
    private let warning = 0.85

    private func reason(
        _ percent: Double? = nil,
        threshold: Double? = nil,
        error: ProviderError? = nil,
        connected: Bool = true
    ) -> SpineReason? {
        RowSpine.reason(
            percent: percent,
            warningThreshold: threshold ?? warning,
            error: error,
            isConnected: connected
        )
    }

    // MARK: - The quiet row

    /// The common case, and the one that decides whether the panel reads as a
    /// list or as a picket fence: nine healthy rows must carry no marks at all.
    func testAConnectedRowBelowTheWarningDoesNotSpine() {
        for percent in [0, 0.01, 0.25, 0.5, 0.6, 0.7, 0.84, 0.8499] {
            XCTAssertNil(reason(percent), "a row at \(percent) put a bookmark on a healthy service")
        }
    }

    /// A service that publishes a status and no quota has nothing to be near the
    /// cap of. The spine is not something to invent for it, and the row already
    /// says "connected" with its dot.
    func testAStatusOnlyServiceNeverSpines() {
        for threshold in [0.5, 0.85, 0.98] {
            XCTAssertNil(reason(nil, threshold: threshold), "threshold \(threshold)")
        }
    }

    // MARK: - The boundary

    /// Inclusive, and inclusive is the side that matters: the meter, the figure's
    /// weight and the fill's square end all turn on at exactly this value, and a
    /// spine that waited for the next float would leave one of the four near-cap
    /// channels disagreeing with the other three at the only percentage where
    /// the disagreement is visible.
    func testTheThresholdIsInclusive() {
        XCTAssertEqual(reason(warning), .nearCap, "85% is the warning, not the top of caution")
        XCTAssertNil(reason(warning.nextDown), "the float below the threshold spined")
        XCTAssertEqual(reason(warning.nextUp), .nearCap)
        XCTAssertEqual(reason(0.86), .nearCap)
        XCTAssertEqual(reason(1), .nearCap)
    }

    /// Providers do report past their own cap — an overage plan, or a limit that
    /// moved mid-window — and the row is not less near its cap for it.
    func testAReadingPastTheCapStillSpines() {
        for percent in [1.0001, 1.4, 12, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(reason(percent), .nearCap, "a row at \(percent) stopped spining")
        }
    }

    /// A negative reading is a parse that went wrong, not a row that is very
    /// empty. Either way it is nowhere near the cap and gets no mark.
    func testANegativePercentDoesNotSpine() {
        for percent in [-0.0, -0.0001, -0.5, -100, -Double.greatestFiniteMagnitude] {
            XCTAssertNil(reason(percent), "a row at \(percent) spined")
        }
    }

    /// Once a row spines for being near its cap it must not stop as the number
    /// climbs. A comparison written the wrong way round passes every fixed case
    /// above and fails somewhere in here.
    func testTheDecisionNeverUnwindsAsTheNumberClimbs() {
        for threshold in [0.5, 0.85, 0.98] {
            var seenNearCap = false
            for step in stride(from: -0.2, through: 1.5, by: 0.01) {
                let spined = reason(step, threshold: threshold) == .nearCap
                if spined { seenNearCap = true }
                if seenNearCap {
                    XCTAssertTrue(spined, "threshold \(threshold) stopped spining again at \(step)")
                }
                XCTAssertEqual(
                    spined, step >= threshold,
                    "threshold \(threshold) at \(step)"
                )
            }
        }
    }

    // MARK: - Untrusted numbers

    /// A percentage divided by a limit of zero is a NaN, and a NaN loses `>=`
    /// silently. The guard has to be written as a positive test of finiteness,
    /// which is what this pins: the answer is "no mark", not "a mark on every
    /// row that failed to divide".
    func testANonFinitePercentNeitherSpinesNorTraps() {
        for percent in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(reason(percent), "a percent of \(percent) produced a mark")
            XCTAssertNil(reason(percent, threshold: 0), "a percent of \(percent) against a zero threshold")
        }
    }

    /// The threshold comes out of `UserDefaults` by way of `AppearanceSettings`,
    /// which clamps it — but this function takes it as an argument and cannot
    /// know that the caller read it through the clamp. A threshold that cannot
    /// be compared against refuses the mark rather than handing one to every row
    /// in the panel.
    func testAMalformedThresholdRefusesRatherThanSpiningEveryRow() {
        for threshold in [Double.nan, .infinity, -.infinity] {
            for percent in [0, 0.5, 0.99, 1] {
                XCTAssertNil(
                    reason(percent, threshold: threshold),
                    "a threshold of \(threshold) spined a row at \(percent)"
                )
            }
        }
    }

    /// Finite and absurd is a different case from unusable. A threshold of zero
    /// says every reading is near the cap, and obeying the number given is the
    /// only reading that keeps this function agreeing with the meter and the
    /// figure, which obey it too.
    func testAFiniteButAbsurdThresholdIsObeyed() {
        XCTAssertEqual(reason(0, threshold: 0), .nearCap)
        XCTAssertEqual(reason(0, threshold: -1), .nearCap)
        XCTAssertNil(reason(1, threshold: 2))
        XCTAssertNil(reason(1, threshold: .greatestFiniteMagnitude))
    }

    // MARK: - The two state reasons

    /// Listed and empty is a decision waiting on the user, not a quiet row. The
    /// panel folds disconnected services into a disclosure group by default, so
    /// what reaches here is a row it has already chosen to show.
    func testARowWithNoCredentialAsksForTheUser() {
        XCTAssertEqual(reason(nil, connected: false), .needsUser)
        XCTAssertEqual(reason(0, connected: false), .needsUser)
        XCTAssertEqual(reason(0.1, connected: false), .needsUser)
    }

    /// An auth problem is not less urgent for being empty. A session that
    /// expired at 3% needs the same trip to Settings as one that expired at 93%,
    /// and the percentage is the one thing on the row that is now a lie.
    func testALockedOrExpiredRowSpinesEvenAtZero() {
        for error: ProviderError in [.notAuthenticated, .sessionExpired] {
            XCTAssertEqual(reason(0, error: error), .needsUser, "\(error) at zero")
            XCTAssertEqual(reason(nil, error: error), .needsUser, "\(error) with no reading")
            XCTAssertEqual(reason(0.5, error: error), .needsUser, "\(error) mid-window")
        }
    }

    /// `isAuth` is the provider's own line, and `blocked` and `rateLimited` stay
    /// on the failure side of it deliberately: a captive portal or a bot
    /// challenge is not a session the user has to go and repair, and telling
    /// them it is costs them a working credential.
    func testEveryErrorLandsOnTheSideItsOwnIsAuthPutsIt() {
        let cases: [(ProviderError, SpineReason)] = [
            (.notAuthenticated, .needsUser),
            (.sessionExpired, .needsUser),
            (.blocked("cf challenge"), .failed),
            (.rateLimited, .failed),
            (.network("timed out"), .failed),
            (.parse("no usage key"), .failed),
            (.unsupported, .failed),
            (.configuration("no team id"), .failed)
        ]
        for (error, expected) in cases {
            XCTAssertEqual(reason(0.5, error: error), expected, "\(error)")
            XCTAssertEqual(error.isAuth, expected == .needsUser, "\(error) disagrees with its own isAuth")
        }
    }

    /// An empty payload is a real outcome — a body that parsed to nothing, a
    /// URLSession error with no message — and it must not be read as "no error".
    /// The associated string is a thing to show the user, never the thing that
    /// decides whether there is a problem.
    func testAnErrorWithAnEmptyMessageStillCounts() {
        for error: ProviderError in [.blocked(""), .network(""), .parse(""), .configuration("")] {
            XCTAssertEqual(reason(0.1, error: error), .failed, "\(error)")
        }
    }

    // MARK: - The ranking

    /// One mark carries one meaning, so the three are ranked rather than
    /// combined. A row that is not answering has nothing true to say about how
    /// full it is, and the last percentage it reported is only getting staler.
    func testFailedOutranksNearCap() {
        XCTAssertEqual(reason(0.99, error: .network("timed out")), .failed)
        XCTAssertEqual(reason(1, error: .parse("bad json")), .failed)
    }

    func testNeedsUserOutranksNearCap() {
        XCTAssertEqual(reason(0.99, error: .sessionExpired), .needsUser)
        XCTAssertEqual(reason(0.99, connected: false), .needsUser)
    }

    /// An error is only ever set by an attempt, so it is the more specific of
    /// the two statements and wins over the connection flag either way round.
    func testAnErrorOutranksTheConnectionFlag() {
        XCTAssertEqual(reason(0.99, error: .network("offline"), connected: false), .failed)
        XCTAssertEqual(reason(nil, error: .sessionExpired, connected: false), .needsUser)
        XCTAssertEqual(reason(nil, error: .rateLimited, connected: true), .failed)
    }

    // MARK: - Independence from colour

    /// The greyscale invariant, made true rather than hoped for.
    ///
    /// A row asks two questions in order — whether to mark, and what colour the
    /// mark is — and only the second takes a ramp. `reason` has nowhere to get
    /// one from, and this is the call site that keeps it that way: threading a
    /// ramp into the decision would have to start here. What it asserts on top
    /// of that is the consequence the design promises — the same grid of rows
    /// marks identically whatever the panel's colour is set to, and every mark
    /// still has an ink under every ramp, so converting the panel to greyscale
    /// drains marks of hue without removing any.
    func testTheDecisionIsIndependentOfTheColourRamp() {
        let grid: [(Double?, ProviderError?, Bool)] = [
            (0, nil, true),
            (0.84, nil, true),
            (0.85, nil, true),
            (0.99, nil, true),
            (nil, nil, true),
            (nil, nil, false),
            (0.2, .sessionExpired, true),
            (0.99, .network("timed out"), true),
            (Double.nan, nil, true)
        ]
        let expected = grid.map { reason($0.0, error: $0.1, connected: $0.2) }
        XCTAssertEqual(expected.filter { $0 != nil }.count, 5, "the grid stopped covering all three reasons")

        for ramp in AppearanceSettings.ColorRamp.allCases {
            // In the order a row does it: decide, and only then ask for a
            // colour. Nothing the second call answers is allowed to reach back
            // into the first.
            let underRamp = grid.map { row -> SpineReason? in
                guard let reason = reason(row.0, error: row.1, connected: row.2) else { return nil }
                XCTAssertNotEqual(
                    RowSpine.ink(reason, ramp: ramp, tint: .red), Color.clear,
                    "\(reason) had no ink at all under \(ramp.rawValue)"
                )
                return reason
            }
            XCTAssertEqual(underRamp, expected, "the spine decision moved under \(ramp.rawValue)")
        }
    }
}

/// The ink the mark is drawn in.
///
/// Two rules, and they pull in opposite directions: `nearCap` must agree with
/// the meter beside it whatever the user set the ramp to, and the two state
/// reasons must not, because neither is a usage reading. The tint is passed in
/// as a loud sentinel that appears nowhere in the palette, so "did this defer to
/// the row's tint" is a fact rather than a guess — the state inks share their
/// hexes with the ramp's amber and red on purpose, and comparing against those
/// would prove nothing.
final class RowSpineInkTests: XCTestCase {
    /// Magenta at full chroma: not in the palette, not in any provider's brand
    /// mark, and not a colour any ramp can produce by accident.
    private let sentinel = Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1)

    private var colouredRamps: [AppearanceSettings.ColorRamp] {
        AppearanceSettings.ColorRamp.allCases.filter { $0 != .mono }
    }

    private let reasons: [SpineReason] = [.nearCap, .needsUser, .failed]

    // MARK: - Deferring, and refusing to

    /// The mark and the meter beside it are drawn from one reading of the
    /// settings, which is why the tint is an argument rather than something this
    /// resolves for itself.
    func testNearCapTakesTheRowsOwnTint() {
        for ramp in colouredRamps {
            XCTAssertEqual(
                RowSpine.ink(.nearCap, ramp: ramp, tint: sentinel), sentinel,
                "nearCap disagreed with the meter it is bookmarking under \(ramp.rawValue)"
            )
        }
    }

    /// The ramp is a rule about readings, and neither of these is a reading.
    func testTheStateReasonsIgnoreTheTintAndTakeTheStateInks() {
        for ramp in colouredRamps {
            XCTAssertEqual(RowSpine.ink(.needsUser, ramp: ramp, tint: sentinel), Tokens.Ink.attention, ramp.rawValue)
            XCTAssertEqual(RowSpine.ink(.failed, ramp: ramp, tint: sentinel), Tokens.Ink.failure, ramp.rawValue)
            XCTAssertNotEqual(RowSpine.ink(.needsUser, ramp: ramp, tint: sentinel), sentinel, ramp.rawValue)
            XCTAssertNotEqual(RowSpine.ink(.failed, ramp: ramp, tint: sentinel), sentinel, ramp.rawValue)
        }
    }

    /// The two state inks resolved, so that "amber and red" is a pair of hexes
    /// rather than a pair of words. These are the app's only two alarm hues and
    /// they have to stay apart in both appearances — amber against red is the
    /// worst discrimination there is in deuteranopia, and it is the pair a 2pt
    /// mark is asking a user to tell apart.
    func testTheStateInksAreTheRecordedHexesAndStayApart() throws {
        for dark in [false, true] {
            let attention = try XCTUnwrap(hex(RowSpine.ink(.needsUser, ramp: .usage, tint: sentinel), dark: dark))
            let failure = try XCTUnwrap(hex(RowSpine.ink(.failed, ramp: .usage, tint: sentinel), dark: dark))
            XCTAssertEqual(attention, dark ? 0xE0A200 : 0x8F6100, "attention on \(dark ? "dark" : "light")")
            XCTAssertEqual(failure, dark ? 0xEC5D62 : 0xC62A2F, "failure on \(dark ? "dark" : "light")")
            XCTAssertNotEqual(attention, failure, "the two alarm inks collapsed on \(dark ? "dark" : "light")")
        }
    }

    /// A 2pt mark has no contrast to give away, so nothing here is allowed to be
    /// a wash of its own.
    func testTheStateInksAreFullyOpaque() throws {
        for ramp in colouredRamps {
            for reason: SpineReason in [.needsUser, .failed] {
                for dark in [false, true] {
                    let alpha = try XCTUnwrap(alpha(RowSpine.ink(reason, ramp: ramp, tint: sentinel), dark: dark))
                    XCTAssertEqual(alpha, 1, accuracy: 0.001, "\(reason) under \(ramp.rawValue)")
                }
            }
        }
    }

    /// Whatever the ramp, a mark still has ink in it.
    ///
    /// This is the presence half of the near-cap contract: the design promises
    /// that greyscale costs the panel its hue and none of its other channels,
    /// and a ramp that resolved a mark to something transparent would take the
    /// mark itself with it. The floor is `Color.primary`'s own 0.847 — the
    /// lightest any of these gets, and the value `.mono` lands on.
    func testNoRampDrainsTheMarkBelowVisibility() throws {
        for ramp in AppearanceSettings.ColorRamp.allCases {
            for reason in reasons {
                for dark in [false, true] {
                    let opacity = try XCTUnwrap(alpha(RowSpine.ink(reason, ramp: ramp, tint: sentinel), dark: dark))
                    XCTAssertGreaterThanOrEqual(
                        opacity, 0.84,
                        "\(reason) under \(ramp.rawValue) on \(dark ? "dark" : "light") is a wash"
                    )
                }
            }
        }
    }

    // MARK: - Monochrome

    /// The user asked for a panel with no hue in it, and the spine is the one
    /// vertical coloured element there is — leaving it saturated would make it
    /// the only thing in the panel ignoring the setting. Nothing is lost: what
    /// carries "this row wants you" is the mark being there.
    ///
    /// Equality against `Color.primary` itself rather than against a resolved
    /// value, because that is what catches the failure worth catching: any
    /// `.opacity()` laid over it compares unequal, and a washed-out 2pt mark is
    /// the one thing this reason cannot afford.
    func testMonoTakesPrimaryAtFullOpacityForAllThreeReasons() {
        for reason in reasons {
            XCTAssertEqual(
                RowSpine.ink(reason, ramp: .mono, tint: sentinel), Color.primary,
                "\(reason) is not the label colour under mono"
            )
            XCTAssertNotEqual(RowSpine.ink(reason, ramp: .mono, tint: sentinel), sentinel, "\(reason)")
        }
    }

    /// And it follows the appearance rather than being a fixed black, which is
    /// the whole reason it is `.primary` and not a hex: the mark has to survive
    /// on both panel grounds.
    func testTheMonoMarkResolvesToBothAppearances() throws {
        let ink = RowSpine.ink(.nearCap, ramp: .mono, tint: sentinel)
        let light = try XCTUnwrap(hex(ink, dark: false))
        let dark = try XCTUnwrap(hex(ink, dark: true))
        XCTAssertNotEqual(light, dark, "the monochrome mark is one fixed value in both appearances")
    }

    /// Under a coloured ramp the mark is a hue, not the label colour. This is
    /// the other half of the mono rule: if every ramp resolved to `.primary` the
    /// mono case would be asserting nothing.
    func testAColouredRampIsNotTheLabelColour() {
        for ramp in colouredRamps {
            for reason in reasons {
                XCTAssertNotEqual(
                    RowSpine.ink(reason, ramp: ramp, tint: sentinel), Color.primary,
                    "\(reason) under \(ramp.rawValue)"
                )
            }
        }
    }

    // MARK: - Resolving

    /// `performAsCurrentDrawingAppearance` rather than assigning
    /// `NSAppearance.current`: the second is deprecated, and a deprecation
    /// warning is a build regression here.
    private func resolve(_ color: Color, dark: Bool) -> NSColor? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return resolved
    }

    private func hex(_ color: Color, dark: Bool) -> UInt32? {
        guard let srgb = resolve(color, dark: dark) else { return nil }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return channel(srgb.redComponent) << 16
             | channel(srgb.greenComponent) << 8
             | channel(srgb.blueComponent)
    }

    private func alpha(_ color: Color, dark: Bool) -> CGFloat? {
        resolve(color, dark: dark)?.alphaComponent
    }
}

/// How wide the mark is drawn, and that the view around it builds.
///
/// The width is the near-cap channel that has to survive a display the colour
/// channel does not, so it is read from the tokens rather than restated: the
/// mark widening under increased contrast and `Tokens` deciding by how much are
/// two facts, and only the first one belongs here.
final class RowSpineWidthTests: XCTestCase {

    func testTheWidthComesFromTheTokens() {
        XCTAssertEqual(RowSpine.width(increasedContrast: false), Tokens.Control.spineWidth)
        XCTAssertEqual(RowSpine.width(increasedContrast: true), Tokens.Control.spineWidthIncreased)
    }

    /// Colour alone cannot rescue a 2pt mark on a low-contrast display, and the
    /// mark is the first thing such a display loses.
    func testTheMarkWidensUnderIncreasedContrast() {
        XCTAssertGreaterThan(
            RowSpine.width(increasedContrast: true),
            RowSpine.width(increasedContrast: false)
        )
    }

    /// Whole points, and at least two of them. A fractional width resamples on
    /// every backing store the panel can land on, which on something this thin
    /// is the difference between a mark and a smudge.
    func testBothWidthsAreWholePointsAndThickEnoughToSee() {
        for increased in [false, true] {
            let width = RowSpine.width(increasedContrast: increased)
            XCTAssertTrue(width.isFinite, "increasedContrast \(increased) gave \(width)")
            XCTAssertEqual(width, width.rounded(), "increasedContrast \(increased) gave a fractional \(width)")
            XCTAssertGreaterThanOrEqual(width, 2, "increasedContrast \(increased) gave \(width)")
        }
    }

    // MARK: - As a view

    /// Every reason under every ramp builds and asks for exactly the token's
    /// width. The colours are asserted above; what is left to check is that the
    /// view is wired to the same two functions rather than to its own copy of
    /// either.
    @MainActor
    func testTheMarkBuildsAtTheTokenWidthForEveryReasonAndRamp() {
        for ramp in AppearanceSettings.ColorRamp.allCases {
            for reason: SpineReason in [.nearCap, .needsUser, .failed] {
                let host = NSHostingView(
                    rootView: AnyView(
                        RowSpineView(reason: reason, ramp: ramp, tint: .red).frame(height: 40)
                    )
                )
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(
                    host.fittingSize.width,
                    RowSpine.width(increasedContrast: false),
                    accuracy: 0.5,
                    "\(reason) under \(ramp.rawValue)"
                )
            }
        }
    }

    /// It fills the height it is given rather than measuring one. Anything in
    /// the panel that requests height requests it on every row, and the mark is
    /// held off the card's ends by the caller — so it has to take the inset
    /// height it is handed without arguing.
    @MainActor
    func testTheMarkFillsTheHeightItIsGiven() {
        for height in [12, 28, 49] as [CGFloat] {
            let host = NSHostingView(
                rootView: AnyView(
                    RowSpineView(reason: .nearCap, ramp: .usage, tint: .red).frame(height: height)
                )
            )
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, height, accuracy: 0.5, "at \(height)pt")
        }
    }
}
