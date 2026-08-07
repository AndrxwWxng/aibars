import SwiftUI

/// The Appearance pane of Settings: presets first, then one section per part of
/// the app they change, over a sample panel that redraws as the controls move.
///
/// The sample is pinned below the form rather than sitting in it. Every setting
/// here is judged by looking at something, and a preview that scrolls off the
/// top the moment you reach the meter section is a preview you have to remember
/// instead of read.
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
            .frame(minWidth: 300)

            Divider().opacity(0.5)
            preview
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(AppearanceSettings.Preset.allCases) { preset in
                    PresetChip(
                        title: preset.label,
                        isSelected: appearance.matchingPreset == preset,
                        help: preset.summary
                    ) {
                        appearance.apply(preset)
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Presets")
        } footer: {
            // The summary is long enough to be a paragraph, so it goes where the
            // pane already puts prose rather than inside a 104pt chip.
            Text(appearance.matchingPreset?.summary
                 ?? "Custom. Picking a preset replaces everything below except your accent colour and manual order.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                readout: percentReadout
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
            Text("Density moves padding, spacing, type and the size of the dials together. Text size scales the type on top of it, so tight rows with large type is a combination you can have. Bar thickness is its own setting, under the usage meter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                LabeledContent("Windows per service") {
                    Stepper(value: $appearance.secondaryWindowLimit, in: 1...6) {
                        Text("\(appearance.secondaryWindowLimit)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("What each row shows")
        } footer: {
            Text(rowContentFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    HStack(spacing: 8) {
                        ColorPicker("", selection: appearance.accentColorBinding, supportsOpacity: false)
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
                readout: percentReadout
            )
            TunerRow(
                title: "Warning above",
                value: $appearance.warningThreshold,
                range: warningRange,
                step: 0.01,
                readout: percentReadout
            )
            RampStrip(appearance: appearance, providerAccent: SampleService.claude.accent)
        } header: {
            Text("Usage meter")
        } footer: {
            Text("Every colour scheme still turns to the warning colour above the warning threshold, and that is also where the menu bar mark picks up its tint. The two thresholds cannot cross.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The two thresholds are held five points apart by the settings themselves,
    /// so the sliders are given the same coupled bounds. With a fixed 30–85 track
    /// and the warning threshold down at 50%, everything above 45% is track the
    /// thumb springs back out of the moment it is dragged there.
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
            Text(listFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                LabeledContent("Bars in the mark") {
                    Stepper(value: $appearance.menuBarBarCount, in: 1...6) {
                        Text("\(appearance.menuBarBarCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
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
            Text("Monochrome leaves the mark as a template image, so the menu bar gives it its own light, dark and vibrancy treatment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to defaults") { appearance.resetToDefaults() }
        } footer: {
            Text("Returns every option here to how the app shipped, and clears your accent colour and manual order along with them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The live sample

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview — hovers like the real panel")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)

            // Both axes scroll: the panel can be wider than this pane and taller
            // than the strip, and clipping the sample is how you end up tuning a
            // setting whose effect is off-screen. Indicators stay on — a
            // comfortable row with six windows is three times this strip, and
            // with no scroller the rest of it reads as missing rather than below.
            ScrollView([.horizontal, .vertical]) {
                SamplePanel(appearance: appearance)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .padding(.top, 14)
        // A column, so a comfortable row with six windows is visible whole
        // rather than cropped to a strip.
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func percentReadout(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func pointReadout(_ value: Double) -> String {
        value == value.rounded()
            ? "\(Int(value)) pt"
            : String(format: "%.1f pt", value)
    }
}

// MARK: - Controls

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
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 168)
                Text(readout(value))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}

/// One preset, styled like the settings sidebar rows so the selected one reads
/// as a state rather than a button that was pressed a while ago.
private struct PresetChip: View {
    let title: String
    let isSelected: Bool
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return Color.primary.opacity(isHovered ? 0.10 : 0.06)
    }
}

/// The colour ramp end to end, with the bands where the thresholds currently
/// put them. Two sliders describe the ramp; this is the ramp.
private struct RampStrip: View {
    @ObservedObject var appearance: AppearanceSettings
    let providerAccent: Color

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                band(from: 0, to: appearance.cautionThreshold, width: geo.size.width)
                band(from: appearance.cautionThreshold, to: appearance.warningThreshold, width: geo.size.width)
                band(from: appearance.warningThreshold, to: 1, width: geo.size.width)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule(style: .continuous))
        .padding(.vertical, 3)
    }

    /// Each band is drawn in the colour the ramp gives its own midpoint, so a
    /// scheme that collapses two bands into one colour shows two bands of one
    /// colour rather than a lie.
    private func band(from: Double, to: Double, width: CGFloat) -> some View {
        Rectangle()
            .fill(appearance.tint(for: (from + to) / 2, providerAccent: providerAccent))
            .frame(width: max(0, width * (to - from)))
    }
}

/// The status item as configured: the mark, then whatever text the style asks
/// for, from the same sample levels the panel preview uses.
private struct MenuBarSample: View {
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        HStack(spacing: 5) {
            if appearance.menuBarLabel.showsGlyph {
                UsageMeterGlyph(
                    levels: SampleService.menuBarLevels,
                    // `menuBarTint` is already nil under `.monochrome`; deciding
                    // that again here would be a second copy of the rule to keep
                    // in step with the status item.
                    alertColor: appearance.menuBarTint(for: percent),
                    alertThreshold: appearance.warningThreshold,
                    perBarColour: appearance.menuBarColour == .perBar,
                    height: appearance.menuBarGlyphHeight,
                    barCount: appearance.menuBarBarCount
                )
            }
            switch appearance.menuBarLabel {
            case .iconAndPercent, .percentOnly:
                Text("\(Int((percent * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .iconAndName:
                Text(SampleService.claude.displayName)
                    .font(.system(size: 11, weight: .medium))
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
///
/// Deliberately not a `ProviderRow`: that view takes an `AnyUsageProvider`,
/// which only exists wrapped around a live provider — a Keychain lookup, a
/// network fetch and a real enabled flag in UserDefaults, for the sake of a
/// picture. This draws the same anatomy from the same `Metrics`, so the two
/// move together when the metrics do.
private struct SamplePanel: View {
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            VStack(spacing: appearance.metrics.rowGap) {
                SampleRow(appearance: appearance, service: .claude)
                SampleRow(appearance: appearance, service: .chatgpt)
            }
            .padding(.vertical, 6)
        }
        .frame(width: appearance.panelWidth)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            UsageMeterGlyph(
                levels: SampleService.menuBarLevels,
                alertColor: appearance.menuBarTint(for: SampleService.claude.primary.percent),
                alertThreshold: appearance.warningThreshold,
                height: 16
            )
            .padding(.leading, 2)

            // Sized off the metrics like the panel's own header, so the strip
            // shows the header growing with the text scale instead of holding
            // still while every row under it moves.
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Usage")
                    .font(.system(size: appearance.metrics.titleSize, weight: .semibold))
                if appearance.showsHeaderSummary {
                    Text("Claude is nearly capped — 92%")
                        .font(.system(size: appearance.metrics.captionSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            // Images, not buttons: the refresh, settings and quit controls are
            // the only way out of the app and can never be configured away, so
            // the preview shows them without offering to run them.
            ForEach(["arrow.clockwise", "gearshape", "power"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }
}

private struct SampleRow: View {
    @ObservedObject var appearance: AppearanceSettings
    let service: SampleService

    @State private var isHovered = false

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }
    private var primary: UsageMetric { service.primary }

    /// The panel's two gaps, named because the chip ceiling has to subtract them
    /// to know what width the text column was left with.
    private static let textGap: CGFloat = 11
    private static let leadingSpacing: CGFloat = 7

    var body: some View {
        // Top alignment lines a 40pt logo up with the name; a row with nothing
        // under its title is one line of type, which top alignment would leave
        // hanging from the ceiling of that logo.
        HStack(alignment: drawsDetail ? .top : .center, spacing: hasLeading ? Self.textGap : 0) {
            leading
            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                titleLine
                detail
            }
        }
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .padding(.vertical, metrics.rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(backgroundOpacity))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var backgroundOpacity: Double {
        switch appearance.rowBackground {
        case .plain:  return 0
        case .hover:  return isHovered ? 0.06 : 0
        case .always: return isHovered ? 0.09 : 0.05
        }
    }

    private var showsActions: Bool {
        switch appearance.rowActions {
        case .always:  return true
        case .onHover: return isHovered
        case .never:   return false
        }
    }

    /// With `numberOnly` the percentage *is* the meter, so it outlives the
    /// percentage toggle — the rule the panel's rows follow, and without it this
    /// row can be configured down to a name with no usage on it at all.
    private var showsNumber: Bool {
        appearance.showsPercentage || appearance.meterStyle == .numberOnly
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
        if detailText(for: primary) != nil { return true }
        return appearance.secondaryWindows != .hidden && !windows.isEmpty
    }

    /// What is left of the panel once the logo-and-dial column has taken its
    /// share — the only width budget a row gets to reason about.
    private var textColumnWidth: CGFloat {
        guard hasLeading else {
            return CGFloat(appearance.panelWidth) - 2 * metrics.rowHorizontalPadding
        }
        let logo = appearance.logoStyle == .hidden ? 0 : CGFloat(appearance.logoSize)
        let ring = appearance.meterStyle == .ring ? metrics.ringDiameter : 0
        let inner: CGFloat = (logo > 0 && ring > 0) ? Self.leadingSpacing : 0
        return CGFloat(appearance.panelWidth)
            - 2 * metrics.rowHorizontalPadding
            - (logo + ring + inner + Self.textGap)
    }

    @ViewBuilder
    private var leading: some View {
        if hasLeading {
            HStack(spacing: Self.leadingSpacing) {
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
            .padding(.top, 1)
        }
    }

    // MARK: Title

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(service.displayName)
                .font(.system(size: metrics.titleSize, weight: .semibold))
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
                    .font(.system(size: metrics.captionSize, weight: .medium))
                    // A pill that wraps to a second line stops being a pill.
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if showsActions {
                HoverIconButton(systemName: "arrow.clockwise", help: "Refresh \(service.displayName)") {}
                    .frame(width: 20, height: 18)
                HoverIconButton(systemName: "arrow.up.right", help: "Open usage page") {}
                    .frame(width: 20, height: 18)
            }

            if showsNumber {
                Text("\(Int((primary.percent * 100).rounded()))%")
                    .font(.system(size: metrics.titleSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint(for: primary))
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var detail: some View {
        if appearance.meterStyle == .bar {
            bar(for: primary, height: metrics.barHeight)
        }
        if let line = detailText(for: primary) {
            Text(line)
                .font(.system(size: metrics.detailSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        secondaryWindows
    }

    private var windows: [UsageMetric] {
        Array(service.secondary.prefix(appearance.secondaryWindowLimit))
    }

    /// Chips are a single unwrapped line, so their ceiling is width rather than
    /// a count: 520pt of empty panel takes all six, 300pt behind a 40pt logo at
    /// 130% type takes one. Measured the way the panel measures it, or the
    /// stepper appears to promise chips the row will never draw.
    private var chipWindows: [UsageMetric] {
        // A dot, the capsule's padding, and about nine characters of "7d 12/100".
        let chipWidth = 26 + metrics.captionSize * 5
        return Array(windows.prefix(max(1, Int(textColumnWidth / chipWidth))))
    }

    @ViewBuilder
    private var secondaryWindows: some View {
        switch appearance.secondaryWindows {
        case .hidden:
            EmptyView()
        case .expanded:
            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                ForEach(windows, id: \.label) { metric in
                    secondaryWindow(metric)
                }
            }
            .padding(.top, 3)
        case .chips:
            HStack(spacing: 5) {
                ForEach(chipWindows, id: \.label) { metric in
                    chip(for: metric)
                }
            }
            .padding(.top, 1)
        }
    }

    /// A further window is drawn in whatever the meter style is, the way the
    /// panel draws it: a thinner bar, a smaller dial beside the caption, or the
    /// caption on its own. Bars under a ring setting would be a hybrid row that
    /// exists nowhere in the app.
    @ViewBuilder
    private func secondaryWindow(_ metric: UsageMetric) -> some View {
        switch appearance.meterStyle {
        case .bar:
            VStack(alignment: .leading, spacing: 3) {
                bar(for: metric, height: metrics.secondaryBarHeight)
                secondaryCaption(for: metric)
            }
        case .ring:
            HStack(spacing: 6) {
                UsageRing(
                    percent: metric.percent,
                    diameter: metrics.ringDiameter * 0.55,
                    thickness: metrics.secondaryBarHeight,
                    tint: tint(for: metric)
                )
                secondaryCaption(for: metric)
            }
        case .numberOnly:
            secondaryCaption(for: metric)
        }
    }

    private func secondaryCaption(for metric: UsageMetric) -> some View {
        HStack(spacing: 4) {
            Text(metric.label)
                .font(.system(size: metrics.captionSize, weight: .medium))
                .foregroundStyle(.secondary)
                // The window's name is what tells two meters apart, so it keeps
                // its line and its width before the figures beside it.
                .lineLimit(1)
                .layoutPriority(1)
            if let line = detailText(for: metric) {
                Text(line)
                    .font(.system(size: metrics.captionSize))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    // Wrapping here silently costs a line per window, which is a
                    // strange way for a narrow panel to get taller.
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if showsNumber {
                Text("\(Int((metric.percent * 100).rounded()))%")
                    .font(.system(size: metrics.captionSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint(for: metric))
            }
        }
    }

    private func chip(for metric: UsageMetric) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint(for: metric))
                .frame(width: 5, height: 5)
            Text(chipLabel(for: metric))
                .font(.system(size: metrics.captionSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The width estimate behind `chipWindows` is an estimate, so the
                // last chip on a narrow row still has to give up its tail rather
                // than push its neighbours off the edge.
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    /// The panel's chip carries its counts whatever the row toggles say, so this
    /// one does too. A chip reading "Weekly" names a window and reports nothing
    /// about it, which is the one thing a chip is for.
    private func chipLabel(for metric: UsageMetric) -> String {
        "\(metric.label) \(metric.displayUsed)/\(metric.displayLimit)"
    }

    private func bar(for metric: UsageMetric, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(fill(for: metric))
                    // The floor is the bar's own height, as in the panel: at 12pt
                    // thickness a 3pt fill is a squashed sliver, and an untouched
                    // window draws no fill at all rather than a permanent nub.
                    .frame(width: metric.percent > 0
                           ? max(height, geo.size.width * metric.percent)
                           : 0)
            }
        }
        .frame(height: height)
    }

    private func tint(for metric: UsageMetric) -> Color {
        appearance.tint(for: metric.percent, providerAccent: service.accent)
    }

    private func fill(for metric: UsageMetric) -> AnyShapeStyle {
        let colour = tint(for: metric)
        guard appearance.usesGradientFill else { return AnyShapeStyle(colour) }
        return AnyShapeStyle(
            LinearGradient(
                colors: [colour.opacity(0.75), colour],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    /// The counts and the countdown share a line, and either can be switched
    /// off — so the separator only appears when there are two things to separate.
    private func detailText(for metric: UsageMetric) -> String? {
        var parts: [String] = []
        if appearance.showsAmounts {
            let unit = metric.unit.map { " \($0)" } ?? ""
            parts.append("\(metric.displayUsed) / \(metric.displayLimit)\(unit)")
        }
        if appearance.showsCountdowns, let reset = metric.resetDate,
           let countdown = Countdown.short(until: reset) {
            parts.append("resets in \(countdown)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
