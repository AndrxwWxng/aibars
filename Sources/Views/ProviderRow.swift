import SwiftUI

public struct ProviderRow: View {
    @ObservedObject var provider: AnyUsageProvider
    public let result: Result<UsageData, ProviderError>?
    public let onSignIn: () -> Void
    public let onOpenDashboard: () -> Void
    public let onRefresh: () -> Void
    /// Show every window the provider reports, each with its own bar.
    public let showsAllWindows: Bool
    public let showsPlanName: Bool

    @State private var isHovered = false

    public init(
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?,
        onSignIn: @escaping () -> Void,
        onOpenDashboard: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        showsAllWindows: Bool = true,
        showsPlanName: Bool = true
    ) {
        self.provider = provider
        self.result = result
        self.onSignIn = onSignIn
        self.onOpenDashboard = onOpenDashboard
        self.onRefresh = onRefresh
        self.showsAllWindows = showsAllWindows
        self.showsPlanName = showsPlanName
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ProviderLogo(
                providerID: provider.id,
                fallbackName: provider.displayName,
                fallbackColor: provider.accentColor,
                size: 30
            )
            .padding(.top, 1)
            .opacity(provider.isAuthenticated ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 5) {
                titleLine
                detailContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
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

    // MARK: - Title

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if showsPlanName, let plan = planName {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Hover reveals the per-row actions in place of the plan pill's
            // whitespace, so the resting state stays uncluttered.
            if isHovered && provider.isAuthenticated {
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

    @ViewBuilder
    private var trailingValue: some View {
        if !provider.isAuthenticated {
            Button(action: onSignIn) {
                Text("Sign in")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if case .success(let data) = result, data.primary.limit > 0 {
            Text("\(Int((data.primary.percent * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(UsageTint.color(for: data.primary.percent))
        }
    }

    // MARK: - Body of the row

    @ViewBuilder
    private var detailContent: some View {
        if !provider.isAuthenticated {
            Text(signInPrompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let result {
            switch result {
            case .success(let data):
                if data.primary.limit > 0 {
                    UsageBar(metric: data.primary)
                } else {
                    StatusLine(metric: data.primary)
                }
                if !data.secondary.isEmpty {
                    if showsAllWindows {
                        // Each further window gets its own bar. A weekly cap you
                        // are 80% through matters as much as the 5-hour one, and
                        // a chip reading "7d 80%" buries that.
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(data.secondary.prefix(4), id: \.label) { metric in
                                if metric.limit > 0 {
                                    UsageBar(metric: metric, isSecondary: true)
                                } else {
                                    // No ceiling: a bar would always read empty
                                    // and "600 / 0" is worse than the bare value.
                                    SecondaryValue(metric: metric)
                                }
                            }
                        }
                        .padding(.top, 3)
                    } else {
                        HStack(spacing: 5) {
                            ForEach(data.secondary.prefix(3), id: \.label) { metric in
                                SecondaryChip(metric: metric)
                            }
                        }
                        .padding(.top, 1)
                    }
                }
            case .failure(let error):
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: error.isAuth
                          ? "person.crop.circle.badge.exclamationmark"
                          : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(error.isAuth ? .orange : .red)
                    Text(error.errorDescription ?? "Error")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 14)
        }
    }

    private var signInPrompt: String {
        provider.webLogin == nil
            ? "Not connected — add a token in Settings"
            : "Not connected"
    }

    private var planName: String? {
        guard case .success(let data) = result, provider.isAuthenticated,
              let plan = data.planName else { return nil }
        return PlanName.pretty(plan, service: provider.displayName)
    }
}

/// The primary usage bar: a thin track, a tinted fill, and one line of
/// context underneath.
public struct UsageBar: View {
    public let metric: UsageMetric
    /// A further window rather than the headline one: thinner bar, smaller type,
    /// and the window's own name in front so "7d" and "GPT-4o" are told apart.
    public let isSecondary: Bool

    public init(metric: UsageMetric, isSecondary: Bool = false) {
        self.metric = metric
        self.isSecondary = isSecondary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: isSecondary ? 3 : 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.75), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(3, geo.size.width * metric.percent))
                }
            }
            .frame(height: isSecondary ? 3 : 5)

            HStack(spacing: 4) {
                if isSecondary {
                    Text(metric.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(secondaryAmount)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    if let reset = resetText {
                        Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(reset)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(amountText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let reset = resetText, !isSecondary {
                    Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if isSecondary {
                    Text("\(Int((metric.percent * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(UsageTint.color(for: metric.percent))
                }
            }
        }
    }

    /// The secondary line already carries its own label and percentage, so this
    /// is only the raw counts — and nothing at all for a percentage metric,
    /// where "47 / 100" would just repeat the badge.
    private var secondaryAmount: String {
        if metric.unit == "%" || metric.limit == 100 { return "" }
        let unit = metric.unit.map { " \($0)" } ?? ""
        return "\(metric.displayUsed) / \(metric.displayLimit)\(unit)"
    }

    private var tint: Color { UsageTint.color(for: metric.percent) }

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
    public let metric: UsageMetric

    public init(metric: UsageMetric) {
        self.metric = metric
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(metric.used > 0 ? UsageTint.color(for: 0) : Color.secondary)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let reset = metric.resetDate, let countdown = Countdown.short(until: reset) {
                Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("renews in \(countdown)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
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
    public let metric: UsageMetric

    public init(metric: UsageMetric) {
        self.metric = metric
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(metric.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var value: String {
        let unit = metric.unit.map { " \($0)" } ?? ""
        return "\(metric.displayUsed)\(unit)"
    }
}

public struct SecondaryChip: View {
    public let metric: UsageMetric

    public init(metric: UsageMetric) {
        self.metric = metric
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(UsageTint.color(for: metric.percent))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
