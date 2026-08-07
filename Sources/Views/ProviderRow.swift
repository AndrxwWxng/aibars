import SwiftUI

public struct ProviderRow: View {
    @ObservedObject var provider: AnyUsageProvider
    @ObservedObject private var appearance: AppearanceSettings
    public let result: Result<UsageData, ProviderError>?
    public let onSignIn: () -> Void
    public let onOpenDashboard: () -> Void
    public let onRefresh: () -> Void
    /// Overrides `AppearanceSettings.secondaryWindows`: true is `.expanded`,
    /// false is `.chips`. Only still here so callers written against the old
    /// flag keep compiling — nil, the setting, is the normal case.
    public let showsAllWindows: Bool?
    /// Overrides `AppearanceSettings.showsPlanNames`. Nil follows the setting.
    public let showsPlanName: Bool?

    @State private var isHovered = false

    public init(
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?,
        onSignIn: @escaping () -> Void,
        onOpenDashboard: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        showsAllWindows: Bool? = nil,
        showsPlanName: Bool? = nil,
        appearance: AppearanceSettings? = nil
    ) {
        self.provider = provider
        self.result = result
        self.onSignIn = onSignIn
        self.onOpenDashboard = onOpenDashboard
        self.onRefresh = onRefresh
        self.showsAllWindows = showsAllWindows
        self.showsPlanName = showsPlanName
        // Resolved here rather than as a default argument: a default argument
        // is evaluated at the call site, and `shared` is main-actor isolated,
        // so that would constrain who is allowed to build a row.
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }

    // Both gaps in the leading column are named rather than written where they
    // are used, because `chipLimit` has to subtract them to know what width the
    // text column was left with.

    /// Logo-and-dial column to the text beside it.
    private static let textGap: CGFloat = 11
    /// Logo to dial, inside that column.
    private static let leadingSpacing: CGFloat = 7

    public var body: some View {
        // Top alignment lines a 40pt logo up with the name rather than with the
        // middle of a stack of bars — but a row with nothing under its title is
        // one 13pt line beside that logo, and top alignment leaves it hanging
        // from the ceiling of a 40pt row.
        HStack(alignment: drawsDetail ? .top : .center, spacing: hasLeading ? Self.textGap : 0) {
            leading

            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                titleLine
                detailContent
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
        .onTapGesture {
            provider.isAuthenticated ? onOpenDashboard() : onSignIn()
        }
        .help(provider.isAuthenticated
              ? (provider.dashboardURL != nil ? "Open \(provider.displayName) usage page" : "")
              : "Sign in to \(provider.displayName)")
    }

    private var backgroundOpacity: Double {
        switch appearance.rowBackground {
        case .plain:  return 0
        case .hover:  return isHovered ? 0.06 : 0
        // The resting card still has to lift under the pointer, or the row
        // stops answering "is this the one I'm about to click".
        case .always: return isHovered ? 0.09 : 0.05
        }
    }

    // MARK: - Leading column

    /// False collapses the gap as well as the column — an 11pt indent in front
    /// of nothing reads as a broken layout, not as a text list.
    private var hasLeading: Bool {
        appearance.logoStyle != .hidden || appearance.meterStyle == .ring
    }

    /// Width of the logo-and-dial column, the gap to the text included. What is
    /// left of the panel after it is the text column, which is the only width
    /// budget this row gets to reason about.
    private var leadingWidth: CGFloat {
        guard hasLeading else { return 0 }
        let logo = appearance.logoStyle == .hidden ? 0 : CGFloat(appearance.logoSize)
        let ring = appearance.meterStyle == .ring ? metrics.ringDiameter : 0
        let inner = (logo > 0 && ring > 0) ? Self.leadingSpacing : 0
        return logo + ring + inner + Self.textGap
    }

    private var textColumnWidth: CGFloat {
        CGFloat(appearance.panelWidth) - 2 * metrics.rowHorizontalPadding - leadingWidth
    }

    @ViewBuilder
    private var leading: some View {
        if hasLeading {
            HStack(spacing: Self.leadingSpacing) {
                if appearance.logoStyle != .hidden {
                    ProviderLogo(
                        providerID: provider.serviceID,
                        fallbackName: provider.displayName,
                        fallbackColor: provider.accentColor,
                        size: appearance.logoSize,
                        showsTile: appearance.logoStyle == .tile
                    )
                    .opacity(provider.isAuthenticated ? 1 : 0.55)
                }

                if appearance.meterStyle == .ring {
                    // Drawn even with nothing to report, so the text column
                    // starts at the same x on every row of the panel.
                    UsageRing(
                        percent: primaryPercent ?? 0,
                        diameter: metrics.ringDiameter,
                        thickness: metrics.barHeight,
                        tint: tint(for: primaryPercent ?? 0)
                    )
                }
            }
            .padding(.top, 1)
        }
    }

    // MARK: - Title

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(provider.displayName)
                .font(.system(size: metrics.titleSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                // The name is the one thing the row cannot be read without, so
                // it takes its width before the account label and the pill.
                .layoutPriority(1)

            // With several accounts of one service, the name alone is the same
            // word repeated — say which account it is.
            if appearance.showsAccountLabels, let account = accountLabel {
                Text(account)
                    .font(.system(size: metrics.captionSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }

            if showsPlan, let plan = planName {
                Text(plan)
                    .font(.system(size: metrics.captionSize, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if showsActions && provider.isAuthenticated {
                HoverIconButton(systemName: "arrow.clockwise", help: "Refresh \(provider.displayName)", action: onRefresh)
                    .frame(width: 20, height: 18)
                if provider.dashboardURL != nil {
                    HoverIconButton(systemName: "arrow.up.right", help: "Open usage page", action: onOpenDashboard)
                        .frame(width: 20, height: 18)
                }
            }

            trailingValue
        }
    }

    /// Hover reveals the per-row actions in place of the plan pill's whitespace,
    /// so the resting state stays uncluttered — unless the user has asked for
    /// them to be permanent, or gone.
    private var showsActions: Bool {
        switch appearance.rowActions {
        case .onHover: return isHovered
        case .always:  return true
        case .never:   return false
        }
    }

    @ViewBuilder
    private var trailingValue: some View {
        if !provider.isAuthenticated {
            Button(action: onSignIn) {
                Text("Sign in")
                    .font(.system(size: metrics.detailSize, weight: .medium))
                    // The one control on a disconnected row, so it is the last
                    // thing that should give: a crowded title line otherwise
                    // squeezes it to "Si…".
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if appearance.showsUsageNumber, case .success(let data) = result, data.primary.limit > 0 {
            Text("\(Int((data.primary.percent * 100).rounded()))%")
                .font(.system(size: metrics.titleSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint(for: data.primary.percent))
                // Unconstrained, a Text under a title line too narrow for it
                // wraps rather than truncates — "100%" becomes "100" over "%",
                // and the row grows a line. It ranks with the name, not with the
                // pill: under `numberOnly` it is the entire reading.
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    // MARK: - Body of the row

    /// Whether anything at all is drawn beneath the title line. Has to agree
    /// with `detailContent` below, since the row's vertical alignment turns on
    /// it — the two are kept next to each other for that reason.
    private var drawsDetail: Bool {
        // "Not connected", "Loading…" and an error are each a line of their own.
        guard provider.isAuthenticated, case .success(let data) = result else { return true }
        // A quotaless provider gets its StatusLine; a bar is always drawn.
        guard data.primary.limit > 0, appearance.meterStyle != .bar else { return true }
        if caption(for: data.primary, isSecondary: false).hasContent { return true }
        return !data.secondary.isEmpty
            && appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) != .hidden
    }

    @ViewBuilder
    private var detailContent: some View {
        if !provider.isAuthenticated {
            Text(signInPrompt)
                .font(.system(size: metrics.detailSize))
                .foregroundStyle(.secondary)
        } else if let result {
            switch result {
            case .success(let data):
                primaryMetric(data.primary)
                secondaryWindows(data.secondary)
            case .failure(let error):
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: error.isAuth
                          ? "person.crop.circle.badge.exclamationmark"
                          : "exclamationmark.triangle.fill")
                        .font(.system(size: metrics.captionSize))
                        .foregroundStyle(error.isAuth ? .orange : .red)
                    Text(error.errorDescription ?? "Error")
                        .font(.system(size: metrics.detailSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Loading…")
                    .font(.system(size: metrics.detailSize))
                    .foregroundStyle(.secondary)
            }
            .frame(height: metrics.detailSize + 3)
        }
    }

    @ViewBuilder
    private func primaryMetric(_ metric: UsageMetric) -> some View {
        if metric.limit > 0 {
            switch appearance.meterStyle {
            case .bar:
                UsageBar(metric: metric, accent: provider.accentColor, appearance: appearance)
            case .ring, .numberOnly:
                // The dial in the leading column and the trailing percentage
                // are the meter here; only the context line is left to draw,
                // and with both its halves switched off the row is one line.
                if caption(for: metric, isSecondary: false).hasContent {
                    caption(for: metric, isSecondary: false)
                }
            }
        } else {
            StatusLine(metric: metric, accent: provider.accentColor, appearance: appearance)
        }
    }

    @ViewBuilder
    private func secondaryWindows(_ windows: [UsageMetric]) -> some View {
        if !windows.isEmpty {
            switch appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) {
            case .expanded:
                // Each further window gets its own meter. A weekly cap you are
                // 80% through matters as much as the 5-hour one, and a chip
                // reading "7d 80%" buries that.
                VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                    ForEach(windows.prefix(appearance.secondaryWindowLimit), id: \.label) { metric in
                        secondaryWindow(metric)
                    }
                }
                .padding(.top, max(0, metrics.contentSpacing - 2))
            case .chips:
                HStack(spacing: 5) {
                    ForEach(windows.prefix(chipLimit), id: \.label) { metric in
                        SecondaryChip(metric: metric, accent: provider.accentColor, appearance: appearance)
                    }
                }
                .padding(.top, 1)
            case .hidden:
                EmptyView()
            }
        }
    }

    /// Chips are a single unwrapped line, so their ceiling is width rather than
    /// a count: 520pt of empty panel takes all six, 300pt behind a 40pt logo
    /// takes two, and with a dial beside that logo as well, one. A flat cap of
    /// four gets both ends of that wrong, and the narrow end is the one that
    /// matters — four chips compressed to four ellipses say strictly less than
    /// one chip that can still be read. The expanded style runs down the panel
    /// rather than along it and needs no such ceiling.
    ///
    /// Estimated rather than measured: a GeometryReader here would have to
    /// resolve before the row could report a height, and MenuBarExtra sizes its
    /// window to the height the rows report.
    private var chipLimit: Int {
        // A dot, the capsule's padding, and about nine characters of "7d 12/100".
        let chipWidth = 26 + metrics.captionSize * 5
        return max(1, min(appearance.secondaryWindowLimit, Int(textColumnWidth / chipWidth)))
    }

    @ViewBuilder
    private func secondaryWindow(_ metric: UsageMetric) -> some View {
        if metric.limit > 0 {
            switch appearance.meterStyle {
            case .bar:
                UsageBar(metric: metric, isSecondary: true, accent: provider.accentColor, appearance: appearance)
            case .ring:
                HStack(spacing: 6) {
                    UsageRing(
                        percent: metric.percent,
                        diameter: metrics.ringDiameter * 0.55,
                        thickness: metrics.secondaryBarHeight,
                        tint: tint(for: metric.percent)
                    )
                    caption(for: metric, isSecondary: true)
                }
            case .numberOnly:
                caption(for: metric, isSecondary: true)
            }
        } else {
            // No ceiling: a meter would always read empty and "600 / 0" is
            // worse than the bare value.
            SecondaryValue(metric: metric, appearance: appearance)
        }
    }

    private func caption(for metric: UsageMetric, isSecondary: Bool) -> MetricCaption {
        MetricCaption(metric: metric, isSecondary: isSecondary, accent: provider.accentColor, appearance: appearance)
    }

    private func tint(for percent: Double) -> Color {
        appearance.tint(for: percent, providerAccent: provider.accentColor)
    }

    private var showsPlan: Bool { showsPlanName ?? appearance.showsPlanNames }

    private var signInPrompt: String {
        provider.webLogin == nil
            ? "Not connected — add a token in Settings"
            : "Not connected"
    }

    private var primaryPercent: Double? {
        guard case .success(let data) = result, data.primary.limit > 0 else { return nil }
        return data.primary.percent
    }

    /// Who this row is. The service's own answer when it gives one, otherwise
    /// the browser profile the session came from — which is at least enough to
    /// tell two accounts apart.
    private var accountLabel: String? {
        if case .success(let data) = result, let account = data.accountLabel, !account.isEmpty {
            return account
        }
        guard provider.accountID != nil || provider.browserOrigin != nil else { return nil }
        return provider.browserOrigin
    }

    private var planName: String? {
        guard case .success(let data) = result, provider.isAuthenticated,
              let plan = data.planName else { return nil }
        return PlanName.pretty(plan, service: provider.displayName)
    }
}

private extension AppearanceSettings {
    /// The trailing percentage is one figure among several next to a bar or a
    /// dial, but with `numberOnly` it *is* the meter — hiding it there would
    /// leave a row with no usage in it at all.
    var showsUsageNumber: Bool { showsPercentage || meterStyle == .numberOnly }

    func secondaryWindowStyle(overriddenBy flag: Bool?) -> SecondaryWindowStyle {
        guard let flag else { return secondaryWindows }
        return flag ? .expanded : .chips
    }
}

/// The primary usage bar: a thin track, a tinted fill, and one line of
/// context underneath.
public struct UsageBar: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    /// A further window rather than the headline one: thinner bar, smaller type,
    /// and the window's own name in front so "7d" and "GPT-4o" are told apart.
    public let isSecondary: Bool
    /// The service's brand colour, which `colorRamp == .provider` paints with.
    public let accent: Color

    public init(
        metric: UsageMetric,
        isSecondary: Bool = false,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil
    ) {
        self.metric = metric
        self.isSecondary = isSecondary
        self.accent = accent
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }
    private var height: CGFloat { isSecondary ? metrics.secondaryBarHeight : metrics.barHeight }
    private var caption: MetricCaption {
        MetricCaption(metric: metric, isSecondary: isSecondary, accent: accent, appearance: appearance)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: max(2, metrics.contentSpacing - (isSecondary ? 2 : 1))) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                    Capsule(style: .continuous)
                        .fill(fill)
                        // A nonzero value never rounds away to nothing, but the
                        // floor is the bar's own height rather than a fixed 3pt
                        // — at 12pt thickness a 3pt fill is a squashed sliver.
                        .frame(width: metric.percent > 0
                               ? max(height, geo.size.width * metric.percent)
                               : 0)
                }
            }
            .frame(height: height)

            if caption.hasContent { caption }
        }
    }

    /// A flat fill reads as the more clinical panel; the gradient is what the
    /// app has always drawn.
    private var fill: AnyShapeStyle {
        let tint = appearance.tint(for: metric.percent, providerAccent: accent)
        guard appearance.usesGradientFill else { return AnyShapeStyle(tint) }
        return AnyShapeStyle(
            LinearGradient(
                colors: [tint.opacity(0.75), tint],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

/// A compact dial, for `meterStyle == .ring`. Carries no number of its own —
/// at the diameters this is drawn at, two digits inside the ring are smaller
/// than the tertiary captions, and the percentage is already on the title line.
public struct UsageRing: View {
    public let percent: Double
    public let diameter: CGFloat
    public let thickness: CGFloat
    public let tint: Color

    public init(percent: Double, diameter: CGFloat, thickness: CGFloat, tint: Color) {
        self.percent = percent
        self.diameter = diameter
        self.thickness = thickness
        self.tint = tint
    }

    /// A 12pt stroke on an 18pt dial is a disc with a dimple. Whatever the
    /// meter thickness, the ring keeps a hole a third of its width.
    private var stroke: CGFloat { min(thickness, diameter / 3) }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: stroke)
            if percent > 0 {
                Circle()
                    // `strokeBorder` insets for us; a trimmed path has to be
                    // inset by hand or the arc overhangs the track.
                    .inset(by: stroke / 2)
                    .trim(from: 0, to: min(max(percent, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The line of context under a meter: what the window is called, how much of it
/// is gone, and when it comes back. Every part of it is optional, so it also
/// answers whether it would draw anything at all.
public struct MetricCaption: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    public let isSecondary: Bool
    public let accent: Color

    public init(
        metric: UsageMetric,
        isSecondary: Bool = false,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil
    ) {
        self.metric = metric
        self.isSecondary = isSecondary
        self.accent = accent
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var size: CGFloat {
        isSecondary ? appearance.metrics.captionSize : appearance.metrics.detailSize
    }

    /// A secondary window always keeps its name — without it the row has two
    /// unlabelled meters and no way to tell which cap is which. The primary
    /// window is already named by the row itself, so it can vanish entirely.
    public var hasContent: Bool {
        if isSecondary { return true }
        return (appearance.showsAmounts && !amountText.isEmpty)
            || (appearance.showsCountdowns && resetText != nil)
    }

    public var body: some View {
        // A caption is one line of context under a meter. Left unconstrained, a
        // Text narrower than its content wraps rather than truncates, so at
        // 300pt these would quietly become three lines and shove the row apart.
        HStack(spacing: 4) {
            if isSecondary {
                Text(metric.label)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Which window this is outranks how much of it is gone: the
                    // counts and the countdown are the verbose part, so they are
                    // the part that truncates first.
                    .layoutPriority(1)
                if appearance.showsAmounts, !secondaryAmount.isEmpty {
                    Text(secondaryAmount)
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            } else if appearance.showsAmounts, !amountText.isEmpty {
                Text(amountText)
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if appearance.showsCountdowns, let reset = resetText {
                if showsSeparator {
                    Text("·").font(.system(size: size)).foregroundStyle(.tertiary)
                }
                Text(reset)
                    .font(.system(size: size))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isSecondary, appearance.showsUsageNumber {
                Text("\(Int((metric.percent * 100).rounded()))%")
                    .font(.system(size: size, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(appearance.tint(for: metric.percent, providerAccent: accent))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// The interpunct joins two things. A secondary line always has its label
    /// in front of the countdown; the primary line has only the amounts, and
    /// with those switched off a leading "·" is just a mark on the panel.
    private var showsSeparator: Bool {
        if isSecondary { return true }
        return appearance.showsAmounts && !amountText.isEmpty
    }

    /// The secondary line already carries its own label and percentage, so this
    /// is only the raw counts — and nothing at all for a percentage metric,
    /// where "47 / 100" would just repeat the badge.
    private var secondaryAmount: String {
        if metric.unit == "%" || metric.limit == 100 { return "" }
        let unit = metric.unit.map { " \($0)" } ?? ""
        return "\(metric.displayUsed) / \(metric.displayLimit)\(unit)"
    }

    /// For percentage metrics the number is already in the trailing badge, so
    /// the line underneath names the window instead of repeating "47 / 100".
    private var amountText: String {
        if metric.unit == "%" {
            return metric.label
        }
        let unit = metric.unit.map { " \($0)" } ?? ""
        if metric.limit > 0 {
            return "\(metric.displayUsed) / \(metric.displayLimit)\(unit)"
        }
        return "\(metric.displayUsed)\(unit) \(metric.label.lowercased())"
    }

    private var resetText: String? {
        guard let reset = metric.resetDate else { return nil }
        guard let countdown = Countdown.short(until: reset) else { return "reset due" }
        return "resets in \(countdown)"
    }
}

/// For providers that report a state rather than a quota — there's no bar to
/// draw, so show the state itself.
public struct StatusLine: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    public let accent: Color

    public init(
        metric: UsageMetric,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil
    ) {
        self.metric = metric
        self.accent = accent
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var size: CGFloat { appearance.metrics.detailSize }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(metric.used > 0 ? appearance.tint(for: 0, providerAccent: accent) : Color.secondary)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if appearance.showsCountdowns,
               let reset = metric.resetDate,
               let countdown = Countdown.short(until: reset) {
                Text("·").font(.system(size: size)).foregroundStyle(.tertiary)
                Text("renews in \(countdown)")
                    .font(.system(size: size))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: size + 3)
    }

    /// A unit is the provider saying "this is a count", so lead with the
    /// figure: "0 reqs this cycle" answers something, "GPT-4 class requests"
    /// does not. Without a unit the metric is a state — Copilot's "Active" —
    /// and prefixing it with a number would be nonsense.
    private var text: String {
        guard let unit = metric.unit else { return metric.label }
        return "\(metric.displayUsed) \(unit) \(metric.label.lowercased())"
    }
}

/// A further window that reports a figure but no ceiling.
public struct SecondaryValue: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric

    public init(metric: UsageMetric, appearance: AppearanceSettings? = nil) {
        self.metric = metric
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var size: CGFloat { appearance.metrics.captionSize }

    public var body: some View {
        HStack(spacing: 4) {
            Text(metric.label)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Governed by showsAmounts like every other raw count, but the
            // label stays: a bare window name is still a window this service
            // reports, and dropping the row would hide that.
            if appearance.showsAmounts {
                Text(value)
                    .font(.system(size: size))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var value: String {
        let unit = metric.unit.map { " \($0)" } ?? ""
        return "\(metric.displayUsed)\(unit)"
    }
}

public struct SecondaryChip: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    public let accent: Color

    public init(
        metric: UsageMetric,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil
    ) {
        self.metric = metric
        self.accent = accent
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(appearance.tint(for: metric.percent, providerAccent: accent))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: appearance.metrics.captionSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // Four chips of a long-named window overflow a 300pt panel;
                // truncating one label is better than pushing the last chip
                // off the edge.
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var label: String {
        if metric.unit == "%" || metric.limit == 100 {
            return "\(metric.label) \(Int(metric.used.rounded()))%"
        }
        return "\(metric.label) \(metric.displayUsed)/\(metric.displayLimit)"
    }
}

/// Compact "3h 12m" countdowns. `Date.formatted(.relative:)` produces
/// "in 3 hours" — longer, and less precise than a usage window warrants.
public enum Countdown {
    public static func short(until date: Date, from now: Date = Date()) -> String? {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }

        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 {
            let remainderHours = hours % 24
            return remainderHours > 0 ? "\(days)d \(remainderHours)h" : "\(days)d"
        }
        if hours > 0 {
            let remainderMinutes = minutes % 60
            return remainderMinutes > 0 ? "\(hours)h \(remainderMinutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
