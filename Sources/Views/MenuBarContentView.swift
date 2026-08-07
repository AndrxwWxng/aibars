import SwiftUI
import AppKit

public struct MenuBarContentView: View {
    @ObservedObject public var state: AppState
    @ObservedObject public var appearance: AppearanceSettings
    @Binding public var showSettings: Bool

    /// The panel is built by `MenuBarExtra`, which hands its content no
    /// environment worth relying on, and by the layout tests, which build it
    /// with no scene at all — so appearance is a stored dependency with the
    /// shared instance as its default rather than an `@EnvironmentObject`.
    @MainActor
    public init(state: AppState, showSettings: Binding<Bool>) {
        self.init(state: state, showSettings: showSettings, appearance: .shared)
    }

    public init(state: AppState, showSettings: Binding<Bool>, appearance: AppearanceSettings) {
        self._state = ObservedObject(wrappedValue: state)
        self._appearance = ObservedObject(wrappedValue: appearance)
        self._showSettings = showSettings
    }

    private typealias PanelSection = AppearanceSettings.PanelSection

    /// Which collapsible blocks the user has opened, keyed by section id. Kept
    /// per id rather than as one flag so regrouping doesn't hand the "not
    /// connected" disclosure's state to whatever block takes its place.
    @State private var expandedSections: Set<String> = []

    /// As much of the screen as the panel can reasonably take, rather than a
    /// fixed 560pt that clipped the list on every display. Leaves room for the
    /// menu bar, the header, and a margin at the bottom.
    private var maximumListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(320, screen - 160)
    }

    public var body: some View {
        // Ordering, account collapsing, the quotaless and disconnected
        // policies, and grouping all happen in one pass inside
        // AppearanceSettings; the panel only draws what comes back.
        let sections = appearance.sections(from: state.rankedProviders, snapshots: state.snapshots)
        return VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if sections.isEmpty {
                emptyState
            } else {
                list(sections)
            }
        }
        .frame(width: CGFloat(appearance.panelWidth))
    }

    // MARK: - List

    private func list(_ sections: [PanelSection]) -> some View {
        ScrollView {
            VStack(spacing: appearance.metrics.rowGap) {
                ForEach(sections) { section in
                    block(
                        section,
                        isFirst: section.id == sections.first?.id,
                        isOnly: sections.count == 1
                    )
                }
            }
            .padding(.vertical, 6)
        }
        // The cap has to sit *under* `fixedSize`, not over it. `fixedSize`
        // measures its child against no proposal and then lays it out at that
        // ideal height whatever the parent offers, so a cap above it trimmed
        // only the height the panel *reported*: nine comfortable services put a
        // 1288pt scroll view in a 780pt window with its clip view the full
        // 1288pt, so there was no scroller and the 500pt past the cap were
        // drawn outside the panel where nothing could reach them. Underneath,
        // the ScrollView is handed the capped height and scrolls the rest.
        .frame(maxHeight: maximumListHeight)
        // `fixedSize` is what makes the panel a usable size at all.
        //
        // A ScrollView has no intrinsic height, and MenuBarExtra sizes its
        // window to whatever the content asks for — so this collapsed to zero
        // and the panel opened as a 51pt strip containing nothing but the
        // header. `maxHeight` caps a height, it never supplies one. Fixing the
        // vertical axis makes the ScrollView adopt its content's height, which
        // the cap then trims; past the cap it scrolls as before.
        //
        // Measuring the content and feeding the height back through a
        // preference also works, but only after a layout pass — so the window
        // opens short and visibly jumps.
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehaviorIfAvailable()
    }

    /// One block of rows and the header it sits under.
    ///
    /// `isOnly` matters because a lone collapsible block is the whole panel:
    /// folding it away would leave the header and nothing else, so it loses the
    /// disclosure and stays open. That is the case where every service is
    /// disconnected, which is also every user's first launch.
    @ViewBuilder
    private func block(_ section: PanelSection, isFirst: Bool, isOnly: Bool) -> some View {
        if let title = section.title {
            Group {
                if section.isCollapsible && !isOnly {
                    DisclosureHeader(
                        title: title,
                        count: section.providers.count,
                        isExpanded: expansion(of: section.id),
                        fontSize: sectionFontSize
                    )
                } else {
                    SectionLabel(title: title, count: section.providers.count, fontSize: sectionFontSize)
                        // Indented past the chevron a collapsible header
                        // carries. Grouping by usage band under the default
                        // disconnected policy puts both kinds in one list, and
                        // two title indents in one list reads as damage.
                        .padding(.leading, 12 + DisclosureHeader.chevronColumn(at: sectionFontSize))
                }
            }
            .padding(.top, isFirst ? 2 : 8)
        }

        if !section.isCollapsible || isOnly || expandedSections.contains(section.id) {
            ForEach(section.providers) { provider in
                row(for: provider)
            }
        }
    }

    /// Section headers stay at their own deliberate 9pt — they are a divider
    /// with a word on it, not content — but still follow the text scale.
    ///
    /// Upward only. The smallest text scale would take this to 7.6pt, and an
    /// uppercased, letter-spaced label at that size is a grey smear with a
    /// chevron-shaped smudge next to it.
    private var sectionFontSize: CGFloat {
        max(9, 9 * CGFloat(appearance.textScale))
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert(id)
                } else {
                    expandedSections.remove(id)
                }
            }
        )
    }

    private func row(for provider: AnyUsageProvider) -> some View {
        ProviderRow(
            provider: provider,
            result: state.snapshots[provider.id],
            onSignIn: { signIn(provider) },
            onOpenDashboard: { open(provider.dashboardURL) },
            onRefresh: { Task { await state.refresh(provider.id) } },
            appearance: appearance
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            UsageMeterGlyph(
                levels: state.usageLevels,
                alertColor: appearance.menuBarTint(for: state.topUsagePercent),
                alertThreshold: appearance.warningThreshold,
                height: 16
            )
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("AI Usage")
                    .font(.system(size: appearance.metrics.titleSize, weight: .semibold))
                if appearance.showsHeaderSummary {
                    Text(state.headlineSummary)
                        .font(.system(size: appearance.metrics.captionSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            // Refresh, settings and quit are never hideable: they are the only
            // way out of an app with no Dock icon and no window.
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .frame(width: 24, height: 24)
            } else {
                HoverIconButton(systemName: "arrow.clockwise", help: "Refresh all · \(updatedText) (⌘R)") {
                    Task { await state.refreshAll(userInitiated: true) }
                }
                .keyboardShortcut("r")
            }

            HoverIconButton(systemName: "gearshape", help: "Settings (⌘,)") {
                showSettings = true
            }
            .keyboardShortcut(",")

            HoverIconButton(systemName: "power", help: "Quit aibars (⌘Q)") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private var updatedText: String {
        guard let last = state.lastRefresh else { return "not refreshed" }
        let elapsed = Int(Date().timeIntervalSince(last))
        if elapsed < 10 { return "updated just now" }
        if elapsed < 60 { return "updated \(elapsed)s ago" }
        if elapsed < 3600 { return "updated \(elapsed / 60)m ago" }
        return "updated \(elapsed / 3600)h ago"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(hasEnabledServices ? "Nothing to show" : "No services enabled")
                .font(.system(size: appearance.metrics.titleSize, weight: .medium))
            // An empty panel with services enabled means the appearance filters
            // ate them — say so, or the user goes looking in Services for a row
            // that is switched on and hidden.
            Text(hasEnabledServices
                 ? "Your Appearance settings are hiding every service."
                 : "Turn one on in Settings → Services.")
                .font(.system(size: appearance.metrics.detailSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        // The longer message wraps once the panel is narrow or the text scale
        // is up, and a wrapped line with no inset runs edge to edge into the
        // window's rounded corners.
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }

    private var hasEnabledServices: Bool {
        !state.rankedProviders.isEmpty
    }

    // MARK: - Actions

    private func signIn(_ provider: AnyUsageProvider) {
        // Providers with a login page hand off to the browser; the rest still
        // need the token form in Settings.
        if provider.webLogin != nil {
            LoginWindowController.show(provider: provider) { success in
                if success { Task { await state.refresh(provider.id) } }
            }
        } else {
            showSettings = true
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A quiet group divider that folds the rows beneath it away.
struct DisclosureHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var fontSize: CGFloat = 9

    @State private var isHovered = false

    /// How far the chevron pushes the title in, so a section drawn without one
    /// can match rather than hang a chevron's width to the left of its
    /// neighbours.
    static func chevronColumn(at fontSize: CGFloat) -> CGFloat {
        fontSize + labelSpacing
    }

    private static let labelSpacing: CGFloat = 6

    var body: some View {
        Button {
            // Deliberately not animated. MenuBarExtra resizes its window to fit
            // the content, so animating the rows in means the window chases a
            // moving target — the panel jitters and the status item redraws
            // mid-flight.
            isExpanded.toggle()
        } label: {
            HStack(spacing: Self.labelSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: fontSize * 0.9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    // A fixed box, or the column `chevronColumn` promises is
                    // whatever width the glyph happened to render at.
                    .frame(width: fontSize)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                SectionLabel(title: title, count: count, fontSize: fontSize)
            }
            .padding(.vertical, 2)
            .padding(.leading, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isExpanded ? "Hide" : "Show \(count) more")
    }
}

/// A quiet group divider for the dropdown list.
struct SectionLabel: View {
    let title: String
    let count: Int
    var fontSize: CGFloat = 9

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Text("\(count)")
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
        .padding(.trailing, 12)
        .padding(.bottom, 2)
    }
}

/// A borderless icon button that reveals a rounded hover background, matching
/// the affordances in system menu bar panels.
struct HoverIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.09 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private extension View {
    /// `scrollBounceBehavior` is macOS 14+; the app targets 13.
    @ViewBuilder
    func scrollBounceBehaviorIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}
