import SwiftUI
import AppKit

/// One segment of the strip, as this file needs to draw it.
///
/// Every reference this file makes to `MenuBarEntry` goes through `init(_:)`,
/// so the rasteriser is coupled to the strip model at exactly one line. The
/// figure arrives already chosen and already formatted: which services are
/// shown and how their numbers read belongs to the model, and a rasteriser
/// that re-formatted them would be a second copy of those rules to keep in
/// step.
private struct StripSegment: Equatable {
    let serviceID: String
    let displayName: String
    let figure: String
    /// nil for a status-only service. Status-only services have no percentage
    /// and must not be given a fake one, so this is what decides whether the
    /// segment can take a usage tint at all — never a 0 standing in for it.
    let percent: Double?

    init(_ entry: MenuBarEntry) {
        self.serviceID = entry.serviceID
        self.displayName = entry.displayName
        self.figure = entry.figure
        self.percent = entry.percent
    }

    /// `serviceID` is the family, not the account, so two Claude subscriptions
    /// resolve to the one mark without any unpicking here.
    var brand: BrandMark? { BrandMark.mark(for: serviceID) }

    /// What a service with no vector mark falls back to.
    var initial: String {
        let letter = displayName.prefix(1).uppercased()
        return letter.isEmpty ? "?" : letter
    }

    /// Whether the strip is drawn in colour at all.
    ///
    /// A coloured image cannot be a template, so AppKit stops giving it the
    /// menu bar's own light/dark and vibrancy treatment — which is why colour
    /// is only spent when it is actually carrying a reading. Under
    /// `.alertOnly` that means nothing is coloured until something crosses the
    /// warning, and under `.perBar` a strip of status-only services still has
    /// no number to colour.
    static func coloured(
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
    public static func image(
        entries: [MenuBarEntry],
        height: CGFloat,
        colour: AppearanceSettings.MenuBarColour,
        warningThreshold: Double
    ) -> NSImage {
        // What survives the width cap, not what was asked for. Everything below
        // is a statement about the strip on screen — the memo key, the template
        // flag, the sentence VoiceOver reads — so all of it has to be made
        // against the segments that actually get drawn. `MenuBarStripView` fits
        // again, which is a no-op on an already-fitted list and is what keeps the
        // Appearance pane's preview, which builds the view directly, showing the
        // same segments the bar does.
        let drawn = StripFit.fit(entries, limit: entries.count, height: height)
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
            warningThreshold: warningThreshold, dark: dark
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
            height: height,
            colour: colour,
            warningThreshold: warningThreshold,
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
        // announced as though it were being shown.
        image.accessibilityDescription = MenuBarStripContent.accessibilityLabel(drawn)

        memo = Memo(
            segments: segments, height: height, colour: colour,
            warningThreshold: warningThreshold, dark: dark, image: image
        )
        return image
    }

    /// What the status item shows when there is nothing to say yet: no service
    /// reporting, or a render that failed. The app's own mark with every bar
    /// idle, as a template, rather than an empty slot the user cannot find or
    /// click.
    public static func fallbackImage(height: CGFloat) -> NSImage {
        // Keyed on height alone: a template has no colour to go stale when the
        // menu bar changes appearance.
        if let fallback, fallback.height == height { return fallback.image }

        // `AppMark` is what the old `UsageMeterGlyph` became in the reskin: a
        // fixed profile rather than live levels, which is what this slot wanted
        // anyway — the fallback exists precisely when there are no levels.
        let glyph = AppMark(size: height, tint: .black)
        let image = render(glyph, height: height) ?? blankImage(height: height)
        image.isTemplate = true
        image.accessibilityDescription = MenuBarStripContent.accessibilityLabel([])
        fallback = (height, image)
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
    private static var fallback: (height: CGFloat, image: NSImage)?

    private struct Memo {
        let segments: [StripSegment]
        let height: CGFloat
        let colour: AppearanceSettings.MenuBarColour
        let warningThreshold: Double
        let dark: Bool
        let image: NSImage

        func matches(
            segments: [StripSegment],
            height: CGFloat,
            colour: AppearanceSettings.MenuBarColour,
            warningThreshold: Double,
            dark: Bool
        ) -> Bool {
            self.segments == segments
                && self.height == height
                && self.colour == colour
                && self.warningThreshold == warningThreshold
                && self.dark == dark
        }
    }
}

/// The strip itself: one brand mark and one figure per service.
///
/// Four abstract bars could not tell you which service was which. A mark and
/// its own number can, and the mark is what makes the number legible at a
/// glance — so the two travel together and the pair is what gets dropped when
/// the strip has to get shorter.
///
/// Also the Appearance pane's preview, which is why the neutral colour is a
/// parameter: in a window `.primary` is right, but a coloured strip is
/// rasterised into a non-template image where `.primary` resolves once, to
/// black, and disappears on a dark menu bar.
public struct MenuBarStripView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let segments: [StripSegment]
    private let height: CGFloat
    private let colour: AppearanceSettings.MenuBarColour
    private let warningThreshold: Double
    private let neutral: Color

    public init(
        entries: [MenuBarEntry],
        height: CGFloat,
        colour: AppearanceSettings.MenuBarColour,
        warningThreshold: Double,
        neutral: Color = .primary
    ) {
        // The width cap is applied here rather than by the caller so that the
        // status item and the Appearance pane's preview cannot disagree about it:
        // the pane builds this view directly, and the same three services are
        // wider at a 16pt glyph than at a 10pt one. How many the user asked for
        // has already been settled upstream by `MenuBarStripContent.entries`, so
        // the limit passed here is the count in hand and what `fit` is being
        // asked for is the width.
        self.segments = StripFit
            .fit(entries, limit: entries.count, height: height)
            .map(StripSegment.init)
        self.height = height
        self.colour = colour
        self.warningThreshold = warningThreshold
        self.neutral = neutral
    }

    private var isDark: Bool { colorScheme == .dark }

    private var coloured: Bool {
        StripSegment.coloured(segments, colour: colour, warningThreshold: warningThreshold)
    }

    public var body: some View {
        // Both gaps come off `Tokens.Strip`, which is the scale `StripFit`
        // measures the item with — they were two literals in this file, and a
        // drawing that adds up its own numbers while something else adds up the
        // width is a contract that can quietly stop being true. Why they are not
        // on `Tokens.Space` is stated at the token: that scale is calibrated for a
        // 300pt panel and this is a 22pt bar.
        HStack(spacing: Tokens.Strip.segmentGap) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: Tokens.Strip.markGap) {
                    mark(for: segment)
                    figure(for: segment)
                }
            }
        }
        .frame(height: height)
    }

    private func mark(for segment: StripSegment) -> some View {
        Group {
            if let brand = segment.brand {
                SVGShape(pathData: brand.pathData, viewBox: brand.viewBox)
                    .fill(markColour(brand))
            } else {
                // No vector for this provider, so its initial stands in. Drawn
                // in the neutral rather than a brand colour: there is no path
                // here whose luminance we could reason about.
                Text(segment.initial)
                    .font(.system(size: height * 0.8, weight: .semibold))
                    .foregroundStyle(neutral)
            }
        }
        .frame(width: height, height: height)
    }

    private func figure(for segment: StripSegment) -> some View {
        // Monospaced: the figures tick every refresh and a proportional face
        // would shift the whole strip sideways as they do. One point under the
        // mark's box, because SF Mono's digits sit inside their line box and
        // otherwise out-measure the logo beside them.
        Text(segment.figure)
            .font(.system(
                size: Tokens.Strip.figureSize(height: height),
                weight: .semibold,
                design: .monospaced
            ))
            .foregroundStyle(figureColour(segment))
            .lineLimit(1)
            // A reserved cell, and the reason a tabular face was not enough on
            // its own: drawn at its natural width, a service crossing 99 into 100
            // widened the item by a whole cell and shoved every status icon to
            // its left sideways — the same jitter the digits were chosen to
            // prevent, an order of magnitude larger. The cell comes from the
            // widest reading the strip can produce and never from the string in
            // hand, because measuring the current string is what reintroduces it.
            // Leading-aligned, and deliberately unlike every other figure rail in
            // the app. Elsewhere a rail is a vertical column and trailing
            // alignment lines its digits up on one edge. Here the figures are
            // side by side, so there is no column to align to and trailing
            // alignment spends the cell's slack between a figure and its own
            // mark: measured in the bar, a one-digit reading sat markGap from the
            // NEXT service's logo and two digit-widths from the logo it belongs
            // to, which reads as "0 ChatGPT" rather than "Claude 0". The cell
            // still reserves the widest reading, so 99 → 100 still cannot shove
            // the status icons sideways; the slack just falls where it does no
            // harm, in front of the next segment gap.
            .frame(width: StripFit.figureCell(height: height), alignment: .leading)
    }

    /// The mark takes its brand colour only under `.perBar`. `.alertOnly` means
    /// what it says: nothing carries colour until a service crosses the
    /// warning, and then only the figure that crossed it does.
    private func markColour(_ brand: BrandMark) -> Color {
        guard coloured, colour == .perBar else { return neutral }
        return brand.foreground(dark: isDark)
    }

    /// The colour a figure is set in.
    ///
    /// The line is the user's, not the palette's. `UsageTint.color(for:)` samples
    /// the ramp at its own fixed boundaries, so a user who moved the warning down
    /// to 0.70 read amber at 0.75 in the bar while the row underneath was already
    /// red — and under `.alertOnly` with the line under 0.60 the one figure that
    /// crossed it was tinted resting teal, which is an alert drawn in the colour
    /// of "you are fine". At or above the configured warning the figure therefore
    /// takes the top of the ramp, which is the colour
    /// `AppearanceSettings.menuBarTint(for:)` returns for the same reading. Below
    /// it, `.alertOnly` stays neutral and `.perBar` takes the level's own colour.
    ///
    /// That function is restated here rather than called because this view is
    /// handed the two facts as values rather than the settings object: the
    /// rasteriser memoises on its inputs and an `ObservableObject` is not a key it
    /// can compare, so `menuBarColour` and `warningThreshold` *are* that key. The
    /// caution boundary stays the palette's, and only in `.perBar` — it is the one
    /// input that does not reach here, and the distinction it draws, resting
    /// against getting on, is a panel reading rather than a glance at a bar.
    private func figureColour(_ segment: StripSegment) -> Color {
        guard coloured, let percent = segment.percent else { return neutral }
        switch colour {
        // Stated rather than left to the `coloured` guard above to imply it: a
        // monochrome strip is a template, and a template must not acquire a
        // colour at any reading, however near its cap that reading is.
        case .monochrome:
            return neutral
        case .alertOnly:
            return percent >= warningThreshold ? Self.alarm : neutral
        case .perBar:
            return percent >= warningThreshold ? Self.alarm : UsageTint.color(for: percent)
        }
    }

    /// The top of the ramp, asked for as a reading at the cap rather than as a
    /// sample at 0.85: the shipped threshold is a setting, and a colour that
    /// hardcoded it would ignore the user who moved the line.
    private static var alarm: Color { UsageTint.color(for: 1) }
}
