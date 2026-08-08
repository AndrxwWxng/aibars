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

    public var body: some View {
        // Top alignment lines a 40pt logo up with the name rather than with the
        // middle of a stack of bars — but a row with nothing under its title is
        // one 13pt line beside that logo, and top alignment leaves it hanging
        // from the ceiling of a 40pt row.
        HStack(alignment: drawsDetail ? .top : .center,
               spacing: hasLeading ? Tokens.Space.leadingColumn : 0) {
            leading

            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                titleLine
                detailContent
            }
        }
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .padding(.vertical, metrics.rowVerticalPadding)
        .background(
            Tokens.surface(Tokens.Radius.row)
                .fill(Tokens.quiet(Tokens.rowBackground(appearance.rowBackground, isHovered: isHovered)))
                // Held inside the gutter so a hovered card floats rather than
                // touching the window edge.
                .padding(.horizontal, Tokens.Space.cardInset)
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
                        providerID: provider.serviceID,
                        fallbackName: provider.displayName,
                        fallbackColor: provider.accentColor,
                        size: appearance.logoSize,
                        showsTile: appearance.logoStyle == .tile
                    )
                    .opacity(provider.isAuthenticated ? 1 : Tokens.Dim.disconnected)
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
            .padding(.top, Tokens.Space.hairline)
        }
    }

    // MARK: - Title

    private var titleLine: some View {
        HStack(spacing: Tokens.Space.small) {
            Text(provider.displayName)
                .font(.system(size: metrics.titleSize, weight: Tokens.Ramp.titleWeight))
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
                    .font(.system(size: metrics.captionSize, weight: Tokens.Ramp.emphasisWeight))
                    // A pill that wraps to a second line stops being a pill.
                    .lineLimit(1)
                    .padding(.horizontal, Tokens.Space.small)
                    .padding(.vertical, Tokens.Space.hairline)
                    .background(Capsule().fill(Tokens.quiet(Tokens.Fill.pill)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Tokens.Space.snug)

            // Only an authenticated row has anything to refresh or open, so a
            // disconnected one reclaims the space rather than reserving it for
            // buttons it will never draw.
            if provider.isAuthenticated {
                RowActions(
                    visibility: appearance.rowActions,
                    isHovered: isHovered,
                    hasDashboard: provider.dashboardURL != nil,
                    refreshHelp: "Refresh \(provider.displayName)",
                    onRefresh: onRefresh,
                    onOpenDashboard: onOpenDashboard
                )
            }

            trailingValue
        }
    }

    @ViewBuilder
    private var trailingValue: some View {
        if !provider.isAuthenticated {
            Button(action: onSignIn) {
                Text("Sign in")
                    .font(.system(size: metrics.detailSize, weight: Tokens.Ramp.emphasisWeight))
                    // The one control on a disconnected row, so it is the last
                    // thing that should give: a crowded title line otherwise
                    // squeezes it to "Si…".
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if appearance.showsUsageNumber, case .success(let data) = result, data.primary.limit > 0 {
            // Trailing, so the figure lands on the same x on every row — the
            // same column the secondary percentages under it stop at.
            Text("\(Int((data.primary.percent * 100).rounded()))%")
                .font(.system(size: metrics.titleSize,
                              weight: Tokens.Ramp.titleWeight,
                              design: Tokens.Ramp.figureDesign))
                .monospacedDigit()
                .foregroundStyle(tint(for: data.primary.percent))
                // Unconstrained, a Text under a title line too narrow for it
                // wraps rather than truncates — "100%" becomes "100" over "%",
                // and the row grows a line. It ranks with the name, not with the
                // pill: under `numberOnly` it is the entire reading.
                .lineLimit(1)
                .layoutPriority(1)
                // And it never gives width either. Sharing priority 1 with the
                // service name means both shrink together on the narrowest panel
                // behind the widest logo and dial, and "10…" is not a smaller
                // reading of 100% — it is a different one. A truncated name is
                // still a name, so the name is what gives.
                .fixedSize()
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
                // "Not connected — add a token in Settings" is wider than the
                // text column of a 300pt row at any density, and a Text that is
                // not allowed to grow downward truncates instead of wrapping —
                // which would cut the half that says what to do. Same two-line
                // ceiling the error line takes, for the same reason.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: Tokens.lineBox(metrics.detailSize), alignment: .leading)
        } else if let result {
            switch result {
            case .success(let data):
                primaryMetric(data.primary)
                secondaryWindows(data.secondary)
            case .failure(let error):
                HStack(alignment: .top, spacing: Tokens.Space.small) {
                    Image(systemName: error.isAuth
                          ? "person.crop.circle.badge.exclamationmark"
                          : "exclamationmark.triangle.fill")
                        .font(.system(size: metrics.captionSize))
                        // A credential the user has to go and fix is the same
                        // state a locked session is, and the same amber; a
                        // service that answered badly is the only red.
                        .foregroundStyle(error.isAuth ? Tokens.Ink.attention : Tokens.Ink.failure)
                    Text(error.errorDescription ?? "Error")
                        .font(.system(size: metrics.detailSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: Tokens.lineBox(metrics.detailSize), alignment: .leading)
            }
        } else {
            HStack(spacing: Tokens.Space.small) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    // `scaleEffect` shrinks what is drawn, never what is
                    // reserved: a mini spinner still asks for its full square,
                    // which is taller than the caption that replaces it when the
                    // fetch lands. Held to the line box the rest of this row is
                    // floored at, or the spinner sets the height instead and every
                    // row shrinks as its first refresh comes back — nine of them
                    // resizing the window under the pointer.
                    .frame(width: Tokens.lineBox(metrics.detailSize),
                           height: Tokens.lineBox(metrics.detailSize))
                Text("Loading…")
                    .font(.system(size: metrics.detailSize))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: Tokens.lineBox(metrics.detailSize), alignment: .leading)
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
                //
                // On the enclosing VStack's own spacing, with nothing added on
                // top: the pitch from the primary meter to the first secondary
                // one is then the same as the pitch between two secondaries, so
                // the third window of one service sits on the same line as the
                // third of the next.
                VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                    ForEach(numbered(windows, limit: appearance.secondaryWindowLimit)) { window in
                        secondaryWindow(window.metric)
                    }
                }
            case .chips:
                HStack(spacing: Tokens.Space.snug) {
                    ForEach(numbered(windows, limit: chipLimit)) { window in
                        SecondaryChip(metric: window.metric, accent: provider.accentColor, appearance: appearance)
                    }
                }
            case .hidden:
                EmptyView()
            }
        }
    }

    /// A window and where it sits in the row, which is the only id it has that
    /// cannot repeat.
    ///
    /// A service can report two windows under one name: Claude's per-model weekly
    /// caps all come back as "Weekly · per-model" whenever the payload names no
    /// model, and Gemini's unrecognised buckets as "Window 2". Keyed on `label`,
    /// a repeated `ForEach` id draws one of them and drops the rest, so a service
    /// with four windows would quietly show three.
    private struct NumberedMetric: Identifiable {
        let id: Int
        let metric: UsageMetric
    }

    private func numbered(_ windows: [UsageMetric], limit: Int) -> [NumberedMetric] {
        windows.prefix(limit).enumerated().map { NumberedMetric(id: $0.offset, metric: $0.element) }
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
        // The chip's own furniture — dot, gap, both paddings — read off the
        // chip, then the gap to the next chip, then about nine characters of
        // "7d 12/100". The gap has to be in here: read off the chip alone this
        // is the exact width of one chip with nothing left over, so the estimate
        // promises a chip more than the line holds and the last one arrives as
        // an ellipsis. Erring generous is the wrong direction — one chip that
        // can be read says more than four that cannot.
        let furniture = Tokens.Control.chipDot + Tokens.Space.snug + 2 * Tokens.Space.small
        let chipWidth = furniture + Tokens.Space.snug + metrics.captionSize * 5
        return max(1, min(appearance.secondaryWindowLimit, Int(textColumnWidth / chipWidth)))
    }

    @ViewBuilder
    private func secondaryWindow(_ metric: UsageMetric) -> some View {
        if metric.limit > 0 {
            switch appearance.meterStyle {
            case .bar:
                UsageBar(metric: metric, isSecondary: true, accent: provider.accentColor, appearance: appearance)
            case .ring:
                // Indented by its own dial, the way the row's content is
                // indented by the primary one: a dial always precedes the thing
                // it measures. The caption still ends at the text column's
                // trailing edge, so the percentages stay in one column.
                HStack(spacing: Tokens.Space.small) {
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
        // A name the user typed wins over anything we inferred — they know which
        // account is which and we frequently do not.
        if let custom = AppState.customAccountName(for: provider.id) { return custom }
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

/// The per-row refresh and dashboard buttons.
///
/// Reserved, never inserted. Adding the buttons on hover changed the row's
/// height, so every row grew as the pointer crossed it and the panel resized
/// under the cursor — `MenuBarExtra` sizes its window to the content. They
/// occupy their space whenever the user has not switched them off, and only
/// their opacity changes. `.never` is the one case that reclaims the space,
/// because then no state of the row ever draws them.
///
/// Written to be shared with the Appearance pane's sample row, which is the one
/// place in the app whose job is to show what the panel will look like. That row
/// still reimplements the rule as `if showsActions` and so still inserts the
/// buttons on hover — the preview demonstrates exactly the behaviour the panel is
/// forbidden from having. It should call this instead.
public struct RowActions: View {
    public let visibility: AppearanceSettings.RowActionVisibility
    public let isHovered: Bool
    /// A service with no usage page gets one button. The sample row passes true
    /// because the row it is drawing is a stand-in for any service.
    public let hasDashboard: Bool
    public let refreshHelp: String
    public let onRefresh: () -> Void
    public let onOpenDashboard: () -> Void

    public init(
        visibility: AppearanceSettings.RowActionVisibility,
        isHovered: Bool,
        hasDashboard: Bool,
        refreshHelp: String = "Refresh",
        onRefresh: @escaping () -> Void = {},
        onOpenDashboard: @escaping () -> Void = {}
    ) {
        self.visibility = visibility
        self.isHovered = isHovered
        self.hasDashboard = hasDashboard
        self.refreshHelp = refreshHelp
        self.onRefresh = onRefresh
        self.onOpenDashboard = onOpenDashboard
    }

    private var isShown: Bool {
        switch visibility {
        case .onHover: return isHovered
        case .always:  return true
        case .never:   return false
        }
    }

    public var body: some View {
        if visibility != .never {
            HStack(spacing: 0) {
                HoverIconButton(
                    systemName: "arrow.clockwise",
                    help: refreshHelp,
                    size: Tokens.Control.rowIconButton,
                    action: onRefresh
                )
                if hasDashboard {
                    HoverIconButton(
                        systemName: "arrow.up.right",
                        help: "Open usage page",
                        size: Tokens.Control.rowIconButton,
                        action: onOpenDashboard
                    )
                }
            }
            .opacity(isShown ? 1 : Tokens.Dim.reserved)
            // Invisible buttons must not be clickable.
            .allowsHitTesting(isShown)
        }
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

    /// A caption belongs to the bar above it, so it sits at half the pitch that
    /// separates one meter from the next. One rule for both kinds of bar: the
    /// headline window used to sit 1pt off the content spacing and a secondary
    /// one 2pt off it, which made a stack of meters an uneven ladder.
    private var captionGap: CGFloat {
        max(Tokens.Space.tight, (metrics.contentSpacing / 2).rounded())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: captionGap) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Tokens.quiet(Tokens.Fill.track))
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
                colors: [tint.opacity(Tokens.Fill.gradientFloor), tint],
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
                .strokeBorder(Tokens.quiet(Tokens.Fill.track), lineWidth: stroke)
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
///
/// Two columns, not one run of text. What the window is and how much of it is
/// gone read from the left; when it renews and how full it is are pushed to the
/// trailing edge, so those two land on the same x on every line of every row
/// instead of wherever the amounts before them happened to stop.
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
        // Left unconstrained, a Text narrower than its content wraps rather than
        // truncates, so at 300pt these would quietly become three lines and
        // shove the row apart.
        HStack(spacing: Tokens.Space.snug) {
            if isSecondary {
                Text(metric.label)
                    .font(.system(size: size, weight: Tokens.Ramp.emphasisWeight))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Which window this is outranks how much of it is gone: the
                    // counts and the countdown are the verbose part, so they are
                    // the part that truncates first.
                    .layoutPriority(1)
                if appearance.showsAmounts, !secondaryAmount.isEmpty {
                    Text(secondaryAmount)
                        .font(.system(size: size))
                        .foregroundStyle(.secondary)
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

            Spacer(minLength: Tokens.Space.snug)

            if appearance.showsCountdowns, let reset = resetText {
                Text(reset)
                    .font(.system(size: size))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if appearance.showsUsageNumber {
                // Held on the primary line as well, where the figure itself is
                // up on the title line: without the empty column the countdown
                // beside a bar would stop one percentage further right than the
                // countdown on the secondary line under it.
                Text(isSecondary ? percentText : "")
                    .font(.system(size: size,
                                  weight: Tokens.Ramp.emphasisWeight,
                                  design: Tokens.Ramp.figureDesign))
                    .monospacedDigit()
                    .foregroundStyle(appearance.tint(for: metric.percent, providerAccent: accent))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .frame(minWidth: figureColumn, alignment: .trailing)
            }
        }
        .frame(minHeight: Tokens.lineBox(size))
    }

    /// Width held for the trailing percentage. A rounded monospaced figure runs
    /// about 0.6em to the digit, so "100%" needs roughly 2.5em — 2.8 leaves the
    /// column a hair of slack rather than letting a third digit shove the
    /// countdown left on one line and not the next.
    ///
    /// Off `detailSize` and not `size`: a secondary line sets its figures in
    /// caption type, and a column two points narrower on the third line of a row
    /// than on the first is the misalignment this exists to remove.
    private var figureColumn: CGFloat { (appearance.metrics.detailSize * 2.8).rounded() }

    private var percentText: String {
        "\(Int((metric.percent * 100).rounded()))%"
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
        HStack(spacing: Tokens.Space.small) {
            Circle()
                .fill(metric.used > 0
                      ? appearance.tint(for: 0, providerAccent: accent)
                      : Tokens.Ink.idle)
                .frame(width: Tokens.Control.dot, height: Tokens.Control.dot)
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Tokens.Space.snug)

            // Trailing, like every other countdown in the panel, so a quotaless
            // row's renewal date sits in the same column as the reset date on
            // the metered row above it.
            if appearance.showsCountdowns,
               let reset = metric.resetDate,
               let countdown = Countdown.short(until: reset) {
                Text("renews in \(countdown)")
                    .font(.system(size: size))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: Tokens.lineBox(size))
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
        HStack(spacing: Tokens.Space.snug) {
            Text(metric.label)
                .font(.system(size: size, weight: Tokens.Ramp.emphasisWeight))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Governed by showsAmounts like every other raw count, but the
            // label stays: a bare window name is still a window this service
            // reports, and dropping the row would hide that.
            if appearance.showsAmounts {
                Text(value)
                    .font(.system(size: size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Tokens.lineBox(size))
    }

    private var value: String {
        let unit = metric.unit.map { " \($0)" } ?? ""
        return "\(metric.displayUsed)\(unit)"
    }
}

/// A further window folded down to one pill, for `secondaryWindows == .chips`.
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
        HStack(spacing: Tokens.Space.snug) {
            Circle()
                .fill(appearance.tint(for: metric.percent, providerAccent: accent))
                .frame(width: Tokens.Control.chipDot, height: Tokens.Control.chipDot)
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
        .padding(.horizontal, Tokens.Space.small)
        .padding(.vertical, Tokens.Space.tight)
        .background(Capsule().fill(Tokens.quiet(Tokens.Fill.pill)))
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
