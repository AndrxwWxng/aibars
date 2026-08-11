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

    /// The panel is drawn over the desktop, so its ground is a material and the
    /// scrim over it has to know which appearance it is resolving against.
    @Environment(\.colorScheme) private var colorScheme
    /// A blur under an opaque scrim is cost nobody can see, so the material is
    /// dropped outright rather than merely covered.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The rules this file draws are hairlines, which are the first thing a
    /// low-contrast display loses.
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias PanelSection = AppearanceSettings.PanelSection

    /// Which collapsible blocks the user has opened, keyed by section id. Kept
    /// per id rather than as one flag so regrouping doesn't hand the "not
    /// connected" disclosure's state to whatever block takes its place.
    @State private var expandedSections: Set<String> = []

    /// Section ids currently drawn whole: no chevron, every row showing.
    ///
    /// Tracked because that is a state a block can *leave* under the user. The
    /// not-connected block is built uncollapsible while nothing is connected, so
    /// a first-time user opens the panel onto eleven visible rows — and the
    /// moment the launch sweep adopts two sessions the same block gains a
    /// chevron and folds itself, taking nine rows and a third of the window's
    /// height with it while they are being read. A block that was open when it
    /// gained its disclosure stays open; folding it by hand still sticks.
    @State private var uncollapsibleSections: Set<String> = []

    /// Room the panel leaves the screen: the menu bar above it, its own header,
    /// and a margin at the bottom so the last row isn't flush with the dock.
    private static let screenReserve: CGFloat = 160
    /// The list never asks for less than this even on a short display — below
    /// it the panel stops being a list and becomes a slot.
    private static let minimumListHeight: CGFloat = 320

    /// As much of the screen as the panel can reasonably take, rather than a
    /// fixed 560pt that clipped the list on every display.
    private var maximumListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(Self.minimumListHeight, screen - Self.screenReserve)
    }

    public var body: some View {
        // Ordering, account collapsing, the quotaless and disconnected
        // policies, and grouping all happen in one pass inside
        // AppearanceSettings; the panel only draws what comes back.
        let sections = appearance.sections(from: state.rankedProviders, snapshots: state.snapshots)
        return VStack(spacing: 0) {
            header(firstRow: sections.first?.providers.first)
            headerRule

            if sections.isEmpty {
                emptyState
            } else {
                if hasNothingConnected { orientation }
                list(sections)
            }
        }
        .frame(width: CGFloat(appearance.panelWidth))
        // Outermost, and the only material in the app. Every fill above it is a
        // `Color.primary` opacity — which is what lets one base carry the whole
        // ladder, and is also why the base has to be a value rather than
        // whatever wallpaper happens to be behind the window.
        .background { ground }
        // Expansion follows the shape of the list, so it can only move when the
        // list's own structure does — never when a percentage changes.
        .onAppear { adoptExpansion(of: sections) }
        .onChange(of: shape(of: sections)) { _ in adoptExpansion(of: sections) }
    }

    /// The panel's ground: one material, and an opaque-enough scrim over it.
    ///
    /// Nothing above this is ever a material. Stacked materials multiply blur
    /// cost and resolve to values that depend on what is behind the window,
    /// which is exactly what a value hierarchy cannot tolerate: the card steps
    /// above are worth about 13 and 23 L* points and the scrim holds the base's
    /// own wallpaper swing to about 11, so the ladder cannot invert on any
    /// desktop. Thinner and a white wallpaper flattens the base into the card
    /// sitting on it.
    private var ground: some View {
        ZStack {
            // Dropped rather than hidden under the opaque scrim: a blur nobody
            // can see is still a blur being drawn every frame.
            //
            // `.regularMaterial`, not a thinner one: the scrim's 0.88/0.92 are
            // derived against this material's own lift, and under a thinner one
            // the same alphas let more of the wallpaper through than the value
            // ladder above has room for.
            if !reduceTransparency {
                Rectangle().fill(.regularMaterial)
            }
            Rectangle().fill(
                Tokens.Surface.base.opacity(Tokens.scrimAlpha(
                    isDark: colorScheme == .dark,
                    reduceTransparency: reduceTransparency
                ))
            )
        }
    }

    /// The line under the header. Neutral at every usage level.
    ///
    /// It used to take the warning colour whenever anything was near its cap,
    /// and that is now deleted rather than tuned: the alarm belongs to the row
    /// that has the problem — its figure, its square-capped fill, its spine —
    /// and a coloured edge across the chrome names no service, so it cannot be
    /// acted on. It also put hue on the one element that stays on screen while
    /// the list is scrolled, which is to say it shouted for as long as a user
    /// left the panel open. One weight, one colour, one accessor, everywhere in
    /// the app.
    ///
    /// A `Rectangle` rather than a `Divider` because a `Divider` carries its own
    /// material and a second rule weight with it, and this app has one of each.
    private var headerRule: some View {
        Rectangle()
            .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
            .frame(height: Tokens.Control.hairline)
    }

    /// What `adoptExpansion` watches: which blocks exist and which of them carry
    /// a disclosure.
    private func shape(of sections: [PanelSection]) -> String {
        sections.map { "\($0.id):\($0.isCollapsible)" }.joined(separator: "|")
    }

    private func adoptExpansion(of sections: [PanelSection]) {
        // A lone block loses its disclosure whatever it asked for, so it counts
        // as drawn whole here too — the same rule `block(_:isFirst:isOnly:)`
        // draws by.
        let isOnly = sections.count == 1
        for section in sections
        where section.isCollapsible && !isOnly && uncollapsibleSections.contains(section.id) {
            expandedSections.insert(section.id)
        }
        uncollapsibleSections = Set(sections.filter { !$0.isCollapsible || isOnly }.map(\.id))
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
            .padding(.vertical, Tokens.Space.listMargin)
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
                        .padding(.leading, Tokens.Space.gutter
                                 + DisclosureHeader.chevronColumn(at: sectionFontSize))
                }
            }
            // A group that opens the list needs no air above it; one that
            // follows a block of rows is a break between two things.
            .padding(.top, isFirst ? Tokens.Space.tight : Tokens.Space.medium)
        }

        if !section.isCollapsible || isOnly || expandedSections.contains(section.id) {
            ForEach(section.providers) { provider in
                row(for: provider)
            }
        }
    }

    /// Group headers no longer follow the panel's text scale.
    ///
    /// A group header is a divider with a word on it, not reading matter, so the
    /// slider that sizes the numbers has nothing to say about it — and the
    /// special case it used to need (9 × 0.85 is 7.6, which is a grey smear) has
    /// nothing left to defend at a fixed 10.
    private var sectionFontSize: CGFloat {
        Tokens.Ramp.caption
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

    /// One row, handed the one `AppearanceSettings` every other row is handed.
    ///
    /// That is the whole of the rail contract, and it is structural rather than a
    /// promise: a row's figure rails come out of `RowGeometry`, which is a pure
    /// function of these settings — so every rail in the window is the same width
    /// and ends on the same trailing edge, including on rows with no figure, rows
    /// still loading and rows that never report a percentage at all. A row that
    /// worked its rail out from its own content would break that, which is why
    /// content is not an input to `RowGeometry`. The panel cannot hand a whole
    /// geometry down — its height needs the row's own lines, which is the one
    /// part of it the row alone knows.
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

    private func header(firstRow: AnyUsageProvider?) -> some View {
        PanelHeader(
            appearance: appearance,
            levels: state.usageLevels,
            topPercent: state.topUsagePercent,
            summary: headerSubtitle(firstRow: firstRow)
        ) {
            // Refresh, history, settings and quit are never hideable: they are
            // the only way out of an app with no Dock icon and no window.
            //
            // The sweep counts as refreshing here: the panel a first-time user
            // opens ten seconds after install is mid-adoption, and a spun-down
            // refresh glyph over an empty list presents "nothing connected" as
            // a finished answer rather than a question still being asked.
            if state.isRefreshing || state.isAdopting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    // The button's own footprint, so the cluster doesn't shuffle
                    // sideways for the length of a refresh.
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            } else {
                HoverIconButton(systemName: "arrow.clockwise", help: "Refresh all · \(updatedText) (⌘R)") {
                    Task { await state.refreshAll(userInitiated: true) }
                }
                .keyboardShortcut("r")
            }

            // Straight onto the History pane rather than through
            // `showSettings`, which opens the window on whichever pane it was
            // last left on. A chart is the one thing in Settings the panel
            // routinely wants, and making the user find it under a gear is how
            // ninety days of readings stay unread.
            HoverIconButton(systemName: "chart.xyaxis.line", help: "Usage history") {
                SettingsWindowController.show(state: state, pane: .history)
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
    }

    /// The line under the title: what the panel most needs to say, and how old
    /// the numbers beneath it are.
    ///
    /// `updatedText` is the only answer this app has to "when was this from?",
    /// which in a poller reading undocumented endpoints on a backoff schedule is
    /// the second question every number raises — and it lived exclusively inside
    /// the refresh button's tooltip, where nobody hovers until they have already
    /// decided to distrust the reading.
    private func headerSubtitle(firstRow: AnyUsageProvider?) -> String {
        let summary = state.headlineSummary
        // Nothing has been fetched, so there is no age to report and the summary
        // is already saying so.
        guard state.lastRefresh != nil else { return summary }
        // The default sort is by urgency, which puts the busiest service in row
        // one — so "claude is nearly capped — 92%, caps in 40m" is the row
        // directly beneath the header, its meter and its pace line, read back in
        // smaller type. The pace is no exception: the row carries the same
        // projection in its long form. Freshness is the one thing no row can
        // say, so where the summary is a restatement it takes the slot outright
        // rather than being appended to a line that holds exactly one and
        // truncated off the end of it.
        if let name = state.topProviderName,
           firstRow?.displayName == name,
           summary.hasPrefix(name) {
            return updatedText
        }
        return "\(summary) · \(updatedText)"
    }

    private var updatedText: String {
        guard let last = state.lastRefresh else { return "not refreshed" }
        let elapsed = Int(Date().timeIntervalSince(last))
        if elapsed < 10 { return "updated just now" }
        if elapsed < 60 { return "updated \(elapsed)s ago" }
        if elapsed < 3600 { return "updated \(elapsed / 60)m ago" }
        return "updated \(elapsed / 3600)h ago"
    }

    /// A mark for the empty panel. Larger than any control and smaller than a
    /// logo, which is why it takes no size from `Tokens.Control` — nothing else
    /// in the app draws one.
    private static let emptyMarkSize: CGFloat = 22

    private var emptyState: some View {
        VStack(spacing: Tokens.Space.small) {
            Image(systemName: "square.dashed")
                .font(.system(size: Self.emptyMarkSize))
                .foregroundStyle(.tertiary)
            Text(hasEnabledServices ? "Nothing to show" : "No services enabled")
                .font(.system(size: appearance.metrics.titleSize, weight: Tokens.Ramp.emphasisWeight))
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
        .padding(.horizontal, Tokens.Space.huge)
        .padding(.vertical, Tokens.Space.huge)
    }

    private var hasEnabledServices: Bool {
        !state.rankedProviders.isEmpty
    }

    private var hasNothingConnected: Bool {
        // Locked sessions are excluded deliberately. The header already says
        // "n sessions found but locked — unlock a browser in Settings", and
        // telling someone in larger type directly beneath it that they need not
        // sign in again contradicts the one instruction they do have to follow.
        !state.rankedProviders.contains(where: \.isAuthenticated)
            && state.lockedAccounts.isEmpty
    }

    /// The one sentence a first launch gets.
    ///
    /// `emptyState` holds the panel's only other explanatory copy and it is
    /// unreachable on a genuine first launch: every service ships enabled, so
    /// the list is never empty, and what a new user actually sees is eleven rows
    /// that each say "connect" — which reads as eleven logins to go and find.
    /// This is the whole premise of the app, and it was written down nowhere the
    /// panel could show it.
    private var orientation: some View {
        Text("aibars reads the sessions already open in your browsers. You don't need to sign in again.")
            .font(.system(size: appearance.metrics.detailSize))
            .foregroundStyle(.secondary)
            // The sentence wraps at any panel width, and a wrapped Text inside a
            // stack whose height is being fixed from below gets truncated to one
            // line unless it is allowed to state its own.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Tokens.Space.gutter)
            .padding(.top, Tokens.Space.small)
    }

    // MARK: - Actions

    private func signIn(_ provider: AnyUsageProvider) {
        // Every connection method lives in that window now, including the
        // pasted-key ones — a MiniMax row used to have to send the user to
        // Settings to do something the window can do.
        LoginWindowController.show(provider: provider) { success in
            if success { Task { await state.refresh(provider.id) } }
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The panel's header: the app's mark, its name and its one-line summary, and
/// whatever the caller puts on the right.
///
/// Written to be shared with the Appearance pane's preview, which draws the same
/// header with plain images where the panel has buttons. It existed in both files
/// literal for literal with nothing linking the copies, and the copy in the pane
/// whose job is to show what the panel looks like was the one that went stale.
/// The pane still holds that copy and should take this one.
///
/// The mark here is identity and nothing else. It used to be a second instrument
/// — a four-bar meter of the same usage the rows underneath already draw — and
/// the strip in the menu bar carries that reading now, with a brand mark against
/// each figure so it names the service it belongs to. A header that repeats the
/// list in miniature is a header that changes height when a quota does.
public struct PanelHeader<Trailing: View>: View {
    @ObservedObject private var appearance: AppearanceSettings
    /// Per-service usage. Retained so callers written against the meter mark
    /// keep compiling; the header draws no instrument and reads nothing from it.
    public let levels: [Double]
    /// The worst percentage on the panel. Also retained, and now read by nothing
    /// at all: the alert state it used to colour the mark with went to the rule
    /// under the header, and the rule has since given it up too. Nothing in the
    /// chrome changes with a percentage — the row that has the problem carries
    /// the alarm, and a header whose paint moves with a reading is a header that
    /// eventually moves its height with one.
    public let topPercent: Double
    /// The line under the title, drawn only while `showsHeaderSummary` is on.
    public let summary: String?

    private let trailing: Trailing

    public init(
        appearance: AppearanceSettings,
        levels: [Double] = [],
        topPercent: Double = 0,
        summary: String?,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self._appearance = ObservedObject(wrappedValue: appearance)
        self.levels = levels
        self.topPercent = topPercent
        self.summary = summary
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Tokens.Space.medium) {
            // `Tokens.Control.headerGlyph`, not `menuBarGlyphHeight`: that
            // setting exists because the menu bar's row height is the system's
            // and the mark has to be tuned into it. A header sets its own
            // height, so the setting does not apply here — and the mark sits at
            // the gutter with no nudge of its own, which puts it on the same
            // left edge as every logo in the list below.
            //
            // Arc is the app's own colour and one of the three saturated things
            // the panel allows: this mark, the provider logos, and the usage
            // ramp. It is never a surface, a meter or a row background.
            AppMark(size: Tokens.Control.headerGlyph, tint: Tokens.Ink.arc)

            VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                // A wordmark, so it takes `Ramp.title` rather than the panel's
                // scaled `titleSize`: the text-scale slider sizes the reading
                // matter, and a masthead that grows with it starts competing
                // with the figures it is a label for.
                Text(Wordmark.text)
                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                    .tracking(Wordmark.tracking)
                    // A wrapped title grows the header, which pushes the rule
                    // and every row below it down and makes the window resize to
                    // follow. The summary under it already holds one line; the
                    // title is the half of this pair that had no such promise.
                    .lineLimit(1)
                if appearance.showsHeaderSummary, let summary {
                    // SF Pro with tabular digits, not SF Mono: "updated 12s ago"
                    // is a run with words in it, and the mono face is reserved
                    // for runs that are only digits and separators. The tabular
                    // figures still matter — this line counts up every second
                    // the panel is open.
                    Text(summary)
                        .font(.system(size: appearance.metrics.captionSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Tokens.Space.small)

            // One cluster, tight enough to read as a set rather than as four
            // unrelated controls scattered along the edge.
            HStack(spacing: Tokens.Space.tight) {
                trailing
            }
        }
        .padding(.horizontal, Tokens.Space.gutter)
        // Asymmetric: the rule beneath reads as part of the bottom edge, so the
        // gap to it is smaller than the gap above the title.
        .padding(.top, Tokens.Space.headerTop)
        .padding(.bottom, Tokens.Space.headerBottom)
    }

}

/// The panel's masthead.
///
/// Outside `PanelHeader` because that type is generic over its trailing view and
/// Swift will not hold a static stored property inside a generic one.
private enum Wordmark {
    /// Uppercased in the literal rather than by `.uppercased()`: that transform
    /// is locale-sensitive and this is a name, not prose.
    static let text = "AI USAGE"
    /// Slightly less than a group header's 0.5. A masthead is read as one word
    /// at a glance and needs only enough air to stop the caps touching; a
    /// section label is scanned past and needs more.
    static let tracking: CGFloat = 0.4
}

/// A quiet group divider that folds the rows beneath it away.
struct DisclosureHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var fontSize: CGFloat = Tokens.Ramp.caption

    @State private var isHovered = false

    /// How far the chevron pushes the title in, so a section drawn without one
    /// can match rather than hang a chevron's width to the left of its
    /// neighbours.
    static func chevronColumn(at fontSize: CGFloat) -> CGFloat {
        fontSize + labelSpacing
    }

    private static let labelSpacing: CGFloat = Tokens.Space.small

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
                    // Semibold, not bold: the panel runs on three weights and
                    // this is the only mark that had reached for a fourth.
                    .font(.system(size: fontSize * 0.9, weight: Tokens.Ramp.titleWeight))
                    .foregroundStyle(.tertiary)
                    // A fixed box, or the column `chevronColumn` promises is
                    // whatever width the glyph happened to render at.
                    .frame(width: fontSize)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                SectionLabel(title: title, count: count, fontSize: fontSize)
            }
            .padding(.vertical, Tokens.Space.tight)
            .padding(.leading, Tokens.Space.gutter)
            .contentShape(Rectangle())
            .background(
                Tokens.surface(Tokens.Radius.chip)
                    .fill(Tokens.quiet(isHovered ? Tokens.Fill.controlHover : 0))
                    // Held inside the gutter exactly as a row card is, so the
                    // plate and the cards below it share one edge.
                    .padding(.horizontal, Tokens.Space.cardInset)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isExpanded ? "Hide" : "Show \(count) more")
    }
}

/// A quiet group divider for the dropdown list, and the app's only definition of
/// what a group header looks like: `Ramp.caption`, uppercased, tracked, semibold,
/// secondary, and unscaled. `DisclosureHeader` draws this one rather than a second
/// copy of it, so a collapsible block and a whole one cannot disagree.
struct SectionLabel: View {
    let title: String
    let count: Int
    var fontSize: CGFloat = Tokens.Ramp.caption

    /// The rule trailing the label is a hairline, and a hairline is the first
    /// thing a low-contrast display loses.
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Tokens.Space.small) {
            Text(title.uppercased())
                // Secondary, not tertiary: at a fixed 10pt with letter spacing on
                // it, tertiary is the weight at which an uppercased label stops
                // being read and becomes texture. It is a label on a group of
                // rows, and it has to survive being scanned past.
                .font(.system(size: fontSize, weight: Tokens.Ramp.titleWeight))
                .foregroundStyle(.secondary)
                .tracking(Tokens.sectionTracking)
            // A run that is only digits, so it takes the mono face like every
            // other figure in the panel — a count set in SF Pro beside nine
            // percentages set in SF Mono is the one number that looks borrowed.
            //
            // And so it takes a rail, because mono outside a reserved width is
            // what puts the jitter back: two digits, which is every count this
            // panel can produce. Centred rather than trailing-aligned — a lone
            // pill in a header is furniture, not a column being read down, and
            // the flexible rule after it absorbs the slack either way.
            Text("\(count)")
                .font(.system(
                    size: fontSize,
                    weight: Tokens.Ramp.emphasisWeight,
                    design: Tokens.Ramp.figureDesign
                ))
                .foregroundStyle(.secondary)
                .frame(minWidth: Tokens.figureWidth(fontSize, digits: 2), alignment: .center)
                .padding(.horizontal, Tokens.Space.snug)
                .padding(.vertical, Tokens.Space.hairline)
                .background(Capsule().fill(Tokens.quiet(Tokens.Fill.pill)))
            Rectangle()
                .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
                .frame(height: Tokens.Control.hairline)
        }
        .padding(.trailing, Tokens.Space.gutter)
        .padding(.bottom, Tokens.Space.tight)
    }
}

/// A borderless icon button that reveals a rounded hover background, matching
/// the affordances in system menu bar panels.
struct HoverIconButton: View {
    let systemName: String
    let help: String
    /// The whole button, hover plate included — not a frame wrapped around a
    /// larger one. A header button stands alone and takes the default; a button
    /// inside a row's title line shares that line with type and asks for
    /// `Tokens.Control.rowIconButton`. Wrapping the default in a 20x18 frame is
    /// what the rows used to do, and an inner fixed frame ignores the
    /// proposal — so two 24pt plates overlapped on a 20pt pitch and the refresh
    /// plate ran under the trailing percentage.
    var size: CGFloat = Tokens.Control.iconButton
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Tokens.Control.iconGlyph, weight: Tokens.Ramp.emphasisWeight))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(
                    Tokens.surface(Tokens.Radius.control)
                        .fill(Tokens.quiet(isHovered ? Tokens.Fill.controlHover : 0))
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
