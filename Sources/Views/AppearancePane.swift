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
/// `MeterSlot`, `UsageFigure`, `UsageRing`, `MetricCaption`,
/// `SecondaryChipRun`, `RowActions` — measured by the panel's own `RowGeometry`,
/// and topped by the status item's own `MenuBarStripView`. Nothing here is a copy
/// of any of them. `ProviderRow` itself needs an `AnyUsageProvider`, which only
/// exists wrapped around a Keychain lookup and a network fetch, but everything
/// below that row takes a plain `UsageMetric`.
///
/// Every copy this file ever held drifted, and each drift is the same bug: they
/// hovered by inserting buttons the panel is forbidden from inserting, they spaced
/// their captions on numbers the panel had since retuned, they worked out a
/// leading column and a figure rail the panel had stopped agreeing with, and they
/// drew a track where the panel draws a track with a line of context under it.
/// The last of those made every preset's preview shorter than the row it
/// previewed. So the rule is not "keep the copies in step" — it is that there are
/// no copies. Two more went this pass: the chip run, which had its own HStack of
/// the panel's chips and therefore its own bargain with the caption beside it, and
/// the sample's brand colours, which were two hand-mixed literals standing in for
/// a banded ink the panel reads from `BrandMark`.
public struct AppearancePane: View {
    @ObservedObject private var appearance: AppearanceSettings

    /// The rule between the form and the preview is a hairline, and a hairline is
    /// the first thing a low-contrast display loses.
    @Environment(\.colorSchemeContrast) private var contrast

    /// A stored dependency rather than an `@EnvironmentObject`, like every other
    /// appearance-driven view here: the pane is built directly by its tests with
    /// its dependencies injected and no environment at all, and a stored
    /// dependency is what makes that possible. It was justified here by a claim
    /// about the settings window — that it hosts this pane "with only `AppState`
    /// in its environment" — which `SettingsWindowController.hostingView`
    /// contradicts: it installs `AppearanceSettings.shared` alongside `state` on
    /// both construction paths, and says so.
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
    /// the app has one rule colour and one accessor for it, and `Divider` carries
    /// its own material and its own weight with it. It was also the one rule here
    /// that did not step up under increased contrast, because a `Divider` held at
    /// half opacity is a second treatment nothing else could agree with.
    ///
    /// A whole point wide, deliberately, where the panel's header rule and the
    /// preview's own `headerRule` below take `Control.hair(scale:)` instead. Those
    /// two are horizontal edges inside a drawing the pane is *showing*, and one
    /// point of grey at 2× is twice the ink AppKit's separator lays down. This one
    /// is the window's structure — the split between the controls the user is
    /// operating and the sample they are watching — at the thickness the system
    /// splits a window at (`NSSplitView.dividerThickness` is 1.0). Sub-pixel
    /// structure would also read as an accident beside the pane's 14pt margins.
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
            Toggle("24-hour sparkline", isOn: $appearance.showsRowSparkline)

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
        var lines = ["The extra windows are where a row's height goes: four of them is four more lines under one service. As chips they ride the row's own line of context instead and cost it no height at all, so a narrow panel or large type fits fewer of them than the limit allows."]
        // Always present, never conditioned on the switch. What it explains is
        // the empty box a user sees the first day, and the moment to explain that
        // is before they turn it on rather than after they have wondered.
        lines.append("The sparkline is the last day of a row's headline window, one point an hour at the highest reading in it, and it reserves its slot on every connected row whether or not there is a day of history behind it yet — a row that grew when its history arrived would resize the panel under the pointer.")
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
    /// The warning threshold is worth spelling out because two of the three
    /// things it moves are not colours: the fill's trailing end squares off and
    /// the figure goes a weight heavier. Someone reading this pane is choosing
    /// where an alarm starts, and an alarm that survives a greyscale screenshot
    /// is a different promise from one that does not.
    ///
    /// The resting band gets a line of its own for the opposite reason: a user
    /// who turns everything on and sees a row with no colour anywhere on it has
    /// to be told that is the point, or it reads as a setting that failed to
    /// apply.
    private var meterFooter: String {
        var lines = ["Every colour scheme still turns to the warning colour above the warning threshold, and that is also where the fill squares off its end and the number goes a weight heavier — so the state survives a greyscale screenshot. The two thresholds cannot cross."]
        if appearance.colorRamp == .usage {
            lines.append("Below the caution threshold nothing on the row is tinted at all: the bar rests grey and the number with it, so colour arriving anywhere in the panel means one service is worth looking at.")
        }
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
                // Whole points, unlike the two panel tuners above it. This one
                // ends up in a bitmap: `MenuBarStripRenderer` rounds the strip's
                // measured *width* up and then hands the height through raw to
                // `NSImage(size:)`, so a 13.5 renders on a half-pixel grid at 1×
                // and the tabular figures in it come back soft. Half a point of a
                // 10–16pt mark is not a distinction anyone can see; a smeared
                // figure in the menu bar is.
                step: 1,
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
            // `Ink.muted`, not `.tertiary`: the third ink is gone from the app,
            // and a caption naming the one thing in this window you are meant to
            // look at should not be the faintest text on screen.
            Text("Preview — hovers like the real panel")
                // `.regular` out loud: two weights and an alert, and a label on a
                // preview is context.
                .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                .foregroundColor(Tokens.Ink.muted)

            // Both axes scroll: the panel can be wider than this column and
            // taller than the strip, and hiding the sample is how you end up
            // tuning a setting whose effect is off-screen. Indicators stay on — a
            // comfortable row with six windows is three times this strip, and
            // with no scroller the rest of it reads as missing rather than below.
            // The viewport, read rather than assumed, for the one thing the
            // scroller will not do on its own: hold the sample at the top.
            //
            // A two-axis `ScrollView` centres content shorter than its clip view,
            // and the sample is shorter than this column at every preset — so it
            // sat some 250pt beneath the caption that names it, in the middle of
            // an empty well, and crept upward as a setting made the panel taller.
            // Filling the viewport with the content leaves the scroller nothing to
            // centre; a sample taller than the column still grows past it and
            // still scrolls.
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    SamplePanel(appearance: appearance)
                        // The pane inset is on the column, not in here, so one
                        // number places the caption and the sample.
                        .frame(minWidth: Self.sampleViewportWidth, alignment: .leading)
                        .padding(.bottom, Tokens.Space.large)
                        .frame(minHeight: viewport.size.height, alignment: .top)
                }
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
                    //
                    // `.regular` out loud rather than inherited: the app has two
                    // weights and an alert, and a readout beside a slider is
                    // context — the same weight the label on its left is set in.
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular, design: Tokens.Ramp.figureDesign))
                    .monospacedDigit()
                    // `.foregroundColor` on a `Text`, which is the app's floor:
                    // `Text.foregroundStyle` is macOS 14.
                    .foregroundColor(Tokens.Ink.muted)
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
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular, design: Tokens.Ramp.figureDesign))
                    .monospacedDigit()
                    .foregroundColor(Tokens.Ink.muted)
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
/// which matters more now that the low stop is a grey rather than a colour:
/// grey → amber → red separates on lightness as well as on the blue–yellow axis,
/// so it survives deuteranomaly, protanopia and a greyscale screenshot alike —
/// and a resting bar with no hue on it is what leaves colour free to mean "this
/// one is worth looking at".
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

    /// What one device pixel is worth here, for the one rule the panel draws.
    @Environment(\.displayScale) private var scale

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
                summary: summary,
                // The panel hands its header shorter ways of saying the same
                // thing, longest first, and draws the longest one that fits — so
                // a 300pt panel says "Claude 92%" rather than cutting a sentence
                // in half. A preview handed one line would be the one place in
                // the app where the summary still shows an ellipsis.
                alternates: [shortSummary]
            ) {
                // Images, not buttons: these four controls can never be
                // configured away, so the preview shows them without offering to
                // run them. All four, and on the button's own footprint — the
                // cluster is what everything else on the header line is placed
                // against, and a preview one glyph short of the panel puts the
                // wordmark and the summary beside it in the wrong place.
                ForEach(["arrow.clockwise", "chart.xyaxis.line", "gearshape", "power"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        // `titleWeight`, like every glyph in the app: an icon is
                        // an answer rather than context, and the token that used
                        // to be asked for here promised a step up and resolved to
                        // this same weight.
                        .font(.system(size: Tokens.Control.iconGlyph, weight: Tokens.Ramp.titleWeight))
                        .foregroundColor(Tokens.Ink.muted)
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
    /// square-capped fill — and a coloured edge across the chrome names no
    /// service, so there is nothing to act on. It also put hue on the one
    /// element that stays on screen while the list is scrolled, so it shouted for
    /// as long as the panel was left open.
    ///
    /// One device pixel tall, not one point: `Control.hairline` is the system's
    /// separator *thickness*, and drawn literally on a 2× display it lays down
    /// twice the ink AppKit's own separator does and reads as a soft grey band
    /// rather than as an edge. The panel's rule takes the same treatment, and the
    /// preview has to draw the rule the panel draws.
    ///
    /// Through `Control.hair(scale:)` rather than `hairline / max(scale, 1)`,
    /// which is what stood here: the same arithmetic including the guard against
    /// a reported scale of 0, so nothing moves at any real scale. It was the
    /// third spelling of one device pixel in the app, and the reason the preview
    /// and the panel could have stopped agreeing is that they were two spellings
    /// rather than two calls.
    private var headerRule: some View {
        Rectangle()
            .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
            .frame(height: Tokens.Control.hair(scale: scale))
    }

    /// The figure is read off the sample rather than typed into the sentence, so
    /// the summary cannot end up claiming a percentage no row in the preview shows.
    private var summary: String {
        "Claude is nearly capped — \(percentLabel(SampleService.claude.primary.percent))"
    }

    /// The same fact in fifteen characters or fewer, in the panel's own short
    /// form: the busiest service and its figure, with no clause on it.
    ///
    /// No freshness clause in front of either line, which is where this and the
    /// panel's ladder differ on purpose — the preview has fetched nothing, and
    /// "updated just now" under a settings window that has been open an hour is
    /// the one sentence a sample must not say.
    private var shortSummary: String {
        "\(SampleService.claude.displayName) \(percentLabel(SampleService.claude.primary.percent))"
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

    @State private var isHovered = false

    init(appearance: AppearanceSettings, service: SampleService) {
        self._appearance = ObservedObject(wrappedValue: appearance)
        self.service = service
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
            rowActions: appearance.rowActions,
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
    ///
    /// `.window` off the same settings-only predicate the panel's row uses, and
    /// not off "does this caption happen to have anything in it". The sample is
    /// always reporting, so the two agreed for the sample — but the panel's row
    /// reserves the line in states the sample cannot be in, and a preview that
    /// answers a question a different way than the thing it previews is a preview
    /// that will eventually answer it differently.
    ///
    /// `.sparkline` off the setting alone, exactly as the panel's row takes it.
    /// The sample always has a trace to draw — `RowSparkline.sample` is a fixed
    /// series — where a real row may have nothing yet, and that difference must
    /// not reach the measurement: both reserve the slot from the switch, so the
    /// preview is the height of the row it previews on a machine with no history
    /// at all.
    private var lines: RowGeometry.Lines {
        var drawn: RowGeometry.Lines = [.meter]
        if reservesWindowLine { drawn.insert(.window) }
        if appearance.showsRowSparkline { drawn.insert(.sparkline) }
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
        // Top alignment lines a tall logo up with the name; a row with nothing
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
                // The panel's own hover, transition included: short enough to read
                // as the card lighting up rather than as a fade. The preview said
                // "hovers like the real panel" while lighting instantly, which is
                // the one difference a user can see in this window.
                .animation(.easeOut(duration: 0.12), value: isHovered)
                // Held inside the gutter so a hovered card floats rather than
                // touching the panel edge.
                .padding(.horizontal, Tokens.Space.cardInset)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    // MARK: Leading column

    /// False collapses the gap along with the column, as the panel's rows do: a
    /// 10pt indent in front of nothing reads as a broken layout, not a text list.
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
        // A trace is a block under the title, so a row that draws one is top
        // aligned however empty the rest of its text column is — the panel's own
        // first question, asked here in the same place and the same order.
        if appearance.showsRowSparkline { return true }
        // Every style but the ring draws its meter in the text column, and that
        // slot is occupied on every row.
        guard appearance.meterStyle == .ring else { return true }
        // Under the ring the window line is all the text column has, and whether
        // there is one is `reservesWindowLine` — the same question `lines` above
        // asks, so the alignment and the reserved height cannot answer it
        // differently.
        if reservesWindowLine { return true }
        return appearance.secondaryWindows == .expanded && !service.secondary.isEmpty
    }

    /// The mark, and the dial when the meter is one.
    ///
    /// No nudge onto the title's band any more, here or in the panel: the mark
    /// box and the title box are both 18pt at the defaults, so the two already
    /// sit on one band and the 1pt drop was a lie written in two files —
    /// `RowGeometry` reserved it as well, which made every row a point taller
    /// than the row it drew.
    @ViewBuilder
    private var leading: some View {
        if hasLeading {
            HStack(spacing: Tokens.Space.leadingItems) {
                if appearance.logoStyle != .hidden {
                    ProviderLogo(
                        providerID: service.serviceID,
                        fallbackName: service.displayName,
                        size: appearance.logoSize,
                        showsTile: appearance.logoStyle == .tile,
                        // The sample is always connected and always answering, so
                        // this is the one call site in the app that can state
                        // `true` as a fact rather than read it off a provider.
                        // Through the resolver and not `BrandMark.liveInk`, so
                        // flipping either the brand-colour switch or the colour
                        // ramp previews here exactly as the panel will draw it —
                        // a preview that answered the ink question its own way is
                        // how the two came to disagree in the first place.
                        ink: appearance.markInk(for: service.serviceID, isLive: true)
                    )
                }
                if appearance.meterStyle == .ring {
                    // The panel's own dial rather than a circle drawn here: it
                    // keeps a hole at any thickness and insets its own arc, so a
                    // 12pt meter on a compact 15pt ring stays a ring instead of
                    // a disc overhanging the logo and the text beside it.
                    //
                    // A track and an arc, and nothing else. The pace riser and
                    // the cut through the fill are gone from the bar and from the
                    // dial together — pace is a sentence the row says under
                    // Alerts, not a second instrument drawn inside the first.
                    UsageRing(
                        percent: primary.percent,
                        diameter: metrics.ringDiameter,
                        thickness: metrics.barHeight,
                        tint: tint(for: primary),
                        isNearCap: ProviderRow.isNearCap(
                            percent: primary.percent,
                            warning: appearance.warningThreshold
                        )
                    )
                }
            }
        }
    }

    // MARK: Title

    private var titleLine: some View {
        // `.firstTextBaseline`, which is the panel's own alignment for this line
        // and was `.center` here. The name is SF Pro and the figure SF Mono, and
        // centring puts their cap heights on two baselines a point apart — and,
        // worse for a preview, it makes the buttons' baseline guide a no-op, so
        // the sample resolved its title line a point shorter than the row it is
        // supposed to be showing.
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.small) {
            // The row's subject, and the one thing on the line that is a word
            // rather than a reading. The name and the figure are set at one size
            // and one weight now: the hierarchy between them is the face and the
            // ink, not a point of size and half a weight, and a panel of nine
            // names set heavier than everything under them is the panel shouting.
            Text(service.displayName)
                .font(.system(size: metrics.titleSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.body)
                .lineLimit(1)
                // The name takes its width before the run that says which
                // account, which is the panel's own rule for a 300pt row.
                .layoutPriority(1)

            identityRun

            // `Space.medium`, which is the panel's own minimum between the name
            // and the buttons. It was `snug` here, and a preview that lets its
            // name run four points further than the row does is describing a
            // panel that truncates somewhere else.
            Spacer(minLength: Tokens.Space.medium)

            // The panel's own buttons, which reserve their space and change only
            // opacity. Inserting them on hover — what this row used to do — moved
            // the percentage beside them and the row's whole height every time the
            // pointer crossed it, in a preview whose job is to hold still while
            // you adjust the thing next to it.
            //
            // On the panel's own baseline guide: a button block SwiftUI can find
            // no baseline in is aligned by its bottom edge, and the panel drops
            // its centre onto the reading band instead. Without the guide the
            // sample line resolved a point short of the row's.
            RowActions(
                visibility: appearance.rowActions,
                isHovered: isHovered,
                hasDashboard: true,
                refreshHelp: "Refresh \(service.displayName)"
            )
            .alignmentGuide(.firstTextBaseline) {
                ProviderRow.controlBaseline($0, titleSize: metrics.titleSize)
            }

            trailingValue
        }
    }

    /// Which account, and what plan it is on: one muted run rather than a label
    /// and a filled pill.
    ///
    /// The pill is deleted from the panel and from here together. It had
    /// `lineLimit(1)` and no floor while the name took the width first, so at
    /// 300pt and 130% type it squeezed to nothing and still drew its fill — a
    /// bare grey blob after a truncated name — and the account label beside it,
    /// which is the part that says *which* Claude this row is, was given zero
    /// width and vanished. Both parts are text now, joined by the panel's own
    /// middle dot, and the run gives ground as a whole.
    private var identityParts: [String] {
        var parts: [String] = []
        if appearance.showsAccountLabels { parts.append(service.account) }
        if appearance.showsPlanNames { parts.append(service.plan) }
        return parts
    }

    /// The run, and what it gives up first.
    ///
    /// `ViewThatFits` drops it whole rather than truncating it away: the account
    /// and the plan, then the account alone, then nothing at all. A very long
    /// service name therefore takes the line and this run leaves it, which is
    /// the panel's own order — the name is what the row cannot be read without.
    @ViewBuilder
    private var identityRun: some View {
        let parts = identityParts
        if !parts.isEmpty {
            ViewThatFits(in: .horizontal) {
                // The separator is the panel's own, and it is spelled here rather
                // than composed from two `Text`s so the whole run gives way as one.
                identityText(parts.joined(separator: " · "))
                // The plan is the half that goes: "Max 20×" is the same word on
                // every row of one service, and the address is not.
                if parts.count > 1, let first = parts.first {
                    identityText(first)
                }
                // The candidate `ViewThatFits` can always fall back on, which has
                // to be something that fits any width: the run drops out whole and
                // the name keeps the line.
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    /// Caption type, which is `detailSize` — the 10pt step is the pace sentence's
    /// alone, and a second caption size on the row is a rank the panel does not
    /// have. `.regular` out loud, because this is context beside a name set in
    /// `titleWeight` and a caption that inherits a weight is a weight nobody chose.
    ///
    /// Middle truncation: the tail of an address is the part that tells two
    /// accounts of one service apart, and its head is the part that tells the
    /// person apart. No `layoutPriority` at all — at −1 it was sized after the
    /// spacer beside it and given nothing.
    private func identityText(_ run: String) -> some View {
        Text(run)
            .font(.system(size: metrics.detailSize, weight: .regular))
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// The figure rail, held whether or not there is a figure in it.
    ///
    /// The panel's own `UsageFigure` rather than a pair of `Text`s written here:
    /// the digits, the unit beside them and the shared baseline are the panel's
    /// treatment, and a second copy of it in the one view whose job is to show
    /// what the panel looks like is a copy that will drift. The unit is set at the
    /// digits' own size now — the raised tick was fussy at 13pt and read as an
    /// accident rather than as typography.
    ///
    /// Two channels of the near-cap contract meet on this line. The weight comes
    /// from `ProviderRow.figureWeight`, which is the panel's own pure function of
    /// the reading and the threshold, so the preview cannot step at a different
    /// point from the row. The colour comes from `figureTint`, which holds the
    /// digits neutral below the caution threshold under the usage ramp — a panel
    /// of nine coloured numbers has spent its whole colour budget on the least
    /// informative state it has, and this is how colour arriving on a number
    /// becomes the news. The unit is neutral in every band, because it annotates
    /// the number rather than being part of the reading.
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

    /// The meter block, the trace, and whatever the further windows are set to,
    /// in the same order and on the same spacing as the panel's row.
    @ViewBuilder
    private var detail: some View {
        meterBlock
        sparkline
        secondaryWindows
    }

    /// The sample's own last day, in the same slot the panel's row puts it in.
    ///
    /// `RowSparkline.sample` and not the real store, and that is the point of a
    /// preview: its job is to show what the setting does, and a preview that drew
    /// a blank box on a machine with no history yet would be indistinguishable
    /// from the setting being broken. The fixed series carries a gap and a reset
    /// because those are the two cases the drawing exists to handle, and this pane
    /// is where a user finds out that it does.
    ///
    /// Reserved off the same switch the panel's row reads and drawn in the same
    /// position in the same stack, because a preview that omitted it would be
    /// exactly the divergence this whole row was rebuilt to make impossible.
    @ViewBuilder
    private var sparkline: some View {
        if appearance.showsRowSparkline {
            RowSparkline(peaks: RowSparkline.sample, height: metrics.sparklineHeight)
        }
    }

    /// The headline window: its slot, and the line of context under it, at half
    /// the pitch that separates one window from the next.
    ///
    /// The two are stacked here rather than taken whole from `UsageBar`, and the
    /// reason is the chips. A caption line that can carry the further windows on
    /// its trailing half is a line with two occupants, and a view that draws a
    /// track over a caption has nowhere to put the second one. Both halves are
    /// still the panel's own — `MeterSlot` and `MetricCaption` — and `captionGap`
    /// is the same token `RowGeometry` measures the joint at, which is what keeps
    /// this row the height of the row it previews.
    ///
    /// The quotaless branch the panel keeps has nothing to draw here — the
    /// sample's headline window carries a real quota — and the pace line the panel
    /// puts between this and the further windows is deliberately absent: it draws
    /// only when the samples support a claim, and the preview has no samples.
    private var meterBlock: some View {
        VStack(alignment: .leading, spacing: metrics.captionGap) {
            // Under the ring the dial in the leading column is the meter, so the
            // text column holds only the line of context. Under the bar and the
            // bare number the slot stands either way — it is the same height in
            // both, which is what the row is squared against — and it has exactly
            // two drawings now: a track with its fill, or nothing. The hairline
            // that used to stand in for a meter is gone from the panel and from
            // here: a full-width rule under every title, with nothing beneath it,
            // reads as a table rule rather than as "no quota".
            if appearance.meterStyle != .ring {
                MeterSlot(
                    metric: primary,
                    accent: service.accent,
                    appearance: appearance
                )
            }
            captionLine
        }
    }

    /// The line under the meter.
    ///
    /// One view and not two beside each other, because that is what the panel
    /// draws: `ProviderRow` hands the chips *into* the caption, and
    /// `MetricCaption` puts them at the trailing edge of its own line. Building
    /// them as siblings here was the last measurable difference between the
    /// preview and the panel, and it was a large one — handed no chips,
    /// `MetricCaption.trailing` falls through to its empty-rail branch and
    /// reserves `secondaryRail` at the trailing edge, so the sample spent
    /// `sentence + 8 + rail + 8 + chips` on a line the panel spends
    /// `sentence + 8 + chips` on. At the shipped cozy metrics that is 37pt of
    /// caption the preview did not have and the panel did, which is a preview
    /// truncating a sentence the row would have drawn whole.
    ///
    /// Held open when the settings reserve the line and there is nothing to put
    /// on it, exactly as `UsageBar` holds it open in the panel — the preview has
    /// to be the height of the row it previews in that state too.
    @ViewBuilder
    private var captionLine: some View {
        // The same two nested questions in the same order as `UsageBar`: the
        // settings decide whether there is a line, the content decides what goes
        // on it. Equivalent to one `if` for a sample that always reports and
        // never has a bill — and written as two anyway, because a preview that
        // reaches the panel's answer by a different route is a preview that will
        // eventually reach a different answer.
        if reservesWindowLine {
            if primaryCaption.hasContent {
                primaryCaption
            } else {
                ReservedTextLine(size: metrics.detailSize)
            }
        }
    }

    /// The line under the headline meter, chips and all, asked for twice — once
    /// to draw and once to decide whether the row has a second line at all — so
    /// it is built in one place. Assembled exactly as `ProviderRow.primaryCaption`
    /// assembles it, `drawsChips` gate included, so the chips are chosen where
    /// the style is read and cannot be drawn twice under `.expanded`.
    ///
    /// Internal rather than private so `AppearancePaneTests` can ask it whether
    /// the chips are inside. That the run sat *beside* the caption instead cost
    /// the preview 37pt of sentence and not one point of height, so no
    /// measurement of the rendered row could see it and none did, through two
    /// releases of a test file whose whole subject is this row agreeing with that
    /// one.
    var primaryCaption: MetricCaption {
        let split = chipSplit(service.secondary.count)
        return MetricCaption(
            metric: primary,
            isSecondary: false,
            accent: service.accent,
            appearance: appearance,
            chips: drawsChips ? Array(service.secondary.prefix(split.shown)) : [],
            overflow: drawsChips ? split.hidden : 0
        )
    }

    /// The panel's own predicate, minus the row-level override the sample has no
    /// way to be given. It decides the same three things here it decides there:
    /// whether the row reserves a window line, whether it holds that line open
    /// with nothing on it, and — through `lines` — how tall the sample measures.
    private var reservesWindowLine: Bool {
        appearance.showsAmounts
            || appearance.showsCountdowns
            || appearance.secondaryWindows == .chips
    }

    private var drawsChips: Bool {
        appearance.secondaryWindows == .chips && !service.secondary.isEmpty
    }

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
                // `detailSize`, which is the size the chips are set in — the same
                // argument the panel passes. The sample has no spend to lead its
                // caption, and neither does the service it stands for.
                chipSize: metrics.detailSize,
                carriesSpend: false
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

    /// The further windows, when they are set to a line each. The chips are not
    /// here — they ride the caption line above, which is the whole of what makes
    /// them free.
    @ViewBuilder
    private var secondaryWindows: some View {
        if !service.secondary.isEmpty, appearance.secondaryWindows == .expanded {
            // On the enclosing VStack's own spacing with nothing added on top,
            // as in the panel: the pitch from the meter block to the first
            // secondary line is then the pitch between two of them, so the third
            // window of one service sits on the same line as the third of the
            // next.
            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                ForEach(numbered(appearance.secondaryWindowLimit), id: \.offset) { window in
                    secondaryWindow(window.element)
                }
            }
        }
    }

    /// One further window: its name, and its reading in the trailing rail.
    ///
    /// A line rather than a second full-width meter, which is where most of the
    /// row's height used to go — nine bars down a panel is nine readings of the
    /// same rank, and the headline window is not one of nine. Every window the
    /// sample carries has a ceiling, so the valueless branch the panel keeps for a
    /// metric with no limit has nothing to draw here.
    private func secondaryWindow(_ metric: UsageMetric) -> some View {
        caption(for: metric, isSecondary: true)
    }

    // The chip run was assembled here, beside the caption rather than inside it,
    // and that is the copy this pass deleted. `MetricCaption` has carried the
    // chips since the panel started folding them onto its caption line; building
    // a second `SecondaryChipRun` here meant the sample bargained for width with
    // its caption on different terms than the panel does — and, because a caption
    // handed no chips reserves an empty figure rail instead, on 37pt less of it.
    // `primaryCaption` above now builds the line the way `ProviderRow` builds it,
    // which is the only arrangement in which "the preview is the panel" is a fact
    // about the code.

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
}

// MARK: - Sample data

/// Fixed stand-ins for two connected services, deliberately near the worst case
/// the layout has to survive: an email address, a plan name, six usage windows
/// and a headline metric past the warning threshold. The user's own accounts
/// would make a prettier preview and a less informative one.
///
/// That last figure does double duty and is why it is not tuned down. It sits in
/// the caution band at the shipped thresholds — above 80%, under 95% — which puts
/// it a short drag of the warning slider away from the square-capped fill and the
/// heavier figure, so the two channels that carry near-cap can be seen arriving
/// rather than described in a footer. (It used to be *past* the shipped warning
/// threshold, and the comment here went on saying so after the default moved.)
/// The second service, mid-window, is what makes the first legible as a state
/// rather than as decoration: it is the one coloured thing in the sample, which is
/// the panel's own rule shown rather than described — a preview where every row is
/// tinted teaches that colour means nothing.
///
/// Internal for the same reason `SampleRow` is: the row cannot be measured
/// against a real one without the metrics it is drawn from.
struct SampleService {
    let serviceID: String
    let displayName: String
    /// What `ColorRamp.provider` paints this service's meter and figure with,
    /// which is the panel's own banded brand ink and never a literal.
    ///
    /// It used to be a hand-mixed orange and a hand-mixed green written here —
    /// two saturated colours belonging to no system, in the one window whose job
    /// is to show what the panel looks like, and neither of them the colour the
    /// panel would have drawn. `BrandMark.brandInk` is the banded pair the row
    /// itself reads, so the provider ramp previews as the provider ramp; a
    /// service with no mark falls back to the system accent, exactly as the row
    /// does.
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
            accent: brandInk("claude"),
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
            accent: brandInk("chatgpt"),
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

    /// The banded brand ink for a service, or the system accent for a service
    /// with no mark — the same fallback `AnyUsageProvider.accentColor` takes, so
    /// the sample cannot be tinted by something the panel would not use.
    private static func brandInk(_ providerID: String) -> Color {
        BrandMark.mark(for: providerID)?.brandInk ?? .accentColor
    }
}
