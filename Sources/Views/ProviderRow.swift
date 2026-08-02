import SwiftUI

public struct ProviderRow: View {
    @ObservedObject var provider: AnyUsageProvider
    public let result: Result<UsageData, ProviderError>?
    public let isHovered: Bool
    public let onTap: () -> Void

    public var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(provider.accentColor.opacity(0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: provider.iconName)
                        .foregroundStyle(provider.accentColor)
                        .font(.system(size: 14, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(provider.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if let plan = planName {
                            Text(plan)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                    progressLine
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var progressLine: some View {
        if !provider.isAuthenticated {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Sign in required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let result {
            switch result {
            case .success(let data):
                UsageBar(metric: data.primary)
                if !data.secondary.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(data.secondary.prefix(3), id: \.label) { metric in
                            SecondaryChip(metric: metric)
                        }
                    }
                }
            case .failure(let error):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error.errorDescription ?? "Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var planName: String? {
        if case .success(let data) = result, let plan = data.planName {
            return plan
        }
        return nil
    }
}

public struct UsageBar: View {
    public let metric: UsageMetric

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * metric.percent))
                }
            }
            .frame(height: 4)

            HStack {
                Text(metric.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var color: Color {
        switch metric.percent {
        case ..<0.5: return .green
        case ..<0.8: return .yellow
        default: return .red
        }
    }

    private var detailText: String {
        if metric.unit == "%" {
            return "\(Int(metric.used))%"
        }
        let used = metric.displayUsed
        let limit = metric.displayLimit
        if let reset = metric.resetDate {
            return "\(used) / \(limit) · resets \(reset.formatted(.relative(presentation: .named)))"
        }
        return "\(used) / \(limit)"
    }
}

public struct SecondaryChip: View {
    public let metric: UsageMetric
    public var body: some View {
        Text("\(metric.label) \(Int(metric.percent * 100))%")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
    }
}
