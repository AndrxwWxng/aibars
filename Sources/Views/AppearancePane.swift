import SwiftUI

/// The Appearance pane of Settings: presets first, then one section per part of
/// the app they change, beside a sample panel that redraws as the controls move.
///
/// The sample is pinned beside the form rather than sitting in it. Every setting
/// here is judged by looking at something, and a preview that scrolls off the
/// top the moment you reach the meter section is a preview you have to remember
/// instead of read.
///
/// The sample is assembled from the panel's own parts — `PanelHeader`,
/// `UsageBar`, `UsageFigure`, `UsageRing`, `MetricCaption`, `SecondaryChip`,
/// `OverflowChip`, `RowActions`, `RowSpineView` — measured by the panel's own
/// `RowGeometry`, and topped by the status item's own `MenuBarStripView`. Nothing
/// here is a copy of any of them. `ProviderRow` itself needs an
/// `AnyUsageProvider`, which only exists wrapped around a Keychain lookup and a
/// network fetch, but everything below that row takes a plain `UsageMetric`.
///
/// Every copy this file ever held drifted, and each drift is the same bug: they
/// hovered by inserting buttons the panel is forbidden from inserting, they spaced
/// their captions on numbers the panel had since retuned, they worked out a
/// leading column and a figure rail the panel had stopped agreeing with, and they
/// drew a track where the panel draws a track with a line of context under it.
/// The last of those made every preset's preview shorter than the row it
/// previewed. So the rule is not "keep the copies in step" — it is that there are
/// no copies.
public struct AppearancePane: View {
    @ObservedObject private var appearance: AppearanceSettings

    /// The rule between the form and the preview is a hairline, and a hairline is
    /// the first thing a low-contrast display loses.
    @Environment(\.colorSchemeContrast) private var contrast

    /// A stored dependency rather than an `@EnvironmentObject`, like every other
    /// appearance-driven view here: the settings window is an `NSHostingView`
    /// built with only `AppState` in its environment, and a missing environment
    /// object is a crash on the way in, not a fallback.
    ///
    /// Resolved in the body rather than as a default argument — a default
    /// argument is evaluated at the call site, and `shared` is main-actor
    /// isolated, so that would constrain who is allowed to build the pane.
    public init(appearance: AppearanceSettings? = nil) {
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    public var body: some View {
        // Preview beside the controls, not beneath them. Underneath, it
        // competed with the form for a 520pt window and the thing you were
        // adjusting sat off the bottom edge; alongside, a change and its effect
        // are visible at the same time.
        HStack(spacing: 0) {
            Form {
                presetSection
                sizeSection
                rowLayoutSection
                rowContentSection
                meterSection
                listSection
                menuBarSection
                resetSection
            }
            .formStyle(.grouped)
            // At least as wide as the other panes were before the preview
            // existed, so adding it did not narrow the controls. The window's
            // own minimum is derived from this and the preview column.
            .frame(minWidth: Tokens.Control.formMinWidth)

            columnRule
            preview
        }
    }

    /// The rule between the controls and the sample.
    ///
    /// A `Rectangle` rather than a `Divider`, like every other rule in the app:
    /// the app has one rule weight and one rule colour, and `Divider` carries its
    /// own material and its own weight with it. It was also the one rule here that
    /// did not step up under increased contrast, because a `Divider` held at half
    /// opacity is a second treatment nothing else could agree with.
    private var columnRule: some View {
        Rectangle()
            .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
            .frame(width: Tokens.Control.hairline)
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Tokens.Control.presetChip), spacing: Tokens.Space.small)],
                alignment: .leading,
                spacing: Tokens.Space.small
            ) {
                ForEach(AppearanceSettings.Preset.allCases) { preset in
                    SelectableChip(
                        title: preset.label,
                        isSelected: appearance.matchingPreset == preset,
                        help: preset.summary
                    ) {
                        appearance.apply(preset)
                    }
                }
            }
            .padding(.vertical, Tokens.Space.tight)
        } header: {
            Text("Presets")
        } footer: {
            // The summary is long enough to be a paragraph, so it goes where the
            // pane already puts prose rather than inside a chip.
            SectionFooter(appearance.matchingPreset?.summary
                          ?? "Custom. Picking a preset replaces everything below except your accent colour and manual order.")
        }
    }

    // MARK: - Size

    private var sizeSection: some View {
        Section {
            Picker("Density", selection: $appearance.density) {
                ForEach(AppearanceSettings.Density.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            TunerRow(
                title: "Text size",
                value: $appearance.textScale,
                range: 0.85...1.30,
                step: 0.05,
                readout: percentLabel
            )
            TunerRow(
                title: "Panel width",
                value: $appearance.panelWidth,
                range: 300...520,
                step: 4,
                readout: pointReadout
            )
        } header: {
            Text("Size")
        } footer: {
            SectionFooter("Density moves padding, spacing, type and the size of the dials together. Text size scales the type on top of it, so tight rows with large type is a combination you can have. Bar thickness is its own setting, under the usage meter.")
        }
    }

    // MARK: - Rows

    private var rowLayoutSection: some View {
        Section("Rows") {
            Picker("Provider logos", selection: $appearance.logoStyle) {
                ForEach(AppearanceSettings.LogoStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            if appearance.logoStyle != .hidden {
                TunerRow(
                    title: "Logo size",
                    value: $appearance.logoSize,
                    range: 18...40,
                    step: 1,
                    readout: pointReadout
                )
            }
            Picker("Row background", selection: $appearance.rowBackground) {
                ForEach(AppearanceSettings.RowBackground.allCases) { background in
                    Text(background.label).tag(background)
                }
            }
            Picker("Row buttons", selection: $appearance.rowActions) {
                ForEach(AppearanceSettings.RowActionVisibility.allCases) { visibility in
                    Text(visibility.label).tag(visibility)
                }
            }
        }
    }

    private var rowContentSection: some View {
        Section {
            Toggle("Percentage", isOn: $appearance.showsPercentage)
            Toggle("Raw counts", isOn: $appearance.showsAmounts)
            Toggle("Reset countdowns", isOn: $appearance.showsCountdowns)
            Toggle("Plan names", isOn: $appearance.showsPlanNames)
            Toggle("Account labels", isOn: $appearance.showsAccountLabels)

            Picker("Extra usage windows", selection: $appearance.secondaryWindows) {
                ForEach(AppearanceSettings.SecondaryWindowStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            if appearance.secondaryWindows != .hidden {
                CountStepper(
                    title: "Windows per service",
                    value: $appearance.secondaryWindowLimit,
                    range: 1...6
                )
            }
        } header: {
            Text("What each row shows")
        } footer: {
            SectionFooter(rowContentFooter)
        }
    }

    /// The percentage switch is the one control here that a meter setting can
    /// overrule, and the preview obeying it is otherwise indistinguishable from
    /// the preview being broken.
    private var rowContentFooter: String {
        var lines = ["The extra windows are where a row's height goes: four of them is four bars and four lines of text under one service. As chips they share one line instead, so a narrow panel or large type fits fewer of them than the limit allows."]
        if appearance.meterStyle == .numberOnly {
            lines.append("With the number-only meter the percentage stays on whatever that switch says — it is the only usage left on the row.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Meter

    private var meterSection: some View {
        Section {
            Picker("Usage meter", selection: $appearance.meterStyle) {
                ForEach(AppearanceSettings.MeterStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            if appearance.drawsMeter {
                TunerRow(
                    title: "Thickness",
                    value: $appearance.meterThickness,
                    range: 3...12,
                    step: 0.5,
                    readout: pointReadout
                )
            }

            Picker("Colour", selection: $appearance.colorRamp) {
                ForEach(AppearanceSettings.ColorRamp.allCases) { ramp in
                    Text(ramp.label).tag(ramp)
                }
            }
            // Nothing but the accent ramp reads this colour, so under any other
            // scheme the well sits there taking choices that change nothing on
            // screen. The stored value survives the trip, as the logo size does
            // while logos are off.
            if appearance.colorRamp == .accent {
                LabeledContent("Accent colour") {
                    HStack(spacing: Tokens.Space.medium) {
                        // Labelled for VoiceOver and then hidden.
                        ColorPicker("Accent colour", selection: appearance.accentColorBinding, supportsOpacity: false)
                            .labelsHidden()
                        if appearance.accentColorHex != nil {
                            Button("Use system") { appearance.accentColorHex = nil }
                                .controlSize(.small)
                        }
                    }
                }
            }

            TunerRow(
                title: "Caution above",
                value: $appearance.cautionThreshold,
                range: cautionRange,
                step: 0.01,
                readout: percentLabel
            )
            TunerRow(
                title: "Warning above",
                value: $appearance.warningThreshold,
                range: warningRange,
                step: 0.01,
                readout: percentLabel
            )
            RampStrip(appearance: appearance, providerAccent: SampleService.claude.accent)
        } header: {
            Text("Usage meter")
        } footer: {
            SectionFooter(meterFooter)
        }
    }

    /// What the two thresholds actually do, which is more than tint a bar.
    ///
    /// The warning threshold is worth spelling out because three of the four
    /// things it moves are not colours: the fill's trailing end squares off, the
    /// figure goes a weight heavier, and the row gains a mark down its leading
    /// edge. Someone reading this pane is choosing where an alarm starts, and an
    /// alarm that survives a greyscale screenshot is a different promise from one
    /// that does not.
    ///
    /// The neutral figure below the caution threshold gets a line of its own for
    /// the opposite reason: it is the one rule here that reads as a bug if it is
    /// not stated. A user who turns everything on and sees a graphite number over
    /// a teal bar has been shown a disagreement, not a hierarchy.
    private var meterFooter: String {
        var lines = ["Every colour scheme still turns to the warning colour above the warning threshold, and that is also where the fill squares off its end, the number goes a weight heavier, and the row takes a mark down its leading edge — so the state survives a greyscale screenshot. The two thresholds cannot cross."]
        if appearance.colorRamp == .usage {
            lines.append("Below the caution threshold the number itself stays graphite while its bar keeps the resting colour: nine coloured numbers in a column have nothing left to say when one of them starts to matter.")
        }
        lines.append("The notch on the track — how far through the window itself you are, against how much of it you have spent — follows the same switch as the pace line under Alerts, so turning the pace off turns the notch off with it. Where the fill has overtaken the notch it is cut back to the panel's own ground, and the fill past the cut is the overspend.")
        return lines.joined(separator: " ")
    }

    /// The two thresholds are held five points apart by the settings themselves,
    /// so the sliders are given the same coupled bounds. With a fixed 30–85 track
    /// and the warning threshold down at 50%, everything above 45% is track the
    /// thumb springs back out of the moment it is dragged there.
    ///
    /// This and `warningRange` mirror `AppearanceSettings`' own clamp, which is
    /// private to that file. They have to stay in step: a track the settings will
    /// not honour is a thumb that jumps back, and one they would have honoured is
    /// a value the user cannot reach.
    private var cautionRange: ClosedRange<Double> {
        // The floor guards the range from inverting rather than describing a
        // reachable state: the warning threshold is itself clamped to 50% and up.
        0.30...max(0.30, min(0.85, appearance.warningThreshold - 0.05))
    }

    private var warningRange: ClosedRange<Double> {
        min(0.98, max(0.50, appearance.cautionThreshold + 0.05))...0.98
    }

    // MARK: - The list

    private var listSection: some View {
        Section {
            Picker("Order", selection: $appearance.sortOrder) {
                ForEach(AppearanceSettings.SortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            Picker("Grouping", selection: $appearance.grouping) {
                ForEach(AppearanceSettings.Grouping.allCases) { grouping in
                    Text(grouping.label).tag(grouping)
                }
            }
            Picker("Not-connected services", selection: $appearance.disconnectedServices) {
                ForEach(AppearanceSettings.DisconnectedDisplay.allCases) { display in
                    Text(display.label).tag(display)
                }
            }
            Toggle("Show every account", isOn: $appearance.showsAllAccounts)
            Toggle("Hide services with no quota", isOn: $appearance.hidesQuotalessServices)
            Toggle("Show header summary", isOn: $appearance.showsHeaderSummary)
        } header: {
            Text("The list")
        } footer: {
            SectionFooter(listFooter)
        }
    }

    /// The two settings here that can make a service vanish get told on, because
    /// "my Copilot row disappeared" is otherwise a bug report.
    private var listFooter: String {
        var lines = ["Sorting by how close a service is to its cap moves rows between refreshes; alphabetical and manual stay put."]
        if appearance.disconnectedServices == .hidden || appearance.hidesQuotalessServices {
            lines.append("Hidden services are still listed under Settings → Services.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Menu bar

    /// The strip is one mark and one figure per service now, so the controls are
    /// about the strip rather than about a mark: how many services it carries,
    /// whether it spends colour, and how tall it is drawn.
    ///
    /// The label style and the highest/average pickers are gone with the four
    /// abstract bars they configured. Neither reaches the status item any more —
    /// the strip has no single aggregate figure to be the highest or the average
    /// of — and a control in this window that changes nothing on screen is worse
    /// than no control at all.
    private var menuBarSection: some View {
        Section {
            CountStepper(
                title: "Services shown",
                value: $appearance.menuBarServiceCount,
                range: MenuBarStripContent.range
            )
            Picker("Strip colour", selection: $appearance.menuBarColour) {
                ForEach(AppearanceSettings.MenuBarColour.allCases) { colour in
                    Text(colour.label).tag(colour)
                }
            }
            TunerRow(
                title: "Strip height",
                value: $appearance.menuBarGlyphHeight,
                range: 10...16,
                step: 0.5,
                readout: pointReadout
            )
            LabeledContent("Preview") {
                MenuBarSample(appearance: appearance)
            }
        } header: {
            Text("Menu bar")
        } footer: {
            SectionFooter("The strip carries one brand mark and its own figure per service, closest to its cap first, so you can tell which number is which. A service that reports a state rather than a quota — ChatGPT's subscription, Copilot's seat — shows a dash instead: an invented 0 reads as plenty left and an invented 100 reads as capped, and neither is a claim the service made. Monochrome leaves the strip a template image, so the menu bar gives it its own light, dark and vibrancy treatment; the other two spend colour and give that up.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to defaults") { appearance.resetToDefaults() }
        } footer: {
            SectionFooter("Returns every option here to how the app shipped, and clears your accent colour and manual order along with them.")
        }
    }

    // MARK: - The live sample

    /// The viewport the column leaves the sample, written down rather than left
    /// to the scroll view: a two-axis `ScrollView` proposes no width to its
    /// content, so a sample narrower than the viewport is placed wherever the
    /// scroller feels like putting it, and its leading edge stops agreeing with
    /// the caption above it.
    ///
    /// A constant, because `Tokens.Control.previewColumn` is one — the column
    /// used to be sized to the panel being previewed, which made the form beside
    /// it 80pt narrower at a 386pt panel than at a 300pt one. That is a form that
    /// re-lays out while the panel-width slider inside it is being dragged.
    private static let sampleViewportWidth: CGFloat =
        Tokens.Control.previewColumn - 2 * Tokens.Space.paneMargin

    private var preview: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.snug) {
            Text("Preview — hovers like the real panel")
                .font(.system(size: Tokens.Ramp.caption))
                .foregroundStyle(.tertiary)

            // Both axes scroll: the panel can be wider than this column and
            // taller than the strip, and hiding the sample is how you end up
            // tuning a setting whose effect is off-screen. Indicators stay on — a
            // comfortable row with six windows is three times this strip, and
            // with no scroller the rest of it reads as missing rather than below.
            ScrollView([.horizontal, .vertical]) {
                SamplePanel(appearance: appearance)
                    // The pane inset is on the column, not in here, so one number
                    // places the caption and the sample.
                    .frame(minWidth: Self.sampleViewportWidth, alignment: .leading)
                    .padding(.bottom, Tokens.Space.large)
            }
        }
        .padding(.top, Tokens.Space.paneMargin)
        .padding(.horizontal, Tokens.Space.paneMargin)
        .frame(width: Tokens.Control.previewColumn)
        .frame(maxHeight: .infinity, alignment: .top)
        // A well, which is what this column is: something sunk below the form
        // beside it for a floating surface to sit in. `Surface.well` rather than
        // a system page colour so the sample's own graphite reads against a
        // ground from the same family instead of a blue-grey one.
        .background(Tokens.Surface.well)
        // The column is the sample's bounds, stated rather than assumed.
        //
        // A scroll view only clips what it was handed a definite size for: given
        // none along an axis, its clip view takes the content's own size and the
        // overflow is drawn outside the scroller instead of scrolled to. The
        // panel's list hit exactly that and put 500pt of rows outside the window;
        // here the sample's trailing percentages turned up a second time down the
        // far side of the window, over the sidebar, which nothing in this pane's
        // own layout can place there. Either way this column is the last thing
        // between the sample and the rest of the window, so it holds the line.
        .clipped()
    }

    private func pointReadout(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value)) pt"
            : String(format: "%.1f pt", value)
    }
}

/// A percentage as the app writes one: rounded, never truncated. The header
/// summary, the sample rows and both threshold sliders read it from here — as
/// four copies of `Int((x * 100).rounded())` they were four chances for one of
/// them to start flooring instead. `MetricCaption` and `AppState.headlineSummary`
/// still spell it out themselves and should not.
private func percentLabel(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

// MARK: - Controls

// The pane's footers are `SectionFooter` from the design system, not a treatment
// of their own: the window has one voice for prose under a section, and eight
// sections writing it out is eight chances to lose it.

/// A labelled slider with its value spelled out beside it. A bare 0.6 next to
/// "Caution above" is a number, not an answer.
private struct TunerRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: Tokens.Space.medium) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: Tokens.Control.sliderWidth)
                Text(readout(value))
                    // `Ramp.figureDesign` is SF Mono, which is what carries the
                    // whole terminal half of the visual system: these readouts
                    // tick under a dragging thumb, and a proportional face makes
                    // the number jitter sideways as they do. The tabular request
                    // stays for the same reason it does at every other figure
                    // site — it costs nothing and does not depend on the design
                    // token staying monospaced.
                    .font(.system(size: Tokens.Ramp.caption, design: Tokens.Ramp.figureDesign))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // A readout wide enough to wrap would take the row's height
                    // with it, and every slider below it would shift down half a
                    // line as the value passed 100.
                    .lineLimit(1)
                    .frame(width: Tokens.Control.readoutWidth, alignment: .trailing)
            }
        }
    }
}

/// A labelled count. Set like a `TunerRow`'s readout — caption type, monospaced,
/// trailing in the same width — because "4 windows" and "62%" are the same kind
/// of answer to the eye running down the pane, and one of them was arriving in
/// body type.
private struct CountStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            Stepper(value: $value, in: range) {
                Text("\(value)")
                    .font(.system(size: Tokens.Ramp.caption, design: Tokens.Ramp.figureDesign))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Tokens.Control.readoutWidth, alignment: .trailing)
            }
        }
    }
}

/// The colour ramp end to end, with the bands where the thresholds currently
/// put them. Two sliders describe the ramp; this is the ramp.
///
/// The meter's ramp, which is now the only thing that takes all three bands: a
/// row's figure holds off until caution under `.usage`, so the low band here is a
/// bar colour and not a digit colour. The strip stays whole anyway — it is the
/// palette being shown, and the sample panel beside it is where the two are drawn
/// against each other.
///
/// It is also the one place the ramp's own palette can be checked at a glance,
/// which matters more now that the low stop is a cool teal rather than a green:
/// teal → amber → red separates on the blue–yellow axis, which deuteranomaly and
/// protanopia both preserve, and green is thereby freed to mean only "this
/// connection is working".
private struct RampStrip: View {
    @ObservedObject var appearance: AppearanceSettings
    let providerAccent: Color

    var body: some View {
        GeometryReader { geo in
            // Stacked from the top of the ramp down rather than laid out side by
            // side: three widths that each round to the nearest point do not add
            // up to the width they were taken from, and the leftover showed as a
            // hairline of window between the last band and the cap.
            ZStack(alignment: .leading) {
                band(from: appearance.warningThreshold, to: 1)
                band(from: appearance.cautionThreshold, to: appearance.warningThreshold)
                    .frame(width: geo.size.width * appearance.warningThreshold)
                band(from: 0, to: appearance.cautionThreshold)
                    .frame(width: geo.size.width * appearance.cautionThreshold)
            }
        }
        .frame(height: Tokens.Space.medium)
        .clipShape(Capsule(style: Tokens.Radius.style))
        .padding(.vertical, Tokens.Space.tight)
    }

    /// Each band is drawn in the colour the ramp gives its own midpoint, so a
    /// scheme that collapses two bands into one colour shows two bands of one
    /// colour rather than a lie.
    private func band(from: Double, to: Double) -> some View {
        Rectangle()
            .fill(appearance.tint(for: (from + to) / 2, providerAccent: providerAccent))
    }
}

/// The status item as configured: the strip itself, drawn by the same view the
/// renderer rasterises for the menu bar.
///
/// Its `neutral` is left at `.primary`, which is right here and wrong there: in
/// a window `.primary` resolves against the window's appearance, while a coloured
/// strip is baked into a non-template image where it would resolve once, to
/// black, and vanish on a dark menu bar. The renderer passes its own; this does
/// not have to.
private struct MenuBarSample: View {
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        MenuBarStripView(
            entries: MenuBarStripContent.entries(
                from: SampleService.stripEntries,
                limit: appearance.menuBarServiceCount
            ),
            height: CGFloat(appearance.menuBarGlyphHeight),
            colour: appearance.menuBarColour,
            warningThreshold: appearance.warningThreshold
        )
    }
}

// MARK: - The sample panel

/// The dropdown, at the configured width, with the header and two services.
private struct SamplePanel: View {
    @ObservedObject var appearance: AppearanceSettings

    /// The rule under the header and the border around the sample are both
    /// hairlines, which a low-contrast display loses first.
    @Environment(\.colorSchemeContrast) private var contrast

    /// Recomputed on each access rather than stored, so the countdowns inside
    /// them stay plausible in a settings window that has been left open. One
    /// list, so the summary above the rows cannot end up describing a different
    /// panel from the rows themselves.
    private var services: [SampleService] { [.claude, .chatgpt] }

    /// The row closest to its cap, which is what the panel hands its header as
    /// `topPercent`. The header draws no instrument from it and no longer changes
    /// colour with it — nothing in the chrome moves with a reading — but the
    /// argument is what the panel passes, and the preview passes what the panel
    /// passes.
    private var worst: SampleService? {
        services.max { $0.primary.percent < $1.primary.percent }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                appearance: appearance,
                levels: SampleService.menuBarLevels,
                topPercent: worst?.primary.percent ?? 0,
                summary: summary
            ) {
                // Images, not buttons: the refresh, settings and quit controls
                // are the only way out of the app and can never be configured
                // away, so the preview shows them without offering to run them.
                // On the button's own footprint, so the cluster sits where the
                // panel's does rather than a few points further out.
                ForEach(["arrow.clockwise", "gearshape", "power"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.Control.iconGlyph, weight: Tokens.Ramp.emphasisWeight))
                        .foregroundStyle(.secondary)
                        .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                }
            }

            headerRule

            VStack(spacing: appearance.metrics.rowGap) {
                ForEach(Array(services.enumerated()), id: \.offset) { entry in
                    SampleRow(appearance: appearance, service: entry.element)
                }
            }
            .padding(.vertical, Tokens.Space.listMargin)
        }
        .frame(width: CGFloat(appearance.panelWidth))
        // A raised surface: the one plane in the app that stands above the ground,
        // and the only one that takes a border.
        //
        // Not a material, and this is the rule rather than a preference — the
        // panel's own scrim is the only translucency in the application, because
        // anything carrying a number has to be drawn on an opaque ground. Every
        // fill above this is a `Color.primary` opacity measured against a known
        // base, and a sample panel that let the settings window's own background
        // through would be nine contrast ratios nobody can state. This is what a
        // preview inside a form looks like: a panel floating on the well beside
        // the controls, at the plane a floating surface is drawn at.
        .background(Tokens.Surface.raised)
        // The sample's own bounds, because the real panel has a window's.
        //
        // A `frame` proposes a width; it does not enforce one. Once the row's
        // buttons and its percentage have both refused to give any — a 300pt
        // panel at 130% type behind a 40pt logo and a dial is that row — the
        // title line is wider than the panel and draws past it. In the menu bar
        // the window cuts that off, which is the honest thing for the preview to
        // show; unclipped it spilled over this border into the strip beside the
        // sample and read as a column of figures that belongs to nothing.
        .clipShape(Tokens.surface(Tokens.Radius.panel))
        .overlay(
            Tokens.surface(Tokens.Radius.panel)
                .strokeBorder(
                    Tokens.quiet(Tokens.borderOpacity(increased: contrast == .increased)),
                    lineWidth: Tokens.Control.hairline
                )
        )
    }

    // MARK: The header rule

    /// The line under the header. Neutral at every usage level, which is the
    /// panel's own behaviour rather than a simplification of it.
    ///
    /// It used to take the worst row's ramp colour above the warning threshold.
    /// That is deleted rather than tuned, here and in the panel together: the
    /// alarm belongs to the row that has the problem — its figure, its
    /// square-capped fill, its spine — and a coloured edge across the chrome names
    /// no service, so there is nothing to act on. It also put hue on the one
    /// element that stays on screen while the list is scrolled, so it shouted for
    /// as long as the panel was left open.
    private var headerRule: some View {
        Rectangle()
            .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
            .frame(height: Tokens.Control.hairline)
    }

    /// The figure is read off the sample rather than typed into the sentence, so
    /// the summary cannot end up claiming a percentage no row in the preview shows.
    private var summary: String {
        "Claude is nearly capped — \(percentLabel(SampleService.claude.primary.percent))"
    }
}

/// One row of the sample, drawn from the panel's own parts and measured by the
/// panel's own `RowGeometry`.
///
/// Internal rather than private, alone among this file's views, so the pane's
/// own tests can measure it against a real `ProviderRow` at the same settings
/// and the same width. A preview that quietly disagrees with the thing it is
/// previewing is the bug this row exists not to have, and it is not a bug that
/// can be caught by looking.
///
/// It reaches for nothing of its own. Every number comes from `RowGeometry` and
/// every mark from a view the panel draws — which is the only arrangement in which
/// "the preview is the panel" is a fact about the code rather than a claim about
/// somebody's diligence. The way this went wrong before was never a wrong constant;
/// it was a second copy of a right one.
struct SampleRow: View {
    @ObservedObject var appearance: AppearanceSettings
    let service: SampleService

    /// Whether the pace notch is drawn, and where in its window a metric is.
    /// Read plainly rather than observed, for the reason `ProviderRow` gives: the
    /// setting lives in a window that is being drawn right now, and the sample is
    /// rebuilt from the settings object beside it whenever anything moves.
    private let trend: UsageTrendStore

    @State private var isHovered = false

    /// Resolved in the init rather than as a default argument, as everywhere else
    /// in the panel: a default argument is evaluated at the call site and the
    /// shared store is main-actor isolated, which would constrain who may build
    /// the sample.
    init(appearance: AppearanceSettings, service: SampleService, trend: UsageTrendStore? = nil) {
        self._appearance = ObservedObject(wrappedValue: appearance)
        self.service = service
        self.trend = trend ?? UsageTrendStore.shared
    }

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }
    private var primary: UsageMetric { service.primary }

    /// Every measurement this row makes, from the one type `ProviderRow` reads.
    ///
    /// This is the fix for the bug the pane's own test exists to catch. The row
    /// and the row it previews each worked out their leading column, their figure
    /// rails and their chip ceiling privately — the same arithmetic written twice
    /// — and the two drifted, which is precisely how a preview comes to describe a
    /// panel the app does not draw. Neither computes geometry any more, and the
    /// agreement is therefore structural rather than a pair of numbers somebody
    /// has to keep in step by hand.
    private var geometry: RowGeometry {
        RowGeometry(
            metrics: metrics,
            showsPercentage: appearance.showsPercentage,
            meterStyle: appearance.meterStyle,
            logoStyle: appearance.logoStyle,
            logoSize: CGFloat(appearance.logoSize),
            panelWidth: CGFloat(appearance.panelWidth),
            lines: lines
        )
    }

    /// Which optional lines this row draws, which is the one part of its geometry
    /// the row alone knows.
    ///
    /// `.meter` unconditionally: the sample's headline window carries a real
    /// quota, so its slot is occupied at every meter style — and under the ring
    /// `RowGeometry` drops the slot itself, because the dial in the leading column
    /// is the meter there.
    ///
    /// `.forecast` never. The preview has no history behind it, and a pace line in
    /// a preview would be the app showing a projection it never made.
    private var lines: RowGeometry.Lines {
        var drawn: RowGeometry.Lines = [.meter]
        if primaryCaption.hasContent { drawn.insert(.window) }
        return drawn
    }

    /// Whether the trailing figure is drawn, read off the rail rather than
    /// restated.
    ///
    /// The rule — with `numberOnly` the percentage *is* the meter, so it outlives
    /// the percentage switch — belongs to `RowGeometry`, which closes the rail for
    /// the whole panel when there is no figure to put in it. Asking the rail is
    /// how this row cannot come to disagree with the width it reserved.
    private var showsNumber: Bool { geometry.headlineRail > 0 }

    var body: some View {
        // Top alignment lines a 40pt logo up with the name; a row with nothing
        // under its title is one line of type, which top alignment would leave
        // hanging from the ceiling of that logo.
        HStack(alignment: drawsDetail ? .top : .center,
               spacing: hasLeading ? Tokens.Space.leadingColumn : 0) {
            leading
            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                titleLine
                detail
            }
        }
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .padding(.vertical, metrics.rowVerticalPadding)
        .background(
            // `geometry.cardRadius` rather than `Radius.row`: 8pt is right for a
            // 49pt comfortable row and eats the corners of a 27pt compact one.
            Tokens.surface(geometry.cardRadius)
                .fill(Tokens.quiet(Tokens.rowBackground(appearance.rowBackground, isHovered: isHovered)))
                // Held inside the gutter so a hovered card floats rather than
                // touching the panel edge.
                .padding(.horizontal, Tokens.Space.cardInset)
        )
        // Over the card, so the mark sits on it. An overlay costs no layout at
        // all, which is what lets the spine come and go without the row changing
        // height — and a preview that draws the panel's own silhouette has to
        // draw the one vertical mark in it.
        .overlay(alignment: .leading) { spine }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    // MARK: The spine

    /// The 2pt bookmark that means "this row wants you".
    ///
    /// The sample's headline window sits past the warning threshold at every
    /// preset, so the preview shows the mark it is there to show — and the second
    /// service, mid-window, shows a row without one. Two rows is the smallest
    /// panel that can demonstrate a mark whose whole meaning is that most rows do
    /// not have it.
    ///
    /// `RowSpine` decides both whether there is a mark and what ink it takes,
    /// including the `.mono` case where it draws `Color.primary` — the presence of
    /// the mark is a non-colour channel and has to survive a user who asked for no
    /// colour at all. The sample is connected and answering, so the only reason it
    /// can produce here is `nearCap`; the two state reasons belong to rows this
    /// preview does not draw.
    @ViewBuilder
    private var spine: some View {
        if let reason = RowSpine.reason(
            percent: primary.percent,
            warningThreshold: appearance.warningThreshold,
            error: nil,
            isConnected: true
        ) {
            RowSpineView(reason: reason, ramp: appearance.colorRamp, tint: tint(for: primary))
                // Held off the card's top and bottom so it reads as a bookmark in
                // the card, and in from the row's edge by the same inset the card
                // itself is held at — otherwise the mark stands in the gutter
                // beside the card rather than on it.
                .padding(.vertical, Tokens.Control.spineInset)
                .padding(.leading, Tokens.Space.cardInset)
        }
    }

    // MARK: Leading column

    /// False collapses the gap along with the column, as the panel's rows do: an
    /// 11pt indent in front of nothing reads as a broken layout, not a text list.
    /// Read off the geometry, which is the one place that decision is made.
    private var hasLeading: Bool { geometry.leadingWidth > 0 }

    /// Whether anything is drawn under the title line at all, which decides
    /// whether the leading column has a stack to align to or a single line.
    ///
    /// The same predicate the panel's row uses, minus the branches this preview
    /// cannot reach: the sample is always connected, always answering, always
    /// carries a quota, and has no spend for a budget line to be drawn from. The
    /// alignment has to agree with the panel's, and the panel is what this is a
    /// preview of.
    private var drawsDetail: Bool {
        // Every style but the ring draws its meter in the text column, and that
        // slot is occupied on every row.
        guard appearance.meterStyle == .ring else { return true }
        if primaryCaption.hasContent { return true }
        return appearance.secondaryWindows != .hidden && !service.secondary.isEmpty
    }

    @ViewBuilder
    private var leading: some View {
        if hasLeading {
            HStack(spacing: Tokens.Space.leadingItems) {
                if appearance.logoStyle != .hidden {
                    ProviderLogo(
                        providerID: service.serviceID,
                        fallbackName: service.displayName,
                        fallbackColor: service.accent,
                        size: appearance.logoSize,
                        showsTile: appearance.logoStyle == .tile
                    )
                }
                if appearance.meterStyle == .ring {
                    // The panel's own dial rather than a circle drawn here: it
                    // keeps a hole at any thickness and insets its own arc, so a
                    // 12pt meter on a compact 15pt ring stays a ring instead of
                    // a disc overhanging the logo and the text beside it.
                    //
                    // Handed both pace channels, because the dial carries the
                    // same instrument the bar does: the elapsed share of its
                    // track, the mark at the boundary, and the cut through the arc
                    // where the fill has overtaken it.
                    UsageRing(
                        percent: primary.percent,
                        diameter: metrics.ringDiameter,
                        thickness: metrics.barHeight,
                        tint: tint(for: primary),
                        elapsed: elapsed(for: primary),
                        isNearCap: ProviderRow.isNearCap(
                            percent: primary.percent,
                            warning: appearance.warningThreshold
                        )
                    )
                }
            }
            .padding(.top, Tokens.Space.hairline)
        }
    }

    // MARK: Title

    private var titleLine: some View {
        HStack(spacing: Tokens.Space.small) {
            // The row's subject, and the one thing on the line that is a word
            // rather than a reading. It carries the title weight; the figure at the
            // end earns its own emphasis from its size and from the ramp, so at
            // rest the name is the heavier of the two.
            Text(service.displayName)
                .font(.system(size: metrics.titleSize, weight: Tokens.Ramp.titleWeight))
                .foregroundStyle(.primary)
                .lineLimit(1)
                // The name takes its width before the account label and the
                // pill, which is the panel's own rule for a 300pt row.
                .layoutPriority(1)

            if appearance.showsAccountLabels {
                Text(service.account)
                    .font(.system(size: metrics.captionSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }

            if appearance.showsPlanNames {
                Text(service.plan)
                    .font(.system(size: metrics.detailSize))
                    // A pill that wraps to a second line stops being a pill.
                    .lineLimit(1)
                    .padding(.horizontal, Tokens.Space.small)
                    .padding(.vertical, Tokens.Space.hairline)
                    .background(Capsule().fill(Tokens.quiet(Tokens.Fill.pill)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Tokens.Space.snug)

            // The panel's own buttons, which reserve their space and change only
            // opacity. Inserting them on hover — what this row used to do — moved
            // the percentage beside them and the row's whole height every time the
            // pointer crossed it, in a preview whose job is to hold still while
            // you adjust the thing next to it.
            RowActions(
                visibility: appearance.rowActions,
                isHovered: isHovered,
                hasDashboard: true,
                refreshHelp: "Refresh \(service.displayName)"
            )

            trailingValue
        }
    }

    /// The figure rail, held whether or not there is a figure in it.
    ///
    /// The panel's own `UsageFigure` rather than a pair of `Text`s written here:
    /// the digits, the smaller unit tick beside them and the shared baseline are
    /// the panel's treatment, and a second copy of it in the one view whose job is
    /// to show what the panel looks like is a copy that will drift.
    ///
    /// Three channels of the near-cap contract meet on this line. The weight comes
    /// from `ProviderRow.figureWeight`, which is the panel's own pure function of
    /// the reading and the threshold, so the preview cannot step at a different
    /// point from the row. The colour comes from `figureTint`, which holds the
    /// digits graphite below the caution threshold under the usage ramp — a panel
    /// of nine coloured numbers has spent its whole colour budget on the least
    /// informative state it has, and this is how colour arriving on a number
    /// becomes the news. The unit tick is neutral in every band, because it
    /// annotates the number rather than being part of the reading.
    @ViewBuilder
    private var trailingValue: some View {
        if showsNumber {
            UsageFigure(
                percent: primary.percent,
                size: metrics.figureSize,
                unitSize: metrics.unitSize,
                weight: ProviderRow.figureWeight(
                    percent: primary.percent,
                    warning: appearance.warningThreshold
                ),
                tint: appearance.figureTint(for: primary.percent, providerAccent: service.accent),
                animatesDigits: true
            )
            // Reserved, never measured: tabular digits fix the width of a digit
            // and not the length of a string, so "9%" would otherwise reflow to
            // "92%" and drag the label beside it.
            .frame(width: geometry.headlineRail, alignment: .trailing)
            .layoutPriority(1)
        } else {
            // The rail stands empty rather than closing up — and closes for the
            // whole panel, never row by row, which `RowGeometry` is what decides.
            Color.clear
                .frame(width: geometry.headlineRail, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Body

    /// The panel's `primaryMetric` and `secondaryWindows`, in the same order and
    /// on the same spacing.
    ///
    /// It draws `UsageBar` and not a bare `MeterSlot`, which is the whole of the
    /// height bug the pane's test catches: a slot is a track, and the panel draws a
    /// track *and* the line of context under it. A sample missing that line was
    /// short of a real row by a caption and a gap on every preset the app ships.
    @ViewBuilder
    private var detail: some View {
        primaryMeter
        secondaryWindows
    }

    /// The headline window, drawn by the same switch the panel's row uses.
    ///
    /// The quotaless branch the panel keeps has nothing to draw here — the
    /// sample's headline window carries a real quota — and the pace line the panel
    /// puts between this and the further windows is deliberately absent: it draws
    /// only when the samples support a claim, and the preview has no samples.
    @ViewBuilder
    private var primaryMeter: some View {
        switch appearance.meterStyle {
        case .bar, .numberOnly:
            // One view for both, as in the panel, because the difference between
            // them is what fills the meter slot rather than whether there is one.
            // The cut, the two-tone track and the squared-off fill all come with
            // it rather than being drawn a second time here.
            UsageBar(
                metric: primary,
                accent: service.accent,
                appearance: appearance,
                trend: trend
            )
        case .ring:
            // The dial in the leading column and the trailing figure are the meter
            // here, so only the context line is left — and with both its halves
            // switched off the row is one line.
            if primaryCaption.hasContent { primaryCaption }
        }
    }

    /// The line under the headline meter, asked for twice — once to draw and once
    /// to decide whether the row has a second line at all — so it is named rather
    /// than built at each site.
    private var primaryCaption: MetricCaption { caption(for: primary, isSecondary: false) }

    /// Chips are a single unwrapped line, so their ceiling is width rather than a
    /// count: 520pt of empty panel takes all six, 300pt behind a 40pt logo at
    /// 130% type takes one.
    ///
    /// `RowGeometry` owns the width half and the caller owns the count half, which
    /// is `secondaryWindowLimit` — so the stepper cannot appear to promise chips
    /// the row will never draw, and the preview cannot show a different number of
    /// them than the panel will.
    private var chipLimit: Int {
        min(
            appearance.secondaryWindowLimit,
            RowGeometry.chipLimit(
                textColumnWidth: geometry.textColumnWidth,
                captionSize: metrics.captionSize
            )
        )
    }

    /// How the windows split between chips of their own and the "+N" standing for
    /// the rest. The panel's rule: the overflow chip takes a slot off the line
    /// rather than being added to it, since pushed past the trailing edge it would
    /// be truncated away — which is the failure it exists to report — and one real
    /// chip is always kept, because "+6" alone names no window at all.
    private func chipSplit(_ count: Int) -> (shown: Int, hidden: Int) {
        let limit = chipLimit
        guard count > limit else { return (count, 0) }
        let shown = max(1, limit - 1)
        return (shown, count - shown)
    }

    @ViewBuilder
    private var secondaryWindows: some View {
        if !service.secondary.isEmpty {
            switch appearance.secondaryWindows {
            case .hidden:
                EmptyView()
            case .expanded:
                // On the enclosing VStack's own spacing with nothing added on top,
                // as in the panel: the pitch from the primary meter to the first
                // secondary one is then the pitch between two secondaries, so the
                // third window of one service sits on the same line as the third of
                // the next.
                VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                    ForEach(numbered(appearance.secondaryWindowLimit), id: \.offset) { window in
                        secondaryWindow(window.element)
                    }
                }
            case .chips:
                let split = chipSplit(service.secondary.count)
                HStack(spacing: Tokens.Space.snug) {
                    ForEach(numbered(split.shown), id: \.offset) { window in
                        SecondaryChip(
                            metric: window.element,
                            accent: service.accent,
                            appearance: appearance
                        )
                    }
                    if split.hidden > 0 {
                        OverflowChip(count: split.hidden, appearance: appearance)
                    }
                }
            }
        }
    }

    /// One further window, drawn as the panel draws it. Every window the sample
    /// carries has a ceiling, so the valueless branch the panel keeps for a metric
    /// with no limit has nothing to draw here.
    @ViewBuilder
    private func secondaryWindow(_ metric: UsageMetric) -> some View {
        switch appearance.meterStyle {
        case .bar, .numberOnly:
            UsageBar(
                metric: metric,
                isSecondary: true,
                accent: service.accent,
                appearance: appearance,
                trend: trend
            )
        case .ring:
            // Indented by its own dial, the way the row's content is indented by
            // the primary one: a dial always precedes the thing it measures.
            HStack(spacing: Tokens.Space.small) {
                UsageRing(
                    percent: metric.percent,
                    diameter: metrics.ringDiameter * 0.55,
                    thickness: metrics.secondaryBarHeight,
                    tint: tint(for: metric),
                    elapsed: elapsed(for: metric),
                    isNearCap: ProviderRow.isNearCap(
                        percent: metric.percent,
                        warning: appearance.warningThreshold
                    )
                )
                caption(for: metric, isSecondary: true)
            }
        }
    }

    /// Keyed on position rather than on the window's name: a service can report
    /// two windows under one label, and a repeated `ForEach` id draws one of them
    /// and silently drops the rest.
    private func numbered(_ limit: Int) -> [(offset: Int, element: UsageMetric)] {
        Array(service.secondary.prefix(limit).enumerated())
    }

    private func caption(for metric: UsageMetric, isSecondary: Bool) -> MetricCaption {
        MetricCaption(
            metric: metric,
            isSecondary: isSecondary,
            accent: service.accent,
            appearance: appearance
        )
    }

    private func tint(for metric: UsageMetric) -> Color {
        appearance.tint(for: metric.percent, providerAccent: service.accent)
    }

    /// Where in its window a metric is, asked the way the panel asks it — so the
    /// dial and the bar in the preview cannot disagree with each other or with the
    /// row they stand for about whether the pace mark is drawn at all.
    private func elapsed(for metric: UsageMetric) -> Double? {
        MeterSlot.elapsed(for: metric, showsPace: trend.showsPaceInPanel)
    }
}

// MARK: - Sample data

/// Fixed stand-ins for two connected services, deliberately near the worst case
/// the layout has to survive: an email address, a plan pill, six usage windows
/// and a headline metric past the warning threshold. The user's own accounts
/// would make a prettier preview and a less informative one.
///
/// That last figure does double duty and is why it is not tuned down. Past the
/// warning threshold at every preset, it is the only reading that shows the
/// square-capped fill, the heavier figure and the spine — and the second service,
/// mid-window, is what makes those legible as a state rather than as decoration.
/// A preview of a panel where nothing is happening previews nothing.
///
/// Internal for the same reason `SampleRow` is: the row cannot be measured
/// against a real one without the metrics it is drawn from.
struct SampleService {
    let serviceID: String
    let displayName: String
    let accent: Color
    let account: String
    let plan: String
    let primary: UsageMetric
    let secondary: [UsageMetric]

    /// Recomputed on each access so the countdowns stay plausible in a window
    /// that has been left open.
    static var claude: SampleService {
        SampleService(
            serviceID: "claude",
            displayName: "Claude",
            accent: Color(red: 0.85, green: 0.45, blue: 0.30),
            account: "you@example.com",
            plan: "Max 20×",
            primary: UsageMetric(
                label: "5-hour messages",
                used: 412,
                limit: 450,
                unit: "messages",
                resetDate: soon(hours: 3, minutes: 12)
            ),
            secondary: [
                UsageMetric(label: "Weekly", used: 3200, limit: 5000, unit: "messages", resetDate: soon(hours: 102)),
                UsageMetric(label: "Weekly Opus", used: 180, limit: 300, unit: "messages", resetDate: soon(hours: 102)),
                UsageMetric(label: "Code 5-hour", used: 44, limit: 60, unit: "prompts", resetDate: soon(hours: 3, minutes: 12)),
                UsageMetric(label: "Code weekly", used: 210, limit: 700, unit: "prompts", resetDate: soon(hours: 102)),
                UsageMetric(label: "Extra credits", used: 6, limit: 40, unit: "credits"),
                UsageMetric(label: "Team pool", used: 1400, limit: 9000, unit: "messages", resetDate: soon(hours: 264))
            ]
        )
    }

    static var chatgpt: SampleService {
        SampleService(
            serviceID: "chatgpt",
            displayName: "ChatGPT",
            accent: Color(red: 0.10, green: 0.55, blue: 0.40),
            account: "Chrome · Profile 1",
            plan: "Plus",
            primary: UsageMetric(
                label: "GPT-5 messages",
                used: 37,
                limit: 80,
                unit: "messages",
                resetDate: soon(hours: 1, minutes: 5)
            ),
            secondary: [
                UsageMetric(label: "Deep research", used: 3, limit: 25, unit: "reports", resetDate: soon(hours: 18)),
                UsageMetric(label: "Sora", used: 12, limit: 50, unit: "videos", resetDate: soon(hours: 18))
            ]
        )
    }

    /// What the menu bar sample is drawn from: one service near its cap, one in
    /// the middle of its window, and one that reports a state rather than a
    /// quota.
    ///
    /// The third is the one worth having. Status-only services carry no urgency,
    /// so `MenuBarStripContent` sorts them below every measured one and the dash
    /// only appears once the strip is set to carry three — which is exactly the
    /// behaviour: a service with no number never displaces one that has a number
    /// worth reading.
    static let stripEntries: [MenuBarEntry] = [
        MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.92),
        MenuBarEntry(serviceID: "cursor", displayName: "Cursor", percent: 0.64),
        MenuBarEntry(serviceID: "chatgpt", displayName: "ChatGPT", percent: nil)
    ]

    /// The levels behind the mark in the panel's own header, which is still a
    /// small multi-bar glyph rather than a strip — a header has room for one
    /// summary shape and the rows underneath carry the readings.
    static let menuBarLevels: [Double] = [0.92, 0.64, 0.46, 0.30, 0.11, 0.03]

    private static func soon(hours: Int, minutes: Int = 0) -> Date {
        Date().addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60))
    }
}
