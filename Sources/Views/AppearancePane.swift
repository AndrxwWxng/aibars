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
/// `UsageBar`, `MetricCaption`, `SecondaryChip`, `RowActions`, `UsageRing` —
/// rather than from copies of them. `ProviderRow` itself needs an
/// `AnyUsageProvider`, which only exists wrapped around a Keychain lookup and a
/// network fetch, but everything below that row takes a plain `UsageMetric`. The
/// copies drifted: they hovered by inserting buttons the panel is forbidden from
/// inserting, and they spaced their captions on numbers the panel had since
/// retuned.
public struct AppearancePane: View {
    @ObservedObject private var appearance: AppearanceSettings

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

            Divider().opacity(Tokens.Fill.divider)
            preview
        }
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
                if appearance.meterStyle == .bar {
                    Toggle("Gradient fill", isOn: $appearance.usesGradientFill)
                }
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
            SectionFooter("Every colour scheme still turns to the warning colour above the warning threshold, and that is also where the menu bar mark picks up its tint. The two thresholds cannot cross.")
        }
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

    private var menuBarSection: some View {
        Section {
            Picker("Style", selection: $appearance.menuBarLabel) {
                ForEach(AppearanceSettings.MenuBarLabelStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            Picker("Number", selection: $appearance.menuBarValue) {
                ForEach(AppearanceSettings.MenuBarValue.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            if appearance.menuBarLabel.showsGlyph {
                CountStepper(
                    title: "Bars in the mark",
                    value: $appearance.menuBarBarCount,
                    range: 1...6
                )
                Picker("Mark colour", selection: $appearance.menuBarColour) {
                    ForEach(AppearanceSettings.MenuBarColour.allCases) { colour in
                        Text(colour.label).tag(colour)
                    }
                }
                TunerRow(
                    title: "Mark size",
                    value: $appearance.menuBarGlyphHeight,
                    range: 10...16,
                    step: 0.5,
                    readout: pointReadout
                )
            }
            LabeledContent("Preview") {
                MenuBarSample(appearance: appearance)
            }
        } header: {
            Text("Menu bar")
        } footer: {
            SectionFooter("Monochrome leaves the mark as a template image, so the menu bar gives it its own light, dark and vibrancy treatment.")
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
        .background(Color(nsColor: .underPageBackgroundColor))
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
/// summary, the sample rows, the menu bar sample and both threshold sliders read
/// it from here — as four copies of `Int((x * 100).rounded())` they were four
/// chances for one of them to start flooring instead. `MetricCaption` and
/// `AppState.headlineSummary` still spell it out themselves and should not.
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
                    .font(.system(size: Tokens.Ramp.caption))
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
                    .font(.system(size: Tokens.Ramp.caption))
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

/// The status item as configured: the mark, then whatever text the style asks
/// for, from the same sample levels the panel preview uses.
private struct MenuBarSample: View {
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        HStack(spacing: Tokens.Space.snug) {
            if appearance.menuBarLabel.showsGlyph {
                UsageMeterGlyph(
                    levels: SampleService.menuBarLevels,
                    // `menuBarTint` is already nil under `.monochrome`; deciding
                    // that again here would be a second copy of the rule to keep
                    // in step with the status item.
                    alertColor: appearance.menuBarTint(for: percent),
                    alertThreshold: appearance.warningThreshold,
                    perBarColour: appearance.coloursEveryMenuBarBar,
                    height: appearance.menuBarGlyphHeight,
                    barCount: appearance.menuBarBarCount
                )
            }
            switch appearance.menuBarLabel {
            case .iconAndPercent, .percentOnly:
                Text(percentLabel(percent))
                    .font(.system(
                        size: Tokens.Ramp.label,
                        weight: Tokens.Ramp.emphasisWeight,
                        design: Tokens.Ramp.figureDesign
                    ))
                    .monospacedDigit()
            case .iconAndName:
                Text(SampleService.claude.displayName)
                    .font(.system(size: Tokens.Ramp.label, weight: Tokens.Ramp.emphasisWeight))
            case .iconOnly:
                EmptyView()
            }
        }
    }

    /// Computed from the sample rather than through `menuBarPercent(in:)`: the
    /// preview has to say something with no AppState around it, and with nothing
    /// connected the real answer is 0% for every setting.
    private var percent: Double {
        let levels = SampleService.menuBarLevels
        switch appearance.menuBarValue {
        case .highest: return levels.max() ?? 0
        case .average: return levels.reduce(0, +) / Double(levels.count)
        }
    }
}

// MARK: - The sample panel

/// The dropdown, at the configured width, with the header and two services.
private struct SamplePanel: View {
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                appearance: appearance,
                levels: SampleService.menuBarLevels,
                topPercent: SampleService.claude.primary.percent,
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

            Divider().opacity(Tokens.Fill.divider)

            VStack(spacing: appearance.metrics.rowGap) {
                SampleRow(appearance: appearance, service: .claude)
                SampleRow(appearance: appearance, service: .chatgpt)
            }
            .padding(.vertical, Tokens.Space.listMargin)
        }
        .frame(width: CGFloat(appearance.panelWidth))
        .background(
            Tokens.surface(Tokens.Radius.panel)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
                .strokeBorder(Tokens.quiet(Tokens.Fill.border))
        )
    }

    /// The figure is read off the sample rather than typed into the sentence, so
    /// the summary cannot end up claiming a percentage no row in the preview shows.
    private var summary: String {
        "Claude is nearly capped — \(percentLabel(SampleService.claude.primary.percent))"
    }
}

/// One row of the sample, drawn from the panel's own parts.
private struct SampleRow: View {
    @ObservedObject var appearance: AppearanceSettings
    let service: SampleService

    @State private var isHovered = false

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }
    private var primary: UsageMetric { service.primary }

    /// The panel's rule for the trailing figure: with `numberOnly` the
    /// percentage *is* the meter, so it outlives the percentage switch —
    /// otherwise a row can be configured down to a name with no usage on it at
    /// all. The panel spells this on `AppearanceSettings` in its own file, where
    /// it is private; `MetricCaption` already follows it for the lines below.
    private var showsNumber: Bool {
        appearance.showsPercentage || appearance.meterStyle == .numberOnly
    }

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
            Tokens.surface(Tokens.Radius.row)
                .fill(Tokens.quiet(Tokens.rowBackground(appearance.rowBackground, isHovered: isHovered)))
                // Held inside the gutter so a hovered card floats rather than
                // touching the panel edge.
                .padding(.horizontal, Tokens.Space.cardInset)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    // MARK: Leading column

    /// False collapses the gap along with the column, as the panel's rows do: an
    /// 11pt indent in front of nothing reads as a broken layout, not a text list.
    private var hasLeading: Bool {
        appearance.logoStyle != .hidden || appearance.meterStyle == .ring
    }

    /// Whether anything is drawn under the title line at all, which decides
    /// whether the leading column has a stack to align to or a single line.
    private var drawsDetail: Bool {
        if appearance.meterStyle == .bar { return true }
        if caption(for: primary, isSecondary: false).hasContent { return true }
        return appearance.secondaryWindows != .hidden && !service.secondary.isEmpty
    }

    /// The panel's own leading-column arithmetic, because the chip ceiling has to
    /// subtract it. Sized off the settings rather than measured, exactly as the
    /// panel does it — the two have to reach the same chip count or the stepper
    /// appears to promise chips the row will never draw.
    private var leadingWidth: CGFloat {
        guard hasLeading else { return 0 }
        let logo = appearance.logoStyle == .hidden ? 0 : CGFloat(appearance.logoSize)
        let ring = appearance.meterStyle == .ring ? metrics.ringDiameter : 0
        let inner = (logo > 0 && ring > 0) ? Tokens.Space.leadingItems : 0
        return logo + ring + inner + Tokens.Space.leadingColumn
    }

    private var textColumnWidth: CGFloat {
        CGFloat(appearance.panelWidth) - 2 * metrics.rowHorizontalPadding - leadingWidth
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
                    UsageRing(
                        percent: primary.percent,
                        diameter: metrics.ringDiameter,
                        thickness: metrics.barHeight,
                        tint: tint(for: primary)
                    )
                }
            }
            .padding(.top, Tokens.Space.hairline)
        }
    }

    // MARK: Title

    private var titleLine: some View {
        HStack(spacing: Tokens.Space.small) {
            Text(service.displayName)
                .font(.system(size: metrics.titleSize, weight: Tokens.Ramp.titleWeight))
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
                    .font(.system(size: metrics.captionSize, weight: Tokens.Ramp.emphasisWeight))
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

            if showsNumber {
                Text(percentLabel(primary.percent))
                    .font(.system(size: metrics.titleSize,
                                  weight: Tokens.Ramp.titleWeight,
                                  design: Tokens.Ramp.figureDesign))
                    .monospacedDigit()
                    .foregroundStyle(tint(for: primary))
                    // Unconstrained, a figure the title line is too narrow for
                    // wraps rather than truncates: "100%" becomes "100" over "%"
                    // and the row grows a line. It never gives width either — a
                    // truncated name is still a name, "10…" is a different
                    // reading of 100%.
                    .lineLimit(1)
                    .layoutPriority(1)
                    .fixedSize()
            }
        }
    }

    // MARK: Body

    /// The panel's `primaryMetric` and `secondaryWindows`, in the same order and
    /// on the same spacing: the bar carries its own caption, and a dial or a bare
    /// number leaves only the context line to draw.
    @ViewBuilder
    private var detail: some View {
        switch appearance.meterStyle {
        case .bar:
            UsageBar(metric: primary, accent: service.accent, appearance: appearance)
        case .ring, .numberOnly:
            if caption(for: primary, isSecondary: false).hasContent {
                caption(for: primary, isSecondary: false)
            }
        }
        secondaryWindows
    }

    /// Chips are a single unwrapped line, so their ceiling is width rather than a
    /// count: 520pt of empty panel takes all six, 300pt behind a 40pt logo at
    /// 130% type takes one. The panel's estimate, literal for literal, or the
    /// preview shows a different number of chips than the panel will.
    private var chipLimit: Int {
        let furniture = Tokens.Control.chipDot + Tokens.Space.snug + 2 * Tokens.Space.small
        let chipWidth = furniture + Tokens.Space.snug + metrics.captionSize * 5
        return max(1, min(appearance.secondaryWindowLimit, Int(textColumnWidth / chipWidth)))
    }

    @ViewBuilder
    private var secondaryWindows: some View {
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
            HStack(spacing: Tokens.Space.snug) {
                ForEach(numbered(chipLimit), id: \.offset) { window in
                    SecondaryChip(
                        metric: window.element,
                        accent: service.accent,
                        appearance: appearance
                    )
                }
            }
        }
    }

    /// Keyed on position rather than on the window's name: a service can report
    /// two windows under one label, and a repeated `ForEach` id draws one of them
    /// and silently drops the rest.
    private func numbered(_ limit: Int) -> [(offset: Int, element: UsageMetric)] {
        Array(service.secondary.prefix(limit).enumerated())
    }

    /// A further window is drawn in whatever the meter style is, the way the
    /// panel draws it: a thinner bar, a smaller dial beside the caption, or the
    /// caption on its own. Bars under a ring setting would be a hybrid row that
    /// exists nowhere in the app.
    @ViewBuilder
    private func secondaryWindow(_ metric: UsageMetric) -> some View {
        switch appearance.meterStyle {
        case .bar:
            UsageBar(metric: metric, isSecondary: true, accent: service.accent, appearance: appearance)
        case .ring:
            // Indented by its own dial, the way the row is indented by the
            // primary one. The caption still ends at the text column's trailing
            // edge, so the percentages stay in one column.
            HStack(spacing: Tokens.Space.small) {
                UsageRing(
                    percent: metric.percent,
                    diameter: metrics.ringDiameter * 0.55,
                    thickness: metrics.secondaryBarHeight,
                    tint: tint(for: metric)
                )
                caption(for: metric, isSecondary: true)
            }
        case .numberOnly:
            caption(for: metric, isSecondary: true)
        }
    }

    /// The panel's caption, which is what puts the countdowns and the
    /// percentages of every line of every row in two columns instead of wherever
    /// the amounts before them happened to stop.
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
/// the layout has to survive: an email address, a plan pill, six usage windows
/// and a headline metric past the warning threshold. The user's own accounts
/// would make a prettier preview and a less informative one.
private struct SampleService {
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

    /// Six levels so the bar-count stepper has something to reveal at every
    /// setting, in the descending order the mark draws them in anyway.
    static let menuBarLevels: [Double] = [0.92, 0.64, 0.46, 0.30, 0.11, 0.03]

    private static func soon(hours: Int, minutes: Int = 0) -> Date {
        Date().addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60))
    }
}
