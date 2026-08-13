import SwiftUI

/// One segment of the strip, as the drawing needs it.
///
/// Every reference the drawing makes to `MenuBarEntry` goes through `init(_:)`,
/// so the six styles are coupled to the strip model at exactly one line. The
/// figure arrives already chosen and already formatted: which services are shown
/// and how their numbers read belongs to the model, and a style that
/// re-formatted them would be a second copy of those rules to keep in step.
///
/// It was `private` to `MenuBarStripRenderer` while there was one drawing. It is
/// public here because there are six, each in its own file, and the alternative
/// to a shared segment type is six styles reaching into `MenuBarEntry` and six
/// chances to format a percentage differently.
public struct StripSegment: Equatable {
    public let serviceID: String
    public let displayName: String
    public let figure: String
    /// nil for a status-only service. Status-only services have no percentage
    /// and must not be given a fake one, so this is what decides whether the
    /// segment can take a usage tint at all — never a 0 standing in for it.
    public let percent: Double?

    public init(_ entry: MenuBarEntry) {
        self.serviceID = entry.serviceID
        self.displayName = entry.displayName
        self.figure = entry.figure
        self.percent = entry.percent
    }

    /// `serviceID` is the family, not the account, so two Claude subscriptions
    /// resolve to the one mark without any unpicking here.
    public var brand: BrandMark? { BrandMark.mark(for: serviceID) }

    /// What a service with no vector mark falls back to.
    public var initial: String {
        let letter = displayName.prefix(1).uppercased()
        return letter.isEmpty ? "?" : letter
    }

    /// Whether the strip is drawn in colour at all.
    ///
    /// A coloured image cannot be a template, so AppKit stops giving it the menu
    /// bar's own light/dark and vibrancy treatment — which is why colour is only
    /// spent when it is actually carrying a reading. Under `.alertOnly` that
    /// means nothing is coloured until something crosses the warning, and under
    /// `.perBar` a strip of status-only services still has no number to colour.
    public static func coloured(
        _ segments: [StripSegment],
        colour: AppearanceSettings.MenuBarColour,
        warningThreshold: Double
    ) -> Bool {
        switch colour {
        case .monochrome: return false
        case .alertOnly:  return segments.contains { ($0.percent ?? 0) >= warningThreshold }
        case .perBar:     return segments.contains { $0.percent != nil }
        }
    }
}

/// Everything a style needs to know about colour, resolved once per drawing.
///
/// The three `switch`es over `MenuBarColour` that lived in `MenuBarStripView`
/// live here instead. A style asks for "the ink this reading takes" and gets it;
/// no style file contains the word `monochrome`, so adding a seventh style
/// cannot get the colour rules subtly wrong, and changing the rules is one edit
/// rather than six.
public struct StripInk {
    /// Black, white or `.primary`, already resolved against the *menu bar's* own
    /// appearance by the renderer — not the application's. A dark wallpaper under
    /// a Light system paints the bar dark, and a neutral resolved against the app
    /// would bake near-black figures into a near-black bar.
    public let neutral: Color
    public let colour: AppearanceSettings.MenuBarColour
    public let warningThreshold: Double
    public let isDark: Bool
    /// `AppearanceSettings.coloursBrandMarks`. The user's one escape hatch from
    /// brand hue, and it reaches here as a value rather than as the settings
    /// object for the same reason `colour` and `warningThreshold` do: the
    /// rasteriser memoises on its inputs and an `ObservableObject` is not a key
    /// it can compare.
    public let coloursMarks: Bool
    /// `StripSegment.coloured(_:colour:warningThreshold:)`, which is also what
    /// sets `isTemplate` on the finished image.
    ///
    /// Only `brand(_:)` consults it, and the asymmetry is the point. A band is a
    /// reading, and every rule that produces one already returns the neutral when
    /// the strip is a template — `.monochrome` unconditionally, `.alertOnly` when
    /// nothing crossed. Brand ink is *identity*, which no rule turns off on its
    /// own, so a template would otherwise acquire a hue that AppKit then throws
    /// away, and the Appearance pane's preview — which is not a template — would
    /// show it.
    public let carriesColour: Bool

    public init(
        neutral: Color,
        colour: AppearanceSettings.MenuBarColour,
        warningThreshold: Double,
        isDark: Bool,
        coloursMarks: Bool,
        carriesColour: Bool
    ) {
        self.neutral = neutral
        self.colour = colour
        self.warningThreshold = warningThreshold
        self.isDark = isDark
        self.coloursMarks = coloursMarks
        self.carriesColour = carriesColour
    }

    /// The ink a reading takes when the reading is what is being coloured — a
    /// figure, a meter fill, a mark under `markOnly`.
    ///
    /// The line is the user's, not the palette's. `UsageTint.color(for:)` samples
    /// the ramp at its own fixed boundaries, so a user who moved the warning down
    /// to 0.70 read amber at 0.75 in the bar while the row underneath was already
    /// red — and under `.alertOnly` with the line under 0.60 the one figure that
    /// crossed it was tinted resting grey, which is an alert drawn in the colour
    /// of "you are fine". At or above the configured warning the reading
    /// therefore takes the top of the ramp, which is the colour
    /// `AppearanceSettings.menuBarTint(for:)` returns for the same reading. Below
    /// it, `.alertOnly` stays neutral and `.perBar` takes the level's own colour;
    /// the caution boundary stays the palette's, and only in `.perBar`, because
    /// the distinction it draws — resting against getting on — is a panel reading
    /// rather than a glance at a bar.
    ///
    /// A `nil` percent is the neutral in every mode. A status-only service has no
    /// band and must not be given one.
    public func band(_ percent: Double?) -> Color {
        guard let percent else { return neutral }
        switch colour {
        // Stated rather than left to `carriesColour` to imply it: a monochrome
        // strip is a template, and a template must not acquire a colour at any
        // reading, however near its cap that reading is.
        case .monochrome:
            return neutral
        case .alertOnly:
            return percent >= warningThreshold ? Self.alarm : neutral
        case .perBar:
            return percent >= warningThreshold ? Self.alarm : UsageTint.color(for: percent)
        }
    }

    /// Identity ink: the brand's own hue under `.perBar`, the neutral otherwise.
    ///
    /// Only a style with something *else* carrying the reading may call this.
    /// `markOnly` and `microBars` have no figure and no column to spare, so their
    /// marks take `band(_:)` instead — spending the strip's one channel on
    /// identity twice would leave those two styles saying nothing about usage at
    /// all.
    public func brand(_ mark: BrandMark) -> Color {
        guard carriesColour, coloursMarks, colour == .perBar else { return neutral }
        return mark.brandInk(dark: isDark)
    }

    /// The empty channel behind a meter fill.
    public var track: Color { neutral.opacity(Tokens.Strip.trackOpacity) }

    /// The rule the micro bars stand on, and the mid-channel stub that stands in
    /// for an em dash where there is no figure to draw one in.
    public var baseline: Color { neutral.opacity(Tokens.Strip.baselineOpacity) }

    /// The top of the ramp, asked for as a reading at the cap rather than as a
    /// sample at 0.85: the shipped threshold is a setting, and a colour that
    /// hardcoded it would ignore the user who moved the line.
    private static var alarm: Color { UsageTint.color(for: 1) }
}

/// One way of drawing a service in the menu bar.
///
/// Six of these, one file each, in place of the `switch` `MenuBarStripView`
/// would otherwise have grown: one in `body`, another in `markColour`, a third
/// in `figureColour` and a fourth in the accessibility sentence — four places to
/// remember when a seventh style arrives, and four chances to remember three of
/// them. Here a style is a type, and the compiler asks for every answer at once.
///
/// The width contract is in the signature rather than in the prose.
/// `cellWidth(height:)` has no parameter that could carry a reading, so a style
/// physically cannot size itself from the string in hand — which is the bug the
/// whole strip is built around: a service crossing 99 into 100 widening the item
/// and shoving every status icon to its left sideways.
public protocol StripStyle {
    associatedtype Cell: View
    associatedtype Underlay: View = EmptyView

    /// The persisted case this type draws. `StripStyleBox.box(for:)` is the only
    /// thing that reads it, and it reads it to assert the table is honest.
    static var kind: AppearanceSettings.MenuBarStyle { get }

    /// One service's width, from the mark height alone.
    ///
    /// `height` is the raw `menuBarGlyphHeight` — the value out of the store,
    /// unrounded and untrusted. Every style resolves it through `Tokens.Strip`,
    /// which is where the rounding and the non-finite guard live. Handing styles
    /// a pre-rounded height instead would put a second rounding site in the
    /// caller and let `cellWidth` and `cell` disagree the day one of them forgot.
    static func cellWidth(height: CGFloat) -> CGFloat

    /// The most services this style will ever draw, whatever the width budget
    /// allows. Three for the styles that mark each service; one for the two that
    /// cannot say which service a reading belongs to.
    static var segmentCeiling: Int { get }

    /// Which sentence shape VoiceOver hears. A style whose reading is a *tint* or
    /// a *bar height* has to say the band in words, because neither is audible.
    static var sentence: MenuBarStripContent.Sentence { get }

    /// Drawn behind the whole run rather than behind one cell — the micro bars'
    /// shared baseline, and nothing else. Defaults to nothing.
    @MainActor @ViewBuilder
    static func underlay(width: CGFloat, height: CGFloat, ink: StripInk) -> Underlay

    /// One service's drawing, in a box exactly `cellWidth(height:)` wide.
    @MainActor @ViewBuilder
    static func cell(_ segment: StripSegment, height: CGFloat, ink: StripInk) -> Cell
}

public extension StripStyle where Underlay == EmptyView {
    /// Five of the six styles draw nothing behind the run. Written once here so
    /// those five say nothing about it rather than each saying `EmptyView()`.
    @MainActor @ViewBuilder
    static func underlay(width: CGFloat, height: CGFloat, ink: StripInk) -> EmptyView {
        EmptyView()
    }
}

/// The erased form the renderer, the view and `StripFit` hold.
///
/// A box of closures rather than an `any StripStyle`, for one reason:
/// `cellWidth` has to be callable from `StripFit`, which is pure CoreGraphics,
/// runs off the main actor in tests, and knows nothing about `View`. An
/// existential carrying an `associatedtype Cell: View` cannot be measured
/// without dragging SwiftUI into the width contract, and the width contract is
/// the part that has to stay assertable without a menu bar to look at.
public struct StripStyleBox {
    public let kind: AppearanceSettings.MenuBarStyle
    public let cellWidth: (CGFloat) -> CGFloat
    public let segmentCeiling: Int
    public let sentence: MenuBarStripContent.Sentence
    public let underlay: @MainActor (CGFloat, CGFloat, StripInk) -> AnyView
    public let cell: @MainActor (StripSegment, CGFloat, StripInk) -> AnyView

    public init<S: StripStyle>(_ style: S.Type) {
        self.kind = S.kind
        self.cellWidth = { S.cellWidth(height: $0) }
        self.segmentCeiling = S.segmentCeiling
        self.sentence = S.sentence
        self.underlay = { AnyView(S.underlay(width: $0, height: $1, ink: $2)) }
        self.cell = { AnyView(S.cell($0, height: $1, ink: $2)) }
    }

    /// The registry, and the only `switch` in the feature.
    ///
    /// It is a name-to-type table with one line per style, not a behaviour switch
    /// that grows a branch per style per question. A missing line is a compile
    /// error, because the enum is switched exhaustively and every answer a style
    /// owes is on the type rather than in a case here.
    public static func box(for kind: AppearanceSettings.MenuBarStyle) -> StripStyleBox {
        switch kind {
        case .markAndFigure: return StripStyleBox(MarkAndFigureStyle.self)
        case .figureOnly:    return StripStyleBox(FigureOnlyStyle.self)
        case .markOnly:      return StripStyleBox(MarkOnlyStyle.self)
        case .microBars:     return StripStyleBox(MicroBarsStyle.self)
        case .markAndMeter:  return StripStyleBox(MarkAndMeterStyle.self)
        case .worstOnly:     return StripStyleBox(WorstOnlyStyle.self)
        }
    }

    /// The shipped style, and the one every caller that has not been given a
    /// choice yet draws.
    ///
    /// It exists because `StripFit.width`, `StripFit.fit` and `MenuBarStripView`
    /// are read by the Appearance pane and its tests, which are another change's
    /// files: until the pane grows its chooser it has no style to pass, and the
    /// honest default is the one drawing the strip made before there were six.
    /// Computed rather than stored, because the box holds main-actor closures and
    /// a stored global would be shared mutable state to no purpose — building one
    /// is six assignments.
    public static var markAndFigure: StripStyleBox { box(for: .markAndFigure) }
}

// MARK: - The drawings three styles share

/// A brand mark in its own square box, in whatever ink the style resolved.
///
/// Three styles draw a mark and they must draw the same one: the box is as wide
/// as it is tall, so a wide logo and a narrow one take the same column, and the
/// box comes from `Tokens.Strip.markBox` so a half-point height setting cannot
/// start every boundary after it on a half pixel.
///
/// The ink is a parameter rather than a rule, because the rule differs: under
/// `markAndFigure` and `markAndMeter` the mark carries identity and takes
/// `StripInk.brand`, while under `markOnly` it is the only thing on screen and
/// takes `StripInk.band`. One drawing, two callers' decisions.
@MainActor
public struct StripMark: View {
    public let segment: StripSegment
    public let height: CGFloat
    public let ink: Color

    public init(segment: StripSegment, height: CGFloat, ink: Color) {
        self.segment = segment
        self.height = height
        self.ink = ink
    }

    public var body: some View {
        let box = Tokens.Strip.markBox(height: height)
        Group {
            if let brand = segment.brand {
                SVGShape(pathData: brand.pathData, viewBox: brand.viewBox)
                    .fill(ink)
            } else {
                // No vector for this provider, so its initial stands in. 0.8 of
                // the box because a capital in SF Pro fills about four fifths of
                // its line box, and a letter drawn at the box's own height would
                // out-measure every logo beside it.
                Text(segment.initial)
                    .font(.system(size: box * 0.8, weight: .semibold))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: box, height: box)
    }
}

/// A reserved figure cell with the reading drawn leading-aligned inside it.
///
/// Three styles print a number and all three print it the same way, which is the
/// only arrangement under which the cell can be reserved once. Monospaced
/// because the figures tick every refresh and a proportional face would shift the
/// strip sideways as they do; one point under the mark, because SF Mono's digits
/// sit inside their line box and at the mark's own height they out-measure the
/// logo beside them.
///
/// This is what `MenuBarStripRenderer.figure(for:)` became, and it is still the
/// one place the strip's leading-alignment rule is written down — two doc
/// comments in `DesignSystem.swift` send the reader to the old name.
@MainActor
public struct StripFigure: View {
    public let segment: StripSegment
    public let height: CGFloat
    public let ink: StripInk

    public init(segment: StripSegment, height: CGFloat, ink: StripInk) {
        self.segment = segment
        self.height = height
        self.ink = ink
    }

    public var body: some View {
        Text(segment.figure)
            .font(.system(
                size: Tokens.Strip.figureSize(height: height),
                weight: .semibold,
                design: .monospaced
            ))
            .foregroundStyle(ink.band(segment.percent))
            .lineLimit(1)
            // A reserved cell, and the reason a tabular face was not enough on
            // its own: drawn at its natural width, a service crossing 99 into 100
            // widened the item by a whole cell and shoved every status icon to
            // its left sideways — the same jitter the digits were chosen to
            // prevent, an order of magnitude larger. The cell comes from the
            // widest reading the strip can produce and never from the string in
            // hand, because measuring the current string is what reintroduces it.
            //
            // Leading-aligned, and deliberately unlike every other figure rail in
            // the app. Elsewhere a rail is a vertical column and trailing
            // alignment lines its digits up on one edge. Here the figures are side
            // by side, so there is no column to align to and trailing alignment
            // spends the cell's slack between a figure and its own mark: measured
            // in the bar, a one-digit reading sat `markGap` from the NEXT
            // service's logo and two digit-widths from the logo it belongs to,
            // which reads as "0 ChatGPT" rather than "Claude 0". The cell still
            // reserves the widest reading, so 99 → 100 still cannot shove the
            // status icons sideways; the slack just falls where it does no harm,
            // in front of the next segment gap.
            //
            // This is the one place that decision is written down. Both token docs
            // used to restate it — and both stated it backwards, calling the cell
            // trailing-aligned while the drawing was leading — which is why they
            // now describe the reserved width and send the reader here.
            .frame(width: Tokens.Strip.figureCell(height: height), alignment: .leading)
    }
}

/// A vertical meter column: an empty channel with a fill standing in the bottom
/// of it.
///
/// `microBars` stands one of these on a shared baseline and `markAndMeter` puts
/// one beside a mark, so the drawing is here and the placement is theirs. Both
/// are handed the plot height they want — `meterPlot(height:).plot` above a
/// baseline, `barePlot(height:)` without one — because that is the whole of the
/// difference between them.
@MainActor
public struct StripColumn: View {
    public let percent: Double?
    public let height: CGFloat
    /// The channel's own height. Everything the reading does happens inside it.
    public let plot: CGFloat
    public let ink: StripInk

    public init(percent: Double?, height: CGFloat, plot: CGFloat, ink: StripInk) {
        self.percent = percent
        self.height = height
        self.plot = plot
        self.ink = ink
    }

    public var body: some View {
        let width = Tokens.Strip.meterColumn(height: height)
        let shape = RoundedRectangle(cornerRadius: width * 0.4, style: Tokens.Radius.style)
        ZStack(alignment: .bottom) {
            shape.fill(ink.track)
            if let percent {
                // Zero is drawn as nothing, not as the 1pt stub `AppMark` uses
                // for its own shortest bar: 0% is a reading, and a reading of
                // nothing must not look like a reading of one.
                let level = min(max(percent, 0), 1)
                if level > 0 {
                    shape
                        .fill(ink.band(percent))
                        .frame(height: max(1, (plot * level).rounded()))
                }
            } else {
                // The em dash, drawn. A status-only service has no fill to show
                // and an empty channel would read as 0%, so the stub sits at the
                // channel's mid-height where nothing else ever does — a fill
                // reaching halfway touches the floor, and this does not.
                //
                // Rounded because `(plot - stub) / 2` is a half point at the two
                // odd plots the settings can produce: 8 at a 10pt mark and 14 at a
                // 16pt one under `markAndMeter`. Everything else in the strip is
                // whole and this is not allowed to be the exception.
                let stub = Tokens.Strip.meterPlot(height: height).baseline
                Rectangle()
                    .fill(ink.baseline)
                    .frame(height: stub)
                    .padding(.bottom, ((plot - stub) / 2).rounded())
            }
        }
        .frame(width: width, height: plot)
    }
}
