import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The panel's one horizontal contract: **nothing the panel draws may fall
/// outside the panel.**
///
/// It is not a nicety. `MenuBarContentView` draws its ground at
/// `.frame(width: panelWidth)`, and a SwiftUI frame does not clip — a subview
/// whose *minimum* width exceeds the proposal is laid out at that minimum and
/// centred, so it draws outside the ground on both sides and `MenuBarExtra`
/// then sizes its window to the overflowing content. Worse, every row in the
/// list shares one `VStack` and each row is `.frame(maxWidth: .infinity)`: a
/// single service with a wide caption drags *every other row* off-centre with
/// it. One bad row is a broken panel, which is exactly how it shipped.
///
/// Asserted in pixels rather than in points, and that is deliberate. The
/// obvious measurement — `NSHostingView.fittingSize` — cannot answer this
/// question from either end. Asked of the panel it returns `panelWidth`,
/// because the outer `.frame(width:)` fixes it whatever the content underneath
/// is doing. Asked of a bare row it over-reports, because `fittingSize` does
/// not resolve a `ViewThatFits` the way a real layout pass does, and both the
/// header's summary and a row's identity run are `ViewThatFits`. So the panel
/// is drawn into a canvas wider than itself and the margins are inspected: ink
/// outside the ground is content that escaped, and nothing else is.
final class PanelWidthContractTests: XCTestCase {

    /// How much clear canvas is left on each side of the panel. Wide enough to
    /// catch the escape rather than to contain it — the shipped defect put
    /// roughly 125pt past each edge.
    private static let margin: CGFloat = 200

    /// The panel widths a user can set, including both ends of the slider.
    private static let widths: [Double] = [300, 356, 420, 520]

    /// The text-size slider's two ends and the shipped value between them.
    ///
    /// Swept with the widths rather than left at 100%, because every reserved
    /// width in the row is a multiple of a type size and the text column is not:
    /// at 130% the figure rails, the chip runs and the spend all grow while the
    /// panel stays where the user put it, so a 300pt panel at 130% is the
    /// narrowest line the app can be asked to fit anything on. It is also the
    /// only combination that drives `chipLimit` down to its floor, which is the
    /// one branch where the reservation is not simply a division.
    private static let scales: [Double] = [0.85, 1.0, 1.30]

    /// The sparkline switch, in both positions.
    ///
    /// Swept alongside the widths because the trace is the second thing the row
    /// draws that spans the whole text column, and the first one broke this
    /// contract: `SecondaryChipRun` spans it under `.fixedSize()`, so it reported
    /// an ideal 40pt wider than the column and nothing could take the width back.
    ///
    /// What is measured here is the row *around* the slot — the block the trace
    /// adds must not perturb anything horizontal. The trace's own width is pinned
    /// where it can be stated exactly rather than inferred from a bitmap:
    /// `RowSparklineTests.testTheTraceAsksForNoWidthAtAll` hosts a full
    /// twenty-four-bucket series and requires a fitting width of zero. That is
    /// the stronger claim of the two, because a row whose store has nothing in it
    /// yet draws an empty `Path`, and an empty `Path` cannot overhang anything.
    private static let sparklines: [Bool] = [false, true]

    // MARK: - The contract

    @MainActor
    func testNothingDrawsOutsideThePanel() throws {
        let appearance = AppearanceSettings.shared
        let originalWidth = appearance.panelWidth
        let originalScale = appearance.textScale
        let originalSparkline = appearance.showsRowSparkline
        defer {
            appearance.panelWidth = originalWidth
            appearance.textScale = originalScale
            appearance.showsRowSparkline = originalSparkline
        }

        let state = Self.pathologicalState()
        var failures: [String] = []

        for width in Self.widths {
            for scale in Self.scales {
                for sparkline in Self.sparklines {
                    appearance.panelWidth = width
                    appearance.textScale = scale
                    appearance.showsRowSparkline = sparkline
                    let panel = MenuBarContentView(
                        state: state,
                        showSettings: .constant(false),
                        appearance: appearance
                    )
                    if let escape = Self.inkOutside(AnyView(panel), panelWidth: CGFloat(width)) {
                        failures.append(String(
                            format: "%.0fpt panel at %.0f%% type, trace %@: ink %.0fpt outside the ground (%@ edge)",
                            width, scale * 100, sparkline ? "on" : "off", escape.overhang, escape.edge
                        ))
                    }
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "content escaped the panel ground:\n" + failures.joined(separator: "\n")
        )
    }

    /// The same contract one row at a time.
    ///
    /// A separate test because the panel-level one cannot see this: the list
    /// sits in a `ScrollView`, which *does* clip, so an over-wide row is hidden
    /// rather than drawn outside the window. It is not harmless — the row is
    /// laid out at its own minimum and centred inside the clip, so the whole
    /// list shifts leading-ward and loses its brand marks off one edge and its
    /// figures off the other, which is precisely the reported defect. Measured
    /// here without the scroll view, where the overflow has nowhere to hide.
    @MainActor
    func testNoRowDrawsOutsideItsPanelWidth() throws {
        let appearance = AppearanceSettings.shared
        let originalWidth = appearance.panelWidth
        let originalScale = appearance.textScale
        let originalSparkline = appearance.showsRowSparkline
        defer {
            appearance.panelWidth = originalWidth
            appearance.textScale = originalScale
            appearance.showsRowSparkline = originalSparkline
        }

        let state = Self.pathologicalState()
        var failures: [String] = []

        for width in Self.widths {
            for scale in Self.scales {
                for sparkline in Self.sparklines {
                    appearance.panelWidth = width
                    appearance.textScale = scale
                    appearance.showsRowSparkline = sparkline
                    for provider in state.providers where provider.isAuthenticated {
                        let row = ProviderRow(
                            provider: provider,
                            result: state.snapshots[provider.id],
                            onSignIn: {},
                            appearance: appearance
                        )
                        .frame(width: CGFloat(width))

                        if let escape = Self.inkOutside(AnyView(row), panelWidth: CGFloat(width)) {
                            failures.append(String(
                                format: "%.0fpt panel at %.0f%% type, trace %@: %@ draws %.0fpt past the %@ edge",
                                width, scale * 100, sparkline ? "on" : "off",
                                provider.serviceID, escape.overhang, escape.edge
                            ))
                        }
                    }
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "rows escape the panel width:\n" + failures.joined(separator: "\n")
        )
    }

    // MARK: - The filter is new content on a width-locked panel

    /// A 32-character query is the widest run the header can be asked to hold, and
    /// the header is the one line in the panel with four fixed controls already on
    /// it.
    ///
    /// The cap is what makes the claim finite: `PanelKeyboard.queryLimit` is a
    /// width contract rather than a taste, so the case asserts against the same
    /// constant the reducer enforces instead of a literal that could drift away
    /// from it.
    @MainActor
    func testAFilterQueryCannotWidenThePanel() throws {
        let appearance = AppearanceSettings.shared
        let originalWidth = appearance.panelWidth
        let originalScale = appearance.textScale
        defer {
            appearance.panelWidth = originalWidth
            appearance.textScale = originalScale
        }

        let state = Self.pathologicalState()
        let query = String(repeating: "w", count: PanelKeyboard.queryLimit)
        var failures: [String] = []

        for width in Self.widths {
            for scale in Self.scales {
                appearance.panelWidth = width
                appearance.textScale = scale
                let panel = MenuBarContentView(
                    state: state,
                    showSettings: .constant(false),
                    appearance: appearance,
                    keyboard: .filtering(query)
                )
                if let escape = Self.inkOutside(AnyView(panel), panelWidth: CGFloat(width)) {
                    failures.append(String(
                        format: "%.0fpt panel at %.0f%% type: the filter line puts %.0fpt past the %@ edge",
                        width, scale * 100, escape.overhang, escape.edge
                    ))
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "the filter line escaped the panel ground:\n" + failures.joined(separator: "\n")
        )
    }

    /// And the same query when it matches nothing, which is the wider case of the
    /// two: the no-match block quotes the query back inside a title-sized line, so
    /// the longest run on screen is 32 characters at `titleSize` rather than at
    /// `detailSize`.
    @MainActor
    func testTheNoMatchBlockCannotWidenThePanel() throws {
        let appearance = AppearanceSettings.shared
        let originalWidth = appearance.panelWidth
        let originalScale = appearance.textScale
        defer {
            appearance.panelWidth = originalWidth
            appearance.textScale = originalScale
        }

        let state = Self.pathologicalState()
        let query = String(repeating: "w", count: PanelKeyboard.queryLimit)
        // The premise, so the case cannot pass by quietly matching something.
        XCTAssertTrue(
            PanelFilter.apply(
                query: query,
                to: appearance.sections(from: state.rankedProviders, snapshots: state.snapshots),
                all: state.providers,
                snapshots: state.snapshots
            ).rows.isEmpty,
            "the query this case is built on matches a row, so the no-match block is never drawn"
        )

        var failures: [String] = []
        for width in Self.widths {
            for scale in Self.scales {
                appearance.panelWidth = width
                appearance.textScale = scale
                let panel = MenuBarContentView(
                    state: state,
                    showSettings: .constant(false),
                    appearance: appearance,
                    keyboard: .filtering(query),
                    restingListHeight: 400
                )
                if let escape = Self.inkOutside(AnyView(panel), panelWidth: CGFloat(width)) {
                    failures.append(String(
                        format: "%.0fpt panel at %.0f%% type: the no-match block puts %.0fpt past the %@ edge",
                        width, scale * 100, escape.overhang, escape.edge
                    ))
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "the no-match block escaped the panel ground:\n" + failures.joined(separator: "\n")
        )
    }

    // MARK: - The reading a window with no ceiling prints

    /// **A limit of zero is "no ceiling", and it may not be drawn as a
    /// denominator.**
    ///
    /// It was. `SecondaryChip` rendered `ClaudeCodeProvider`'s token windows as
    /// `644.6M/0`, and "/0" is not a window with no cap — it is a fraction over
    /// zero, which is either a bug or nonsense depending on how carefully the
    /// reader is looking. It is asserted in this suite rather than a tidier one
    /// because the fixture below is where the real payload lives, and because the
    /// two characters were also two mono cells of an incompressible run on the
    /// line that overflowed.
    ///
    /// Swept over all four of the row's string-producing readings and over the
    /// provider's own payload, built by `ClaudeCodeReport` from real totals, so
    /// the case is about what the app is sent and not about a metric written
    /// here.
    func testNoUncappedWindowIsDrawnWithADenominator() {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: ClaudeCodeTotals(
                sessionWindow: Self.bucket(45_000),
                today: Self.bucket(644_600_000),
                week: Self.bucket(4_334_500_000),
                month: Self.bucket(9_767_200_000),
                byModel: [:],
                lastTurnAt: Date()
            )
        )

        let windows = [data.primary] + data.secondary
        XCTAssertEqual(windows.count, 4, "the provider stopped reporting the four windows this case sweeps")

        for metric in windows {
            XCTAssertEqual(metric.limit, 0, "\"\(metric.label)\" is no longer an uncapped window")
            let printed = [
                SecondaryChip.reading(for: metric).digits,
                SecondaryChip.reading(for: metric).unit ?? "",
                MetricCaption.amountText(for: metric),
                StatusLine.text(for: metric),
                SecondaryValue.value(for: metric)
            ]
            for line in printed {
                XCTAssertFalse(
                    line.contains("/0"),
                    "\"\(metric.label)\" printed \"\(line)\" — a denominator of zero"
                )
                XCTAssertFalse(
                    line.contains("/"),
                    "\"\(metric.label)\" printed \"\(line)\" — a division for a window with nothing to divide by"
                )
            }
        }
    }

    /// And the chip prints the value itself, which is the other half: a reading
    /// that dropped the "/0" by dropping the reading would pass the case above.
    func testAnUncappedChipPrintsTheBareValue() {
        let metric = UsageMetric(label: "Today", used: 644_600_000, limit: 0, unit: "tokens")
        let reading = SecondaryChip.reading(for: metric)
        XCTAssertEqual(reading.digits, "644.6M")
        XCTAssertNil(reading.unit, "the chip's nine-cell rail was handed a unit as well as a value")
    }

    /// A capped window is untouched, which is what makes the change a
    /// distinction rather than a deletion: a figure means there is a quota.
    func testACappedWindowKeepsItsDenominator() {
        let percentage = UsageMetric(label: "Weekly", used: 61, limit: 100, unit: "%")
        XCTAssertEqual(SecondaryChip.reading(for: percentage).digits, "61")
        XCTAssertEqual(SecondaryChip.reading(for: percentage).unit, "%")

        let counted = UsageMetric(label: "Requests", used: 120, limit: 500, unit: "reqs")
        XCTAssertEqual(SecondaryChip.reading(for: counted).digits, "120/500")
        XCTAssertEqual(MetricCaption.amountText(for: counted), "120 / 500 reqs")
    }

    // MARK: - Fixtures

    /// A window holding exactly `count` tokens.
    ///
    /// All of them counted as input, and the report adds the four token fields
    /// together, so the figure the row prints is the figure named at the call
    /// site rather than a sum a reader of this file would have to do.
    private static func bucket(_ count: Int) -> ClaudeCodeBucket {
        ClaudeCodeBucket(
            turns: 1,
            inputTokens: count,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedUSD: 0
        )
    }

    /// Every payload shape that has ever been able to widen a row, in one
    /// panel: token windows with no ceiling, a four-figure spend, three
    /// percentage windows with long names, and a sixty-character work address.
    ///
    /// Taken from what providers really send rather than invented.
    /// `ClaudeCodeProvider` reports `Today`, `7 days` and `30 days` at
    /// `limit: 0` with token counts in them — a seven-character label beside what
    /// used to be a nine-character reading, against a chip estimate that reserved
    /// four and seven. The reading is seven characters now that "no ceiling" no
    /// longer prints a denominator; the label is unchanged, and it is the label
    /// that the estimate got wrong by the wider margin.
    @MainActor
    static func pathologicalState() -> AppState {
        let state = AppState()
        let now = Date()

        if let claudeCode = state.providers.first(where: { $0.serviceID == "claudecode" }) {
            claudeCode.isAuthenticated = true
            state.snapshots[claudeCode.id] = .success(UsageData(
                providerID: claudeCode.id,
                primary: UsageMetric(label: "Spend", used: 0, limit: 0, unit: nil),
                secondary: [
                    UsageMetric(label: "Today", used: 644_600_000, limit: 0, unit: "tokens"),
                    UsageMetric(label: "7 days", used: 4_334_500_000, limit: 0, unit: "tokens"),
                    UsageMetric(label: "30 days", used: 9_767_200_000, limit: 0, unit: "tokens")
                ],
                spend: SpendReport(
                    amountMinor: 870_047, currency: "USD", exponent: 2,
                    period: .month, confidence: .estimated
                )
            ))
        }

        if let claude = state.providers.first(where: { $0.serviceID == "claude" }) {
            claude.isAuthenticated = true
            state.snapshots[claude.id] = .success(UsageData(
                providerID: claude.id,
                planName: "Max 20x",
                primary: UsageMetric(
                    label: "5h session", used: 92, limit: 100, unit: "%",
                    resetDate: now.addingTimeInterval(4_800)
                ),
                secondary: [
                    UsageMetric(label: "Weekly · all models", used: 61, limit: 100, unit: "%"),
                    UsageMetric(label: "Weekly · Opus", used: 88, limit: 100, unit: "%"),
                    UsageMetric(label: "Weekly · per-model", used: 12, limit: 100, unit: "%")
                ],
                accountLabel: "ada.lovelace.engineering@verylongcompanyname.example.com"
            ))
        }

        state.lastRefresh = now.addingTimeInterval(-12)
        return state
    }

    // MARK: - Measurement

    /// The panel drawn into a canvas `2 * margin` wider than itself, with the
    /// margins scanned for ink.
    ///
    /// Returns nil when both margins are clear. Otherwise the further of the
    /// two overhangs, in points, and which edge it ran past.
    @MainActor
    private static func inkOutside(
        _ panel: AnyView,
        panelWidth: CGFloat
    ) -> (overhang: CGFloat, edge: String)? {
        // The panel is placed in a transparent canvas rather than given one of
        // its own grounds, so "is there ink here" is a question about alpha and
        // needs no colour comparison — and so the test cannot be fooled by a
        // palette change.
        let canvas = panel
            .frame(width: panelWidth + 2 * margin, alignment: .center)

        let host = NSHostingView(rootView: AnyView(canvas.environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // One run-loop turn, not a wall-clock wait. A hosting view laid out
        // this turn has not resolved its content yet and the bitmap comes back
        // as the pre-layout frame; a `0.4` sleep did the job by accident and
        // cost eleven seconds across the twenty-eight renders this suite makes.
        RunLoop.current.run(mode: .default, before: Date())

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / size.width
        // A hair inside the margin, so a rounded corner's own antialiasing on
        // the ground's edge is not read as an escape.
        let slack: CGFloat = 1
        let leftEdge = Int(((margin - slack) * scale).rounded(.down))
        let rightEdge = Int(((margin + panelWidth + slack) * scale).rounded(.up))

        var worstLeft: Int?
        var worstRight: Int?

        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in 0..<max(0, leftEdge) where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.02 {
                if worstLeft == nil || x < worstLeft! { worstLeft = x }
            }
            for x in min(rightEdge, rep.pixelsWide)..<rep.pixelsWide
            where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.02 {
                if worstRight == nil || x > worstRight! { worstRight = x }
            }
        }

        let leftOverhang = worstLeft.map { (CGFloat(leftEdge - $0)) / scale } ?? 0
        let rightOverhang = worstRight.map { (CGFloat($0 - rightEdge)) / scale } ?? 0
        if leftOverhang <= 0 && rightOverhang <= 0 { return nil }
        return leftOverhang >= rightOverhang
            ? (leftOverhang, "leading")
            : (rightOverhang, "trailing")
    }
}
