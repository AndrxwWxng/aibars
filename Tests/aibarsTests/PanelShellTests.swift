import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The panel shell: its ground, its group headers, and the header that must not
/// move.
///
/// The height cases live in `PanelLayoutTests` — this is about what the shell
/// says rather than how tall it asks to be.
///
/// The four cases that used to open this file asserted a header rule that took
/// the warning colour whenever anything was near its cap. That behaviour is
/// deleted, so its tests are deleted with it: the rule is neutral at every usage
/// level and the alarm belongs to the row that has the problem. What replaces
/// them is one case that reads the rule back off the raster, because with the
/// decision gone there is no longer a function to ask.
final class PanelShellTests: XCTestCase {

    // MARK: - Group headers

    /// The group header is a divider with a word on it rather than reading
    /// matter, so it is fixed at the panel's caption size and the text-scale
    /// slider has nothing to say about it. `Ramp.detail`, not `Ramp.caption`:
    /// 10pt is spent on exactly one line in the app now — the pace sentence —
    /// and a header a point smaller than the countdown under it was a fifth
    /// size pretending to be a hierarchy. Asserted on the defaults both kinds
    /// carry, because that is where the old scaled size used to be
    /// reintroduced: the panel handed one in, and anything that built either
    /// type without one got a second size instead.
    @MainActor
    func testGroupHeadersAreFixedAtTheCaptionSize() {
        XCTAssertEqual(SectionLabel(title: "grouped", count: 3).fontSize, Tokens.Ramp.detail)
        XCTAssertEqual(
            DisclosureHeader(title: "grouped", count: 3, isExpanded: .constant(false)).fontSize,
            Tokens.Ramp.detail
        )
    }

    /// A block drawn whole is indented past the chevron a collapsible one
    /// carries, so the two kinds of title share a left edge. Both take that
    /// column from one function, and it has to answer at the size they are now
    /// drawn at.
    @MainActor
    func testTheChevronColumnIsWiderThanTheChevron() {
        let column = DisclosureHeader.chevronColumn(at: Tokens.Ramp.caption)
        XCTAssertGreaterThan(column, Tokens.Ramp.caption, "the column has to hold the glyph and its gap")
    }

    // MARK: - The header

    @MainActor
    private func settings(_ name: String) -> AppearanceSettings {
        // A suite of its own, so one case's panel width is not another's.
        guard let store = UserDefaults(suiteName: "panel-shell-\(name)") else {
            return AppearanceSettings.shared
        }
        store.removePersistentDomain(forName: "panel-shell-\(name)")
        return AppearanceSettings(store: store)
    }

    /// The header used to carry a four-bar meter of the same usage the rows
    /// draw, and a mark whose colour changed at the threshold. It is an identity
    /// now, which is what makes this assertion possible: the header's height
    /// cannot move with a percentage, so the rule going red can never push the
    /// list down and make `MenuBarExtra` resize the window under the pointer.
    @MainActor
    func testHeaderHeightDoesNotMoveWithUsage() {
        func height(topPercent: Double) -> CGFloat {
            let header = PanelHeader(
                appearance: settings("header"),
                levels: [topPercent, 0.2, 0.1],
                topPercent: topPercent,
                summary: "updated 12s ago"
            ) {
                Image(systemName: "arrow.clockwise")
            }
            return NSHostingView(rootView: AnyView(header.frame(width: 356))).fittingSize.height
        }
        XCTAssertEqual(height(topPercent: 0.10), height(topPercent: 0.95), accuracy: 0.01)
    }

    /// The header is built before anything has answered and again once
    /// everything has, and neither is a special case it gets to opt out of.
    @MainActor
    func testHeaderBuildsWithNothingAndWithNineServices() {
        let appearance = settings("counts")
        for levels in [[Double](), Array(repeating: 0.5, count: 9)] {
            let header = PanelHeader(
                appearance: appearance,
                levels: levels,
                topPercent: levels.max() ?? 0,
                summary: levels.isEmpty ? "not refreshed" : "updated just now"
            ) {
                Image(systemName: "gearshape")
            }
            let size = NSHostingView(rootView: AnyView(header.frame(width: 356))).fittingSize
            XCTAssertGreaterThan(
                size.height, 0,
                "the header drew nothing at \(levels.count) services"
            )
        }
    }

    // MARK: - The header's two axes

    /// The header's wordmark begins exactly where a row's name begins, at every
    /// logo size the slider can reach.
    ///
    /// The header used to spell its own leading column out — a 14pt `AppMark` and
    /// a `Space.medium` — while a row spells its as the logo and a
    /// `Space.leadingColumn`. Two sums for one column, so the two axes could only
    /// agree by coincidence, and once the mark's grid was made whole and the mark
    /// came out 15pt wide they agreed nowhere: the wordmark stood at
    /// 12 + 15 + 8 = 35 against a name at 12 + logoSize + 10, which is 38, 40, 44
    /// and 62 at the four sizes below. There is one sum now and the header is a
    /// caller of it.
    ///
    /// Computed on both sides rather than read off a render. The two runs are
    /// "aibars" and a service's name, whose glyphs carry different left side
    /// bearings, so a rendered comparison has about a point of slop in it — and at
    /// the shipped 18pt logo the error being watched for is five.
    @MainActor
    func testTheHeadersWordmarkBeginsOnTheRowsNameAxis() {
        let appearance = settings("axis")
        // Both ends of the slider's 16...40 range, the shipped 18, and the 22 the
        // Comfortable preset carries.
        let expected: [Double: CGFloat] = [16: 38, 18: 40, 22: 44, 40: 62]
        for logoSize in expected.keys.sorted() {
            appearance.logoSize = logoSize
            let padding = appearance.metrics.rowHorizontalPadding

            let header = padding + PanelAxis.leadingColumn(for: appearance)
            let row = padding + RowGeometry(
                metrics: appearance.metrics,
                showsPercentage: appearance.showsPercentage,
                meterStyle: appearance.meterStyle,
                logoStyle: appearance.logoStyle,
                logoSize: CGFloat(appearance.logoSize),
                panelWidth: CGFloat(appearance.panelWidth),
                rowActions: appearance.rowActions,
                // The row directly under the header, which has landed a reading
                // and drawn both of its optional lines. The header asks the same
                // arithmetic with `lines: []`, so an equal answer also pins that
                // the leading column is not a function of them — the day it
                // becomes one, the header starts measuring a row that isn't there.
                lines: [.meter, .window]
            ).leadingWidth

            XCTAssertEqual(
                header, row, accuracy: 0.001,
                "at a \(logoSize)pt logo the wordmark starts at \(header)pt and a service name at "
                + "\(row)pt — the header and the rows are laid out to two different axes"
            )
            // Written twice, as this file's own rule: the sum, and the number the
            // sum comes to.
            XCTAssertEqual(
                row,
                Tokens.Space.gutter + CGFloat(logoSize) + Tokens.Space.leadingColumn,
                accuracy: 0.001
            )
            XCTAssertEqual(row, expected[logoSize] ?? 0, accuracy: 0.001)

            // The premise: the arithmetic this replaced really did answer
            // something else, and answered the same something at every size.
            let retired = padding
                + AppMarkGeometry(size: Tokens.Control.headerGlyph).width
                + Tokens.Space.medium
            XCTAssertEqual(
                retired, 35, accuracy: 0.001,
                "the retired sum is the gutter, the mark's own drawn width and the line's gap — "
                + "12 + 15 + 8 — and it is what the wordmark stood on at every logo size"
            )
            XCTAssertNotEqual(
                retired, row, accuracy: 0.001,
                "the header's own arithmetic already agreed with the rows at \(logoSize)pt, so "
                + "this case cannot see the drift it exists for"
            )
        }
    }

    /// With the logos hidden and the meter off the dial, a row draws no leading
    /// column — and neither does the header. A mark standing in front of a list
    /// with no marks in it is the same indent in front of nothing `ProviderRow`
    /// already refuses.
    @MainActor
    func testTheHeaderKeepsNoColumnTheRowsHaveGivenUp() {
        let appearance = settings("axis-hidden")
        appearance.logoStyle = .hidden
        appearance.meterStyle = .bar
        XCTAssertEqual(
            PanelAxis.leadingColumn(for: appearance), 0,
            "the header still reserves a column for a mark the list below it does not draw"
        )

        // Under the ring the dial *is* the column, on every row whether or not it
        // has a reading — so the header keeps one too and stands its mark in it.
        appearance.meterStyle = .ring
        XCTAssertEqual(
            PanelAxis.leadingColumn(for: appearance),
            appearance.metrics.ringDiameter + Tokens.Space.leadingColumn,
            accuracy: 0.001
        )
    }

    /// And the column the mark now sits in changes nothing about how tall the
    /// header is. It is a width frame around a mark that keeps its own
    /// `Control.headerGlyph` height, so the rule under the header and every row
    /// beneath it stay where they are at any logo size.
    @MainActor
    func testTheLogoSizeDoesNotMoveTheHeaderDown() {
        let appearance = settings("axis-height")
        var heights: [Double: CGFloat] = [:]
        for logoSize in [16.0, 18.0, 22.0, 40.0] {
            appearance.logoSize = logoSize
            let header = PanelHeader(appearance: appearance, summary: "updated 12s ago") {
                Image(systemName: "arrow.clockwise")
            }
            heights[logoSize] = NSHostingView(
                rootView: AnyView(header.frame(width: 356))
            ).fittingSize.height
        }
        let spread = (heights.values.max() ?? 0) - (heights.values.min() ?? 0)
        XCTAssertLessThanOrEqual(
            spread, 0.01,
            "the header measured \(heights) across the logo slider — its mark's box is growing "
            + "the masthead as well as widening it"
        )
    }

    // MARK: - The header rule

    /// One neutral hairline under the header, at every usage level up to and
    /// including 100%.
    ///
    /// A coloured line across the chrome names no service, which makes it the one
    /// piece of hue in the panel that no row can account for: a user who reads it
    /// has to go and find out what it was about. The rule going neutral is the
    /// deletion this file is mostly about, and this is what stops it being
    /// quietly undone — the panel is drawn at each level and the line is measured.
    ///
    /// Neutrality is stated against the ground the rule sits on rather than as a
    /// fixed number, because the raster resolves in whatever appearance the
    /// machine happens to be in and the two grounds are two different warm greys.
    @MainActor
    func testHeaderRuleIsNeutralAtEveryUsageLevel() throws {
        var neutral: NSColor?
        for percent in [0, 0.5, 0.84, 0.85, 0.95, 1] as [Double] {
            let drawn = panel(usage: percent, suite: "rule-\(Int(percent * 100))")
            // Or the case passes on a panel that never reached the level it says
            // it is testing, which is the whole of what it is testing.
            XCTAssertEqual(
                drawn.state.topUsagePercent, percent, accuracy: 0.0001,
                "the panel under test did not reach \(percent)"
            )
            let sheet = try XCTUnwrap(raster(drawn.view), "the panel did not render at \(percent)")
            let rule = try XCTUnwrap(
                Self.rule(in: sheet),
                "no hairline was drawn under the header at \(percent)"
            )

            XCTAssertLessThanOrEqual(
                rule.mostColoured.excess, Self.hueAllowance,
                "the rule carries hue at \(percent): \(Self.describe(rule.mostColoured.ink)) "
                + "over a ground of \(Self.describe(rule.mostColoured.ground))"
            )

            // Not merely neutral at each level but the same line at all of them:
            // a rule that took a heavier grey at the threshold would still be the
            // chrome reporting a row's problem.
            if let neutral {
                for channel in Self.channels {
                    XCTAssertEqual(
                        channel.read(rule.sample), channel.read(neutral), accuracy: 0.01,
                        "the rule's \(channel.name) moved at \(percent): "
                        + "\(Self.describe(rule.sample)) against \(Self.describe(neutral))"
                    )
                }
            } else {
                neutral = rule.sample
            }
        }
    }

    // MARK: - The ground

    /// Reduce-transparency is asserted here rather than through the panel
    /// because `EnvironmentValues.accessibilityReduceTransparency` is read-only:
    /// there is no way to hand a hosting view the setting turned on. The
    /// arithmetic is the part that decides what gets drawn, and the panel does
    /// nothing with it but pass it through.
    func testScrimIsOpaqueUnderReduceTransparency() {
        XCTAssertEqual(Tokens.scrimAlpha(isDark: true, reduceTransparency: true), 1)
        XCTAssertEqual(Tokens.scrimAlpha(isDark: false, reduceTransparency: true), 1)
    }

    /// And translucent otherwise, or the material underneath is being paid for
    /// and hidden.
    func testScrimLetsTheMaterialThroughOtherwise() {
        XCTAssertLessThan(Tokens.scrimAlpha(isDark: true, reduceTransparency: false), 1)
        XCTAssertLessThan(Tokens.scrimAlpha(isDark: false, reduceTransparency: false), 1)
    }

    /// The empty half of every bar survives any desktop.
    ///
    /// This is what the scrim is *for*, and it is the only reason the two alphas
    /// are the numbers they are. `Meter.track` is the one absolute pair the app
    /// draws inside the panel — every other plane in there is `Surface.base` or
    /// an opacity over it — while the ground beneath it is `base` at
    /// `scrimAlpha` over `.regularMaterial`, which is to say partly the user's
    /// wallpaper. So the track and its container move independently, and a
    /// bright enough desktop used to lift the dark ground straight through the
    /// track: as shipped (`#2A2B2F` on `#101114` at 0.88) a white wallpaper put
    /// the ground at `#2D2E30` and the track **1.0404:1 below it** — the empty
    /// half of every bar and dial was a hole rather than a container.
    ///
    /// Measured on the same pessimistic model the palette uses throughout, with
    /// the material contributing nothing: light **1.2545:1 with the track below
    /// its ground**, dark **1.2735:1 with the track above its ground**. Both
    /// sides matter, which is why the direction is asserted and not only the
    /// ratio — a track that clears the ground by 1.27 on the wrong side of it is
    /// the same defect with a passing number.
    ///
    /// The alphas were solved for this and nothing else: at 0.92 the dark pair
    /// is 1.2164, at 0.88 it is 1.0715, and at 0.86 it reaches 1.0005 and
    /// vanishes. The floor here is 1.2, which sits under both shipped values and
    /// over everything the retired alphas could reach.
    func testTheTrackNeverInvertsAgainstTheGround() throws {
        for dark in [true, false] {
            let name = dark ? "dark" : "light"
            let base = try resolve(Tokens.Surface.base, dark: dark)
            let track = try resolve(Tokens.Meter.track, dark: dark)
            // The wallpaper that pushes the ground hardest towards the track:
            // white under a dark panel, black under a light one.
            let extreme: CGFloat = dark ? 1 : 0
            let wallpaper = NSColor(srgbRed: extreme, green: extreme, blue: extreme, alpha: 1)
            let scrim = Tokens.scrimAlpha(isDark: dark, reduceTransparency: false)
            let ground = Self.composite(wallpaper, at: 1 - scrim, over: base)

            let ratio = Self.contrast(track, ground)
            XCTAssertGreaterThan(
                ratio, 1.2,
                "the \(name) track measures \(ratio):1 against a ground of "
                + "\(Self.describe(ground)) — the container has stopped being one"
            )
            XCTAssertEqual(
                Tokens.relativeLuminance(track) > Tokens.relativeLuminance(ground), dark,
                "the \(name) track is on the wrong side of its ground"
            )
        }
    }

    /// Every pixel of the panel is covered: the body is drawn on a ground, and
    /// nothing carrying a number is composited straight onto the desktop.
    ///
    /// The scrim over one material is the whole of the application's
    /// translucency, and everything above it is an opaque surface plus a
    /// `Color.primary` opacity. Offscreen a material resolves opaque, which is
    /// what makes this measurable at all — and it also fixes what the case can
    /// honestly claim. What it catches is a hole in the ground: a list, a footer
    /// or a banner drawn outside the surface that is meant to be under it, which
    /// on a desktop is a figure with a wallpaper behind it. A second material
    /// *stacked* on the ground rasters opaque too, so that half of the rule stays
    /// a review rule rather than becoming an assertion here.
    @MainActor
    func testPanelBodyIsDrawnOnAnOpaqueGround() throws {
        // Without this the case would also pass on a renderer that had stopped
        // reporting alpha at all, which is how a raster test dies quietly.
        let translucent = try XCTUnwrap(raster(Color.black.opacity(0.5).frame(width: 8, height: 8)))
        let halfCovered = try XCTUnwrap(translucent.colorAt(x: 4, y: 4))
        XCTAssertLessThan(
            halfCovered.alphaComponent, 1,
            "the harness cannot see transparency, so it cannot see the absence of it either"
        )

        let drawn = panel(usage: 0.92, suite: "ground")
        let sheet = try XCTUnwrap(raster(drawn.view))
        XCTAssertEqual(
            sheet.pixelsWide, Int(drawn.appearance.panelWidth.rounded()),
            "the panel did not raster at its own width"
        )
        XCTAssertGreaterThan(
            sheet.pixelsHigh, 150,
            "the list collapsed to nothing, so there is no body here to check"
        )

        var thinnest: CGFloat = 1
        var thinnestAt = CGPoint.zero
        for y in 0..<sheet.pixelsHigh {
            for x in 0..<sheet.pixelsWide {
                guard let pixel = sheet.colorAt(x: x, y: y), pixel.alphaComponent < thinnest else {
                    continue
                }
                thinnest = pixel.alphaComponent
                thinnestAt = CGPoint(x: x, y: y)
            }
        }
        XCTAssertEqual(
            thinnest, 1, accuracy: 0.001,
            "the panel is \(thinnest) opaque at \(thinnestAt) — the ground does not reach there"
        )
    }

    // MARK: - Width

    /// The ground is a background, and a background must not propose a size.
    /// `PanelLayoutTests` fixes the default width; this one is about the setting
    /// still reaching the window at all three ends of its range.
    @MainActor
    func testPanelKeepsTheConfiguredWidth() {
        for width in [300.0, 380.0, 520.0] {
            let appearance = settings("width-\(Int(width))")
            appearance.panelWidth = width
            let state = AppState()
            let panel = MenuBarContentView(
                state: state,
                showSettings: .constant(false),
                appearance: appearance
            )
            let fitting = NSHostingView(rootView: AnyView(panel)).fittingSize
            XCTAssertEqual(
                fitting.width, CGFloat(appearance.panelWidth), accuracy: 0.01,
                "the panel asked for \(fitting.width)pt at a \(width)pt setting"
            )
        }
    }

    // MARK: - Building a panel

    /// A panel with three services all reporting the same percentage, and the
    /// appearance it was built against.
    ///
    /// Modelled on `PanelLayoutTests`: a row is built out of a credential and a
    /// snapshot, and both are settable, so getting a panel to a stated usage
    /// level involves no network, no session store and no keychain.
    @MainActor
    private func panel(
        usage percent: Double,
        suite: String
    ) -> (state: AppState, appearance: AppearanceSettings, view: AnyView) {
        let appearance = settings(suite)
        let state = AppState()
        for provider in state.providers.prefix(3) {
            provider.isAuthenticated = true
            state.snapshots[provider.id] = .success(
                UsageData(
                    providerID: provider.id,
                    planName: "Pro",
                    primary: UsageMetric(
                        label: "5h window",
                        used: percent * 100,
                        limit: 100,
                        unit: "%"
                    ),
                    secondary: [UsageMetric(label: "Weekly", used: 40, limit: 100, unit: "%")]
                )
            )
        }
        let view = MenuBarContentView(
            state: state,
            showSettings: .constant(false),
            appearance: appearance
        )
        return (state, appearance, AnyView(view))
    }

    /// One pixel per point, deliberately. The rule is 1pt: at scale 2 it becomes
    /// two rows of half-covered pixels, which is more sampling of the same fact.
    @MainActor
    private func raster<V: View>(_ view: V) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    // MARK: - Reading the rule back

    /// The hairline under the header, as drawn.
    private struct Rule {
        /// The pixel of the hairline carrying the most hue over the ground in its
        /// own column, and by how much. Held against its own ground rather than
        /// against a fixed value because the threshold is a step above the
        /// ground, and which ground that is depends on the appearance the raster
        /// resolved in. Reduced to one pixel because a coloured rule is coloured
        /// for its whole length: asserting per pixel reports one failure three
        /// hundred times and buries the message in it.
        let mostColoured: (ink: NSColor, ground: NSColor, excess: CGFloat)
        /// One sample from the middle of its first row, for holding one level's
        /// rule against another's.
        let sample: NSColor
    }

    /// Find that hairline without being told where it is.
    ///
    /// Located structurally rather than at the header's measured height, for two
    /// reasons. A height computed here would have to be kept in step with the
    /// header by hand, which is the arrangement that let the Appearance pane's
    /// preview drift away from the panel it previews. And a 1pt rule under a
    /// header whose height is fractional lands on two pixel rows at partial
    /// coverage, where half a coloured rule is still a coloured rule. A rule runs
    /// the width of the panel and a run of text never covers nine tenths of a
    /// pixel row, so the first such run from the top is the rule, however it fell
    /// across the grid.
    private static func rule(in sheet: NSBitmapImageRep) -> Rule? {
        var ground: [NSColor] = []
        for x in 0..<sheet.pixelsWide {
            guard let colour = sheet.colorAt(x: x, y: 0)?.usingColorSpace(.sRGB) else { return nil }
            ground.append(colour)
        }

        var worst: (ink: NSColor, ground: NSColor, excess: CGFloat)?
        var sample: NSColor?
        for y in 1..<sheet.pixelsHigh {
            var row: [(ink: NSColor, ground: NSColor)] = []
            for x in 0..<sheet.pixelsWide {
                guard let colour = sheet.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      distance(colour, ground[x]) > inked else { continue }
                row.append((colour, ground[x]))
            }
            if Double(row.count) / Double(sheet.pixelsWide) >= fullWidth {
                if sample == nil {
                    sample = sheet.colorAt(x: sheet.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB)
                }
                for pixel in row {
                    let excess = pixel.ink.saturationComponent - pixel.ground.saturationComponent
                    guard excess > (worst?.excess ?? -.greatestFiniteMagnitude) else { continue }
                    worst = (pixel.ink, pixel.ground, excess)
                }
            } else if worst != nil {
                // The run has ended, and everything past it is the list.
                break
            }
        }

        guard let sample, let worst else { return nil }
        return Rule(mostColoured: worst, sample: sample)
    }

    /// A cool graphite is not a pure grey — the panel's own ground measures
    /// 0.013 saturation where this raster resolves, and `Surface.base` measures
    /// 0.016 as a token in light and **0.294** in dark, where five 8-bit steps
    /// of blue over red are most of what a near-black has — so "carries no hue"
    /// has to be a step above the ground rather than a step above zero.
    ///
    /// The dark figure is the one that moved, and it is arithmetic rather than a
    /// decision: the base went `#101114`, 4 steps of blue over red on a maximum
    /// of 20, to `#0C0D11`, 5 over a maximum of 17 — so HSB saturation went
    /// 0.200 to 0.294 while the panel got no more colourful. A cool offset is a
    /// larger fraction of a darker value, which is exactly why this allowance is
    /// a difference from the ground and never an absolute.
    ///
    /// What the rule used to take is still a long way past the allowance:
    /// `Ink.alarm` at 0.55 over the light base measures 0.33, and 0.14 where it
    /// lands on a pixel row at half coverage. Those were 0.39 and 0.18 with the
    /// retired `#B92126` — red went darker rather than duller, deliberately, so
    /// that it separates from amber in greyscale, and shed a little saturation
    /// on the way. The tighter of the two is still more than twice this
    /// allowance, which is the same argument with smaller numbers in it.
    private static let hueAllowance: CGFloat = 0.06

    /// How far a pixel has to sit from the ground in its own column to count as
    /// inked. At full coverage a hairline at `Fill.rule` 0.07 moves the light
    /// ground by 0.07 of it (about 0.068) and the dark one by 0.07 of the way to
    /// white (about 0.066); the header's rule is one device pixel under a
    /// fractional header height, so what this raster actually sees is **0.054**
    /// on the row it falls across. That was about 0.046 until `quiet(_:)` stopped
    /// multiplying by `Color.primary`'s hidden 0.8471 alpha — 0.012 cleared the
    /// quieter figure by four times and clears this one by four and a half, so
    /// the threshold did not have to move with the palette.
    private static let inked: CGFloat = 0.012

    /// How much of a pixel row a rule covers. Nine tenths rather than all of it,
    /// because a rule inset to the panel's gutter is still a rule.
    private static let fullWidth: Double = 0.9

    private static let channels: [(name: String, read: (NSColor) -> CGFloat)] = [
        ("red", { $0.redComponent }),
        ("green", { $0.greenComponent }),
        ("blue", { $0.blueComponent })
    ]

    /// The largest gap between two colours on any one channel. A per-channel
    /// distance rather than a difference in luminance: a rule that swapped grey
    /// for a colour of the same lightness is exactly the change being watched
    /// for.
    private static func distance(_ one: NSColor, _ other: NSColor) -> CGFloat {
        channels.map { abs($0.read(one) - $0.read(other)) }.max() ?? 0
    }

    // MARK: - Compositing a ground that is not drawn anywhere

    /// A dynamic colour resolved in a named appearance.
    ///
    /// `performAsCurrentDrawingAppearance` rather than assigning
    /// `NSAppearance.current`: the second is deprecated, and a deprecation
    /// warning is a build regression here.
    private func resolve(_ color: Color, dark: Bool) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved, "colour would not resolve in sRGB")
    }

    /// One plane over another, `round(bg + (fg − bg)·α)` per 8-bit channel —
    /// the arithmetic the palette states its own figures in, quantised at each
    /// step because each step is a real drawn surface.
    ///
    /// Needed because the ground the track has to clear is a ground nothing in
    /// the app draws in one go: it is the panel's own surface with the desktop
    /// still showing through it, which is why the raster cases above cannot see
    /// it. Offscreen a material resolves opaque, so a rendered panel is the one
    /// desktop this suite can never sample.
    private static func composite(_ ink: NSColor, at alpha: Double, over ground: NSColor) -> NSColor {
        func channel(_ component: (NSColor) -> CGFloat) -> CGFloat {
            let background = (component(ground) * 255).rounded()
            let foreground = (component(ink) * 255).rounded()
            return (background + (foreground - background) * CGFloat(alpha)).rounded() / 255
        }
        return NSColor(
            srgbRed: channel { $0.redComponent },
            green: channel { $0.greenComponent },
            blue: channel { $0.blueComponent },
            alpha: 1
        )
    }

    /// WCAG contrast, off the app's own luminance so a failure here is directly
    /// comparable with the figures recorded in `DesignSystem.swift`.
    private static func contrast(_ one: NSColor, _ other: NSColor) -> Double {
        let a = Tokens.relativeLuminance(one), b = Tokens.relativeLuminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func describe(_ colour: NSColor) -> String {
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgb(\(channel(colour.redComponent)), "
            + "\(channel(colour.greenComponent)), \(channel(colour.blueComponent)))"
    }
}
