import SwiftUI
import AppKit

// `StripSegment` was declared here, `private`, while there was one drawing. It
// lives in `StripStyle.swift` and is public, because there are six drawings in
// six files and the alternative to one shared segment type is six styles reaching
// into `MenuBarEntry` and six chances to format a percentage differently.

/// Rasterises the menu bar strip into the `NSImage` the status item wants.
///
/// `MenuBarExtra` will not reliably draw a `Shape`-based label, and a finished
/// image is what status items expect anyway: a template image inherits the
/// menu bar's own light/dark and vibrancy treatment for free, and the size is
/// exact rather than whatever SwiftUI negotiates inside the status item.
@MainActor
public enum MenuBarStripRenderer {
    /// The strip as the status item will draw it.
    ///
    /// - Parameters:
    ///   - entries: already ranked and already counted by the strip model. The
    ///     width cap is applied here, so this may be longer than what is drawn.
    ///   - colour: `.monochrome` and `.alertOnly` below the threshold produce a
    ///     template image; anything else is coloured and therefore resolves its
    ///     own neutral against the menu bar's appearance.
    ///   - warningThreshold: where the ramp turns red, and the line `.alertOnly`
    ///     waits for.
    ///   - style: which of the six drawings. The case rather than the box,
    ///     because it is part of the memo key and an enum is comparable where a
    ///     box of closures is not.
    ///   - coloursMarks: `AppearanceSettings.coloursBrandMarks`. It reaches the
    ///     drawing and therefore the key: it is the difference between a Claude
    ///     mark in Anthropic's orange and the same mark in the bar's own ink.
    public static func image(
        entries: [MenuBarEntry],
        height: CGFloat,
        colour: AppearanceSettings.MenuBarColour,
        warningThreshold: Double,
        style: AppearanceSettings.MenuBarStyle,
        coloursMarks: Bool
    ) -> NSImage {
        // Resolved once and handed on. `fit` needs the cell width and the style's
        // ceiling, the view needs the drawing, and the sentence needs the shape —
        // three questions, one table lookup, so the three cannot answer for
        // different styles.
        let box = StripStyleBox.box(for: style)
        // What survives the width cap and the style's ceiling, not what was asked
        // for. Everything below is a statement about the strip on screen — the
        // memo key, the template flag, the sentence VoiceOver reads — so all of it
        // has to be made against the segments that actually get drawn.
        // `MenuBarStripView` fits again, which is a no-op on an already-fitted
        // list and is what keeps the Appearance pane's preview, which builds the
        // view directly, showing the same segments the bar does.
        let drawn = StripFit.fit(entries, limit: entries.count, style: box, height: height)
        let segments = drawn.map(StripSegment.init)
        // Nothing to draw is a state the app spends its first seconds in, and a
        // zero-width status item is one the user can neither find nor click.
        guard !segments.isEmpty else { return fallbackImage(height: height) }

        let coloured = StripSegment.coloured(
            segments, colour: colour, warningThreshold: warningThreshold
        )
        // A template's colours collapse to alpha, so the menu bar's appearance
        // cannot change what it renders — keeping it out of the key that way
        // stops a theme flip from redrawing every monochrome strip.
        //
        // The bar's own paint and not the application's: a dark wallpaper under
        // a Light system paints the menu bar dark, and a neutral resolved
        // against the app would then bake near-black figures and near-black
        // brand marks into a near-black bar. `MenuBarIcon.isDarkMenuBar` answers
        // for the bar, and it is read here at the moment of drawing rather than
        // taken from `MenuBarAppearance`'s published value, which exists to say
        // *when* to redraw.
        let dark = coloured && MenuBarIcon.isDarkMenuBar

        if let memo, memo.matches(
            segments: segments, height: height, colour: colour,
            warningThreshold: warningThreshold, dark: dark,
            style: style, coloursMarks: coloursMarks
        ) {
            // The identical instance, not an equal one: AppKit compares the
            // image by identity and skips the status item update when it is
            // unchanged, which is most refreshes.
            return memo.image
        }

        // A template image is recoloured by AppKit, so black is right for it. A
        // coloured one is not, so its neutral parts have to be resolved here
        // against the menu bar's own appearance — otherwise the figures of the
        // services that are not near their cap render black and vanish on a
        // dark menu bar.
        let neutral: Color = coloured ? (dark ? .white : .black) : .black
        let strip = MenuBarStripView(
            entries: drawn,
            style: box,
            height: height,
            colour: colour,
            warningThreshold: warningThreshold,
            coloursMarks: coloursMarks,
            neutral: neutral
        )
        // `ImageRenderer` draws in the light appearance whatever the menu bar is
        // doing, so the usage ramp would bake its light-panel colours into a
        // dark menu bar. The live preview deliberately does not do this: there
        // it should follow the window it sits in.
        .environment(\.colorScheme, dark ? .dark : .light)

        let image = render(strip, height: height) ?? blankImage(height: height)
        image.isTemplate = !coloured
        // The strip model owns the wording, for the same reason it owns the
        // figures. What it is given is the fitted list: the sentence has to name
        // the services on screen, so a segment the width cap dropped must not be
        // announced as though it were being shown. And the shape is the style's,
        // because three of the six draw their reading as a tint or a bar height
        // and VoiceOver can hear neither.
        //
        // This is now the *only* sentence: `MenuBarLabel` reads it back off the
        // image rather than building a second one from the unfitted list, which is
        // what it used to do — three services announced, two drawn.
        image.accessibilityDescription = MenuBarStripContent.accessibilityLabel(
            drawn, sentence: box.sentence, warningThreshold: warningThreshold
        )

        memo = Memo(
            segments: segments, height: height, colour: colour,
            warningThreshold: warningThreshold, dark: dark,
            style: style, coloursMarks: coloursMarks, image: image
        )
        return image
    }

    /// What the status item shows when there is nothing to say yet: no service
    /// reporting, or a render that failed. The app's own mark, as a template,
    /// rather than an empty slot the user cannot find or click.
    public static func fallbackImage(height: CGFloat) -> NSImage {
        // The mark's own box, and not the height that was asked for. `AppMark`
        // draws in the largest even whole point that fits — 12 for the 13 the
        // strip ships at — and a canvas of any other size hands the status item an
        // image whose ink does not fill it. That matters twice over. An odd canvas
        // centres in the 22pt bar on a half point, (22 − 13) / 2 = 4.5, which at 1×
        // splits the baseline and all four bar tops across two device rows each;
        // and `menuBarGlyphHeight` reaches here as a `Double` that has been through
        // a slider, so a fractional canvas is a resample of the whole mark on every
        // display, retina included.
        let box = AppMarkGeometry(size: height).box

        // Keyed on the box and not on the request, so the heights that draw the
        // same mark share one bitmap instead of holding two identical ones. A
        // template has no colour to go stale when the menu bar changes appearance,
        // so the box is the whole key.
        if let fallback, fallback.box == box { return fallback.image }

        // `AppMark` is what the old `UsageMeterGlyph` became in the reskin: a fixed
        // mark rather than live levels, which is what this slot wanted anyway —
        // the fallback exists precisely when there are no levels.
        let glyph = AppMark(size: box, tint: .black)
        let image = render(glyph, height: box) ?? blankImage(height: box)
        image.isTemplate = true
        // The empty-state sentence is the same in all three shapes — there is
        // nothing to band and nothing to call closest to its cap — so which one is
        // asked for here says nothing. `.figures` because that is the shipped
        // style, and the fallback is not keyed on the style for the same reason it
        // is not keyed on the colour: it is the app's mark and no style draws it.
        image.accessibilityDescription = MenuBarStripContent.accessibilityLabel(
            [], sentence: .figures, warningThreshold: 0
        )
        fallback = (box, image)
        return image
    }

    // MARK: - Rasterising

    /// Renders `view` into an image that stays sharp on any display.
    ///
    /// `ImageRenderer.scale` does not reach `nsImage` — measured at 1, 2 and 4,
    /// the representation comes out as one fixed bitmap either way — so a
    /// status item on a retina display gets a blurred strip. `cgImage` does
    /// honour it, so the fix is to rasterise once per scale and hand AppKit a
    /// drawing-handler image: that gives an `NSCustomImageRep` which AppKit
    /// re-invokes at whatever backing scale the destination actually has.
    private static func render(_ view: some View, height: CGFloat) -> NSImage? {
        let measuring = ImageRenderer(content: view)
        var measured = CGSize.zero
        measuring.render { size, _ in measured = size }

        // Integral width: the status item scales a fractional image to fit its
        // slot, and half a point of scaling is enough to smear tabular figures.
        // The strip's width changes with the figures, so this is every refresh.
        let width = max(1, measured.width.rounded(.up))
        let renderer = ImageRenderer(
            content: view.frame(width: width, height: height, alignment: .leading)
        )

        renderer.scale = 1
        let standard = renderer.cgImage
        renderer.scale = 2
        let retina = renderer.cgImage
        guard standard != nil || retina != nil else { return nil }

        // Unflipped, so a CGImage drawn straight into the context keeps its
        // orientation without a transform.
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width)
            guard let bitmap = scale > 1.5 ? (retina ?? standard) : (standard ?? retina) else {
                return false
            }
            context.draw(bitmap, in: rect)
            return true
        }
    }

    /// Last resort when rendering fails: an empty slot of the right size, so
    /// the status item still has something to hit-test.
    private static func blankImage(height: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: max(1, height), height: height))
    }

    // MARK: - Memo

    /// One entry, not a dictionary. The strip is redrawn on every refresh and
    /// almost always with the same inputs; what matters is returning the same
    /// instance for the current state, not remembering old ones.
    private static var memo: Memo?
    /// The fallback's key is `AppMarkGeometry`'s box rather than the height that
    /// was asked for, because that is the size the bitmap actually is: 13 and 12
    /// resolve to the same 12pt mark and must therefore resolve to the same image.
    private static var fallback: (box: CGFloat, image: NSImage)?

    /// Every input the drawing depends on, and the two that were added with the
    /// styles are the two worth naming.
    ///
    /// A `style` or a `coloursMarks` in the signature but not in the key is the
    /// worst shape this bug can take: the user picks a style, the Appearance
    /// pane's preview updates because it builds the view directly, and the menu
    /// bar keeps the previous bitmap because AppKit compares by identity and this
    /// handed back the same instance. The setting looks broken while the preview
    /// says it worked.
    private struct Memo {
        let segments: [StripSegment]
        let height: CGFloat
        let colour: AppearanceSettings.MenuBarColour
        let warningThreshold: Double
        let dark: Bool
        let style: AppearanceSettings.MenuBarStyle
        let coloursMarks: Bool
        let image: NSImage

        func matches(
            segments: [StripSegment],
            height: CGFloat,
            colour: AppearanceSettings.MenuBarColour,
            warningThreshold: Double,
            dark: Bool,
            style: AppearanceSettings.MenuBarStyle,
            coloursMarks: Bool
        ) -> Bool {
            self.segments == segments
                && self.height == height
                && self.colour == colour
                && self.warningThreshold == warningThreshold
                && self.dark == dark
                && self.style == style
                && self.coloursMarks == coloursMarks
        }
    }
}

/// The strip itself: one style's cell per service, laid out on the segment gap.
///
/// Four abstract bars could not tell you which service was which, so every
/// segment now names the service it measures. What that segment *looks* like is
/// the style's — six of them, one file each in `Sources/Views/StripStyles/` — and
/// this view is what is left when the drawing is somebody else's: fit the list,
/// resolve the colour rules once, lay the cells out, put the run's underlay
/// behind them.
///
/// It used to hold a `switch` in `body`, a second in `markColour`, a third in
/// `figureColour` and a fourth would have been needed for the sentence. All four
/// are gone: `StripInk` answers the colour questions and `StripStyleBox` answers
/// the rest, so a seventh style is a new file and one line in the registry rather
/// than four branches spread over this one.
///
/// `mark(for:)` and `figure(for:)` went with them, to `StripMark` and
/// `StripFigure` in `StripStyle.swift`: three of the six styles draw a mark and
/// three draw a figure, so both are shared drawings rather than private methods
/// here. `Tokens.Ramp.figureDesign` and `Tokens.Strip.figureCell` name
/// `StripFigure` as where the leading-alignment rule is written down, which is
/// where it moved to; they named the deleted method here for a release, which is
/// the failure mode a cross-reference to a *method* has and a cross-reference to
/// a type does not.
///
/// Also the Appearance pane's preview, which is why the neutral colour is a
/// parameter: in a window `.primary` is right, but a coloured strip is
/// rasterised into a non-template image where `.primary` resolves once, to
/// black, and disappears on a dark menu bar.
public struct MenuBarStripView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let segments: [StripSegment]
    private let style: StripStyleBox
    private let height: CGFloat
    private let colour: AppearanceSettings.MenuBarColour
    private let warningThreshold: Double
    private let coloursMarks: Bool
    private let neutral: Color

    /// `style` and `coloursMarks` carry defaults for the reason `StripFit.width`
    /// does: the Appearance pane builds this view directly and belongs to the
    /// change that gives it a chooser. The defaults are what the strip drew before
    /// there were six styles, so nothing the pane draws moves until it asks for
    /// something else.
    public init(
        entries: [MenuBarEntry],
        style: StripStyleBox = .markAndFigure,
        height: CGFloat,
        colour: AppearanceSettings.MenuBarColour,
        warningThreshold: Double,
        coloursMarks: Bool = true,
        neutral: Color = .primary
    ) {
        // The width cap is applied here rather than by the caller so that the
        // status item and the Appearance pane's preview cannot disagree about it:
        // the pane builds this view directly, and the same three services are
        // wider at a 16pt glyph than at a 10pt one. How many the user asked for
        // has already been settled upstream by `MenuBarStripContent.entries`, so
        // the limit passed here is the count in hand and what `fit` is being
        // asked for is the width — and, since the styles landed, the style's own
        // ceiling as well.
        self.segments = StripFit
            .fit(entries, limit: entries.count, style: style, height: height)
            .map(StripSegment.init)
        self.style = style
        self.height = height
        self.colour = colour
        self.warningThreshold = warningThreshold
        self.coloursMarks = coloursMarks
        self.neutral = neutral
    }

    public var body: some View {
        // The frame is stated rather than left to the sum of the cells, and that
        // is what makes "the rasterised width is `ceil(StripFit.width(…))`" true by
        // construction instead of by six styles each happening to add up to the
        // number `StripFit` predicted for them.
        let width = StripFit.width(segments: segments.count, style: style, height: height)
        // Whole points, always. The height tuner offered half steps and the
        // rasteriser rounds only the total, so an unrounded box put every interior
        // boundary between pixels and a 13.5pt strip read softer than a 13pt one.
        let box = Tokens.Strip.markBox(height: height)
        let ink = StripInk(
            neutral: neutral,
            colour: colour,
            warningThreshold: warningThreshold,
            isDark: colorScheme == .dark,
            coloursMarks: coloursMarks,
            carriesColour: StripSegment.coloured(
                segments, colour: colour, warningThreshold: warningThreshold
            )
        )

        // The gap comes off `Tokens.Strip`, which is the scale `StripFit` measures
        // the item with — it was a literal in this file, and a drawing that adds up
        // its own numbers while something else adds up the width is a contract that
        // can quietly stop being true. Why it is not on `Tokens.Space` is stated at
        // the token: that scale is calibrated for a 300pt panel and this is a 22pt
        // bar.
        HStack(spacing: Tokens.Strip.segmentGap) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                style.cell(segment, height, ink)
            }
        }
        .frame(width: width, height: box)
        // Behind the whole run rather than behind a cell: the micro bars' baseline
        // is what binds n columns into one chart, and it is the only thing any
        // style draws here. The underlay states its own alignment inside the box,
        // because a background is centred and a baseline is not.
        .background(style.underlay(width, height, ink))
    }
}
