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

    /// The two seeded parameters are for the tests and nothing else, and both
    /// default — so `PanelLayoutTests`, `PanelShellTests`, `PanelWidthContractTests`
    /// and `ZZPanelSnapshot` keep compiling untouched.
    ///
    /// `restingListHeight` in particular cannot be reached any other way: the real
    /// value is measured off a completed layout pass (see `RestingListHeight`), and
    /// a test measuring a panel with `fittingSize` gets one pass and no chance to
    /// feed the measurement back. Injecting it is what makes "a query that removes
    /// rows does not change the list box" an assertion rather than an eyeball.
    public init(
        state: AppState,
        showSettings: Binding<Bool>,
        appearance: AppearanceSettings,
        keyboard: PanelKeyboardState = .resting,
        restingListHeight: CGFloat? = nil
    ) {
        self._state = ObservedObject(wrappedValue: state)
        self._appearance = ObservedObject(wrappedValue: appearance)
        self._showSettings = showSettings
        self._keyboard = State(initialValue: keyboard)
        self._restingListHeight = State(initialValue: restingListHeight)
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
    /// A hairline is one device pixel, not one point: at 2x a 1pt rule is two
    /// rows of half-covered pixels, which reads as a soft grey band rather than
    /// a line. `Control.hairline` stays the system's own 1pt for the places that
    /// mean the system value; the panel's one rule opts out of it.
    @Environment(\.displayScale) private var displayScale

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

    /// The sentence the orientation slot opened with, or nil for a panel that had
    /// nothing to orient. Written only by `latchOrientation` and cleared only when
    /// the panel goes away.
    @State private var latchedOrientation: String?

    /// The query, whether the filter line is showing, and which row the keyboard
    /// is on — one struct rather than three flags, so `PanelKeyboard.reduce` can be
    /// handed the whole thing `inout` and checked without a view.
    @State private var keyboard: PanelKeyboardState

    /// How tall the list drew itself while nothing was being filtered.
    ///
    /// Measured, never computed. Adding up `RowGeometry.height` over the visible
    /// rows is the obvious implementation and it is wrong: a metered row draws
    /// about a point taller than the reservation and a row with `rowActions ==
    /// .never` runs three to five points the other way, which `PanelLayoutTests`
    /// states outright — "the first thing that lays a row out by it will clip a
    /// caption by a point". This must not be that thing.
    @State private var restingListHeight: CGFloat?

    /// The rows on screen, in drawn order, as ids.
    ///
    /// `@State` rather than a `body` local because the monitor's closure has to
    /// read it: a value computed in `body` and captured in `onAppear` is a snapshot
    /// of whenever `onAppear` last ran, and the arrow keys would then be navigating
    /// yesterday's list.
    @State private var drawnRowIDs: [String] = []

    /// A reference type in `@State`: created once per view identity, publishing
    /// nothing. That is right — nothing about it drives layout.
    @State private var monitor = PanelKeyMonitor()

    /// Room the panel leaves the screen: the menu bar above it, its own header,
    /// and a margin at the bottom so the last row isn't flush with the dock.
    private static let screenReserve: CGFloat = 160
    /// The list never asks for less than this even on a short display — below
    /// it the panel stops being a list and becomes a slot.
    private static let minimumListHeight: CGFloat = 320

    /// As much of the screen as the panel can reasonably take, rather than a
    /// fixed 560pt that clipped the list on every display.
    ///
    /// Handed a height rather than reading a screen, so the cap is a statement
    /// that can be checked: a 887pt visible frame — a 14-inch display with the
    /// menu bar and the Dock already taken off it — answers 887 − 160 = 727, and
    /// the floor only comes into it under 480. `PanelLayoutTests` used to work
    /// the same bound out from `NSScreen.main` in its own arithmetic, which on a
    /// two-display machine is a test and a view reading two different screens;
    /// both call this now.
    static func availableListHeight(forScreenHeight height: CGFloat) -> CGFloat {
        max(minimumListHeight, height - screenReserve)
    }

    /// The display the panel is opening on: the one under the pointer.
    ///
    /// Not `NSScreen.main`, which is the screen holding the key window — an app
    /// with no Dock icon and no window of its own does not reliably hold one, and
    /// the status item exists on *every* display's bar
    /// (`MenuBarAppearance.statusBarWindows`), so the panel can open on a screen
    /// the key window is not on. The pointer is over the item that was just
    /// clicked, by definition, which makes it the one input that names the right
    /// display. On a laptop beside a taller external the cap taken from the wrong
    /// screen is larger than the screen the panel is on, so the `ScrollView` is
    /// handed a height it can satisfy whole, never scrolls, and draws the rows
    /// past the screen edge where nothing can reach them.
    ///
    /// Read on every `body` rather than observed: it can only matter at the
    /// moment the panel is built, and `MenuBarExtra` rebuilds its content each
    /// time it opens.
    static var panelScreenHeight: CGFloat {
        let pointer = NSEvent.mouseLocation
        let host = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        return host?.visibleFrame.height ?? 800
    }

    private var maximumListHeight: CGFloat {
        Self.availableListHeight(forScreenHeight: Self.panelScreenHeight)
    }

    public var body: some View {
        // Ordering, account collapsing, the quotaless and disconnected
        // policies, and grouping all happen in one pass inside
        // AppearanceSettings; the panel only draws what comes back.
        let all = appearance.sections(from: state.rankedProviders, snapshots: state.snapshots)
        // And then the query, which narrows what is drawn without touching what
        // was arranged. `all` is what the expansion bookkeeping below reads; the
        // outcome is what the list draws. Keeping the two apart is not tidiness —
        // see the note on `adoptExpansion`.
        let outcome = PanelFilter.apply(
            query: keyboard.isFiltering ? keyboard.query : "",
            to: all,
            all: state.providers,
            snapshots: state.snapshots
        )
        return VStack(spacing: 0) {
            header(firstRow: all.first?.providers.first, matchCount: outcome.rows.count)
            headerRule

            if all.isEmpty {
                emptyState
            } else {
                if let latchedOrientation { orientation(latchedOrientation) }
                list(outcome)
            }
        }
        .frame(width: CGFloat(appearance.panelWidth))
        // Outermost, and the only material in the app. Every fill above it is a
        // `Color.primary` opacity — which is what lets one base carry the whole
        // ladder, and is also why the base has to be a value rather than
        // whatever wallpaper happens to be behind the window.
        .background { ground }
        // Zero-sized, hit-testing nothing, and the only way this view learns which
        // window it is in. See `PanelKeyMonitor`.
        .background(
            PanelWindowProbe { window in
                guard let window else { monitor.detach(); return }
                monitor.attach(to: window)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
        // Expansion follows the shape of the list, so it can only move when the
        // list's own structure does — never when a percentage changes, and never
        // when a query does.
        .onAppear { adoptExpansion(of: all) }
        .onChange(of: shape(of: all)) { _ in adoptExpansion(of: all) }
        // And the orientation slot is decided once per opening. The panel already
        // trusts `onAppear` for expansion, so the latch is seeded from the same
        // hook; `onChange` is the upward half and `onDisappear` ends the
        // presentation. See `latchOrientation`.
        .onAppear { latchOrientation() }
        .onChange(of: hasNothingConnected) { _ in latchOrientation() }
        // No loop: `reconcile` moves `selection`, which changes one card's fill
        // and never the key below.
        //
        // Keyed on the query as well as the ids, and the query is the half that is
        // easy to leave out. A keystroke clears the selection because the rows are
        // about to move under it — but a refinement that narrows *nothing*, "cod"
        // to "code" over the same three rows, moves no id at all. Watching the ids
        // alone, the handler would not run, the selection would stay cleared, and
        // Return would do nothing for the rest of the query.
        .onChange(of: PanelRows(ids: outcome.rows.map(\.id), query: keyboard.query)) { rows in
            drawnRowIDs = rows.ids
            PanelKeyboard.reconcile(&keyboard, rows: rows.ids)
        }
        .onAppear {
            drawnRowIDs = outcome.rows.map(\.id)
            wireKeyboard()
        }
        .onDisappear {
            monitor.detach()
            latchedOrientation = nil
            // Without this, `MenuBarExtra` keeping its content view alive between
            // openings means the next open shows yesterday's query with yesterday's
            // rows filtered out — and the user has no idea why four services
            // vanished.
            keyboard = .resting
        }
    }

    /// Hand the monitor the reducer, and the reducer's answers back to the panel.
    ///
    /// The closure captures this view value, which is legitimate for exactly the
    /// properties it touches: a `@State` read or write goes through the shared
    /// storage box, so it always sees current state. It must therefore touch
    /// **only** `@State`, the monitor, and the two reference dependencies — never
    /// a `let` computed in `body`, which would be frozen at whenever `onAppear`
    /// last ran. `drawnRowIDs` exists for precisely that reason.
    ///
    /// Idempotent, because `MenuBarExtra` may or may not rebuild its content per
    /// opening and `onAppear` is the only hook either way.
    private func wireKeyboard() {
        monitor.onCommand = { command in
            var next = keyboard
            switch PanelKeyboard.reduce(command, into: &next, rows: drawnRowIDs) {
            case .ignored:
                return false
            case .handled:
                keyboard = next
            case .activate(let id):
                keyboard = next
                activate(id)
            case .close:
                keyboard = .resting
                monitor.dismissPanel()
            }
            return true
        }
        // The panel losing the keyboard is the panel being finished with, whether
        // it was closed or the user clicked away.
        monitor.onResignKey = { keyboard = .resting }
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
    /// that has the problem — its figure, its weight, its square-capped fill —
    /// and a coloured edge across the chrome names no service, so it cannot be
    /// acted on. It also put hue on the one element that stays on screen while
    /// the list is scrolled, which is to say it shouted for as long as a user
    /// left the panel open. One weight, one colour, one accessor, everywhere in
    /// the app.
    ///
    /// A `Rectangle` rather than a `Divider` because a `Divider` carries its own
    /// material and a second rule weight with it, and this app has one of each.
    ///
    /// One device pixel tall, which is what makes it land *on* the grid: every
    /// gap above it is a whole point, so at any scale the line starts on a pixel
    /// boundary and covers exactly one row of them. `BrowserLoginView` draws its
    /// rule the same way and says so.
    ///
    /// Through `Tokens.Control.hair(scale:)` rather than the `1 / displayScale`
    /// this used to spell out. Value-identical at every scale a display reports,
    /// so no pixel moves; what changes is that the token stops being a definition
    /// with no callers. Five rules, three spellings of two thicknesses: this and
    /// `BrowserLoginView`'s inline division, `AppearancePane`'s
    /// `hairline / max(scale, 1)`, and two more taking the whole point — while
    /// the function written to settle the question was never called once. Three
    /// of the five call it now, and the two that keep the point say why there.
    private var headerRule: some View {
        Rectangle()
            .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
            .frame(height: Tokens.Control.hair(scale: displayScale))
    }

    /// What `adoptExpansion` watches: which blocks exist and which of them carry
    /// a disclosure.
    private func shape(of sections: [PanelSection]) -> String {
        sections.map { "\($0.id):\($0.isCollapsible)" }.joined(separator: "|")
    }

    /// **Fed the unfiltered sections, always.** This is the single easiest thing
    /// to get wrong in the filter: hand it the filtered shape and a query that
    /// leaves one connected row makes the disconnected block "the only block",
    /// which marks it uncollapsible — and then clearing the filter force-expands
    /// nine rows the user had deliberately folded away, with no keystroke of
    /// theirs between the two states. `PanelFilter.apply` returns an empty
    /// `sections` while filtering partly so that this cannot be done by accident.
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

    private func list(_ outcome: PanelFilter.Outcome) -> some View {
        ScrollViewReader { proxy in
            list(outcome, scrolledBy: proxy)
        }
    }

    private func list(_ outcome: PanelFilter.Outcome, scrolledBy proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: appearance.metrics.rowGap) {
                if outcome.isFiltered {
                    // One flat block, no group headers, and the collapsed block
                    // opened. A filter has already answered "which rows", so a
                    // header reading `Not connected 9` over one matching row is
                    // furniture — and a chevron that hid a match would make the
                    // filter lie about what it found.
                    if outcome.rows.isEmpty {
                        noMatches(outcome.hint)
                    } else {
                        ForEach(outcome.rows) { provider in
                            row(for: provider)
                        }
                    }
                } else {
                    ForEach(outcome.sections) { section in
                        block(
                            section,
                            isFirst: section.id == outcome.sections.first?.id,
                            isOnly: outcome.sections.count == 1
                        )
                    }
                }
            }
            .padding(.vertical, Tokens.Space.listMargin)
            // Measured off the padded content stack rather than off the
            // `ScrollView`, and that is what makes it free of feedback: the
            // content's height is a function of the rows and the fixed panel
            // width, and of nothing the imposed frame below does.
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: RestingListHeight.self, value: geometry.size.height)
                }
            )
        }
        // Unanimated, on purpose, and for the reason `DisclosureHeader` writes
        // down: `MenuBarExtra` sizes its window to its content, so an animated
        // scroll is the window chasing a moving target while the status item
        // redraws mid-flight. `ForEach`'s own element identity is what this
        // resolves — do not add `.id(provider.id)` to the row, it would give the
        // row a second identity and break `ForEach` diffing.
        .onChange(of: keyboard.selection) { id in
            guard let id else { return }
            proxy.scrollTo(id, anchor: .center)
        }
        .onPreferenceChange(RestingListHeight.self) { measured in
            guard !keyboard.isFiltering, measured > 0 else { return }
            restingListHeight = measured
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
        //
        // Which is exactly why the latch below spends the measurement and never
        // supplies it at open: nothing is fed back on the way in. The panel still
        // opens on `fixedSize`, at the height it always did, and the measured
        // value is only ever read from the first keystroke — by which time it has
        // been taken across at least one complete layout pass.
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: latchedHeight, alignment: .top)
        .scrollBounceBehaviorIfAvailable()
    }

    /// How tall the list box is held while a query is being typed.
    ///
    /// nil is "no opinion" — `frame(width:height:alignment:)` uses the child's own
    /// dimension for a nil axis, so this modifier disappears when the panel is not
    /// filtering and the resting behaviour is byte-for-byte what it was.
    ///
    /// **The list box is latched at its resting height the moment filter mode
    /// opens, and held for as long as filtering lasts, and that is the whole
    /// height policy.** `MenuBarExtra` sizes its window to its content, so a list
    /// that resized on every keystroke would be a window resizing on every
    /// keystroke — worse than no filter at all, and the one thing this rollout has
    /// spent itself removing.
    ///
    /// Consequences, all of them intended:
    ///
    /// - A query that takes fifteen rows to one leaves fourteen rows of ground
    ///   below the result. That is the price and it is the right one: the
    ///   alternative moves every remaining row up the screen between two
    ///   keystrokes, under the eye that is reading them.
    /// - A list already past the cap was already pinned there, so filtering
    ///   changes nothing for it.
    /// - A refresh that adds a row *while* a filter is active cannot resize the
    ///   window either, because the latch was taken before it. That falls out for
    ///   free.
    /// - Clearing the filter releases the latch and the panel sizes to content
    ///   once, on a deliberate keystroke, which is exactly when a resize is
    ///   legible.
    private var latchedHeight: CGFloat? {
        guard keyboard.isFiltering, let resting = restingListHeight else { return nil }
        return min(resting, maximumListHeight)
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
    /// A group header is a label on a block of rows, not reading matter, so the
    /// slider that sizes the numbers has nothing to say about it — and the
    /// special case it used to need (9 × 0.85 is 7.6, which is a grey smear) has
    /// nothing left to defend at a fixed size.
    ///
    /// `detail` rather than `caption`: the panel has two sizes and this is a
    /// caption, set at the same 11pt as every other caption in it. 10pt is now
    /// spent on exactly one line in the app — the pace sentence — and a header a
    /// point smaller than the countdown under it was a fifth size pretending to
    /// be a hierarchy.
    private var sectionFontSize: CGFloat {
        Tokens.Ramp.detail
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
            isRefreshing: state.refreshingRows.contains(provider.id),
            appearance: appearance,
            isSelected: keyboard.selection == provider.id
        )
    }

    // MARK: - Header

    private func header(firstRow: AnyUsageProvider?, matchCount: Int) -> some View {
        // Longest first, and the header draws the longest one that fits rather
        // than cutting the tail off the only line it was handed.
        let summaries = headerSummaries(firstRow: firstRow)
        return PanelHeader(
            appearance: appearance,
            levels: state.usageLevels,
            topPercent: state.topUsagePercent,
            summary: summaries.first,
            alternates: Array(summaries.dropFirst()),
            // The filter takes over the summary's slot rather than adding a
            // control beside it. See `PanelHeader.summarySlot`.
            filter: keyboard.isFiltering ? keyboard.query : nil,
            matchCount: matchCount
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
                    .accessibilityLabel(HoverIconButton.inFlightName)
            } else {
                HoverIconButton(.refreshAll, help: "Refresh all · \(updatedText) (⌘R)") {
                    Task { await state.refreshAll(userInitiated: true) }
                }
                .keyboardShortcut("r")
            }

            // Straight onto the History pane rather than through
            // `showSettings`, which opens the window on whichever pane it was
            // last left on. A chart is the one thing in Settings the panel
            // routinely wants, and making the user find it under a gear is how
            // ninety days of readings stay unread.
            HoverIconButton(.history, help: "Usage history") {
                SettingsWindowController.show(state: state, pane: .history)
            }

            HoverIconButton(.settings, help: "Settings (⌘,)") {
                showSettings = true
            }
            .keyboardShortcut(",")

            HoverIconButton(.quit, help: "Quit aibars (⌘Q)") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// The line beside the title — what the panel most needs to say and how old
    /// the numbers beneath it are — and every shorter way of saying it.
    ///
    /// `updatedText` is the only answer this app has to "when was this from?",
    /// which in a poller reading undocumented endpoints on a backoff schedule is
    /// the second question every number raises — and it lived exclusively inside
    /// the refresh button's tooltip, where nobody hovers until they have already
    /// decided to distrust the reading.
    ///
    /// Three forms rather than one because a single string can only ever be cut:
    /// the header used to show "Claude is nearly capped…" with 21pt of empty line
    /// beside it, having spent the width on a `Spacer` before the summary was
    /// measured. It picks a whole sentence now, and the shortest of the three is
    /// short enough that no panel width can truncate it. `headlineSummary` is
    /// untouched — this is which sentence gets drawn, not what it says.
    private func headerSummaries(firstRow: AnyUsageProvider?) -> [String] {
        let summary = state.headlineSummary
        // Nothing has been fetched, so there is no age to report and the summary
        // is already saying so.
        guard state.lastRefresh != nil else { return [summary, shortSummary] }
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
            return [updatedText, shortSummary]
        }
        return ["\(summary) · \(updatedText)", summary, shortSummary]
    }

    /// The summary in fifteen characters or fewer: the last thing the header can
    /// say before it would have to start cutting a sentence in half.
    ///
    /// A closed set, in `headlineSummary`'s own order so the two cannot disagree
    /// about which fact matters most — the busiest service and its figure, else a
    /// count, else why there is no count. It carries no clause: at this width the
    /// pace, the failure count and the freshness are all things the rows beneath
    /// and the refresh tooltip already answer.
    private var shortSummary: String {
        if state.isAdopting { return "checking…" }
        let connected = state.rankedProviders.filter(\.isAuthenticated).count
        guard connected > 0 else {
            let locked = state.lockedAccounts.values.reduce(0, +)
            return locked > 0 ? "\(locked) locked" : "no services"
        }
        if SessionStore.shared.isAccessDenied { return "keychain denied" }
        if let name = state.topProviderName, let top = state.usageLevels.max() {
            return "\(name) \(Int((top * 100).rounded()))%"
        }
        return "\(connected) connected"
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
            // `Ink.muted`, not `.tertiary`. Tertiary is banned from the panel —
            // it is a fourth ink that resolves under 4.5:1 on both grounds, and
            // this mark is the largest thing on an otherwise empty window.
            Image(systemName: "square.dashed")
                .font(.system(size: Self.emptyMarkSize))
                .foregroundColor(Tokens.Ink.muted)
            // A name, so it takes the weight every name in the panel takes.
            // `emphasisWeight` is gone — it resolved to this same `.medium` under
            // a name that promised a step up, which is how the panel came to have
            // no weight contrast at all.
            Text(hasEnabledServices ? "Nothing to show" : "No services enabled")
                .font(.system(size: appearance.metrics.titleSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.body)
            // An empty panel with services enabled means the appearance filters
            // ate them — say so, or the user goes looking in Services for a row
            // that is switched on and hidden.
            Text(hasEnabledServices
                 ? "Your Appearance settings are hiding every service."
                 : "Turn one on in Settings → Services.")
                // Regular, said out loud rather than inherited: the panel has two
                // weights and every caption in it is this one.
                .font(.system(size: appearance.metrics.detailSize, weight: .regular))
                .foregroundColor(Tokens.Ink.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        // The longer message wraps once the panel is narrow or the text scale
        // is up, and a wrapped line with no inset runs edge to edge into the
        // window's rounded corners.
        .padding(.horizontal, Tokens.Space.huge)
        .padding(.vertical, Tokens.Space.huge)
    }

    /// What a query that matched nothing says.
    ///
    /// Drawn **inside** the latched box, as a branch of the list's own content
    /// stack rather than as a sibling of it, so the no-match state and the results
    /// state occupy the same box and switching between them cannot move anything.
    ///
    /// No `square.dashed` mark. `emptyState` earns its 22pt one because it is a
    /// window with nothing in it and no way forward; this is a transient state the
    /// user typed themselves and will type out of on the next keystroke, and a
    /// graphic that appears and disappears as you type is the panel flinching.
    ///
    /// Leading-aligned and top-padded rather than centred, because the box is now
    /// as tall as the whole resting list: a message centred in 400pt of ground
    /// would sit halfway down the window with no relationship to the line the user
    /// is typing on.
    private func noMatches(_ hint: String?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.small) {
            // `lineLimit(1)` and no `fixedSize`: the query is user text on a
            // fixed-width panel, and the 32-character cap plus tail truncation is
            // what keeps this inside `PanelWidthContract`.
            Text("No service matches “\(keyboard.query)”")
                .font(.system(size: appearance.metrics.titleSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.body)
                .lineLimit(1)
                .truncationMode(.tail)
            // Same voice and the same two destinations as `emptyState`'s copy.
            // Without the hint, a user with `hidesQuotalessServices` on types
            // "copilot", gets nothing, and concludes the filter is broken rather
            // than that a setting is doing its job.
            Text(hint ?? "Escape clears the filter.")
                .font(.system(size: appearance.metrics.detailSize, weight: .regular))
                .foregroundColor(Tokens.Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, appearance.metrics.rowHorizontalPadding)
        .padding(.top, Tokens.Space.large)
    }

    private var hasEnabledServices: Bool {
        !state.rankedProviders.isEmpty
    }

    private var hasNothingConnected: Bool {
        !state.rankedProviders.contains(where: \.isAuthenticated)
    }

    /// How many browser sessions were found and could not be read.
    private var lockedSessionCount: Int {
        state.lockedAccounts.values.reduce(0, +)
    }

    /// Decide the orientation slot, once, for the length of one opening.
    ///
    /// The slot used to be `if hasNothingConnected`, read live. That value flips
    /// as the launch sweep lands, and the slot is two wrapped lines plus 6pt of
    /// padding above the list — `MenuBarExtra` sizes its window to its content,
    /// so the window moved by exactly that under the pointer. Measured at the
    /// shipped 356pt panel, cozy, 100% type: 948pt with the sentence against
    /// 914pt without it, a **34pt** jump. It is the one resize left in a panel
    /// where every other part reserves space to avoid exactly this.
    ///
    /// Latched rather than reserved: holding the sentence's height open with
    /// `.hidden()` would spend those 34pt on every connected panel forever, for a
    /// line only a first launch ever reads.
    ///
    /// Self-correcting upward and never downward. A last session expiring flips
    /// the value *to* true, and that sentence is worth growing the window once;
    /// the sweep landing flips it to false, and that is the flip this exists to
    /// swallow. A panel is short-lived, so "for the rest of this opening" is the
    /// right unit — `onDisappear` clears the latch and the next open asks again.
    ///
    /// The *wording* is latched with the presence, which is the half a boolean
    /// latch misses. `lockedAccounts` is filled by the census `adoptBrowserSessions`
    /// starts and never waits for, so `lockedSessionCount` goes 0 → n after the
    /// sweep and the slot swaps to the longer of the two sentences while
    /// `hasNothingConnected` stays true throughout: a different number of wrapped
    /// lines in the same slot, which is the same resize with the boolean standing
    /// still. The first open therefore says the general thing and the next one
    /// says "3 sessions were found but could not be read", which is the right way
    /// round — an instruction the user has to act on can wait one opening, and a
    /// sentence changing length under the pointer cannot be read at all.
    private func latchOrientation() {
        guard latchedOrientation == nil, hasNothingConnected else { return }
        latchedOrientation = orientationSentence
    }

    /// The one sentence a first launch gets.
    ///
    /// `emptyState` holds the panel's only other explanatory copy and it is
    /// unreachable on a genuine first launch: every service ships enabled, so
    /// the list is never empty, and what a new user actually sees is eleven rows
    /// that each say "connect" — which reads as eleven logins to go and find.
    /// This is the whole premise of the app, and it was written down nowhere the
    /// panel could show it.
    ///
    /// Two wordings, because there are two reasons a panel has nothing connected
    /// and they ask for opposite things. A locked Chromium session is not "you
    /// need not sign in again" — it is one instruction the user does have to
    /// follow, and until now the locked panel showed neither sentence. The slot
    /// was suppressed on the premise that the header says
    /// "n sessions found but locked — unlock a browser in Settings"; measured at
    /// the shipped 356pt that sentence wants 285pt against 161pt of header, so
    /// `ViewThatFits` correctly falls to the fifteen-character `3 locked` and the
    /// instruction reaches the screen nowhere at all. It goes here instead, in the
    /// slot that exists for exactly this — a panel of fifteen identical rows and
    /// no idea what to do about them.
    ///
    /// A string rather than a view, because which of the two it is has to be
    /// decided at the moment the slot is latched and then held.
    private var orientationSentence: String {
        lockedSessionCount > 0
            ? "\(lockedSessionCount) browser \(lockedSessionCount == 1 ? "session was" : "sessions were") found but could not be read. Unlock a browser in Settings."
            : "aibars reads the sessions already open in your browsers. You don't need to sign in again."
    }

    private func orientation(_ sentence: String) -> some View {
        Text(sentence)
            .font(.system(size: appearance.metrics.detailSize, weight: .regular))
            .foregroundColor(Tokens.Ink.muted)
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

    /// Return, on the selected row.
    ///
    /// A mirror of `ProviderRow`'s own Button action rather than a second opinion
    /// about what a row does, so pressing Return and clicking the row cannot
    /// diverge — a keyboard that opened a dashboard where a click would have
    /// started a sign-in would be two apps in one panel.
    ///
    /// It does not close the panel. Opening a URL deactivates the app, which
    /// dismisses the panel anyway, and `signIn` opens the login window over it.
    private func activate(_ id: String) {
        guard let provider = state.provider(for: id) else { return }
        provider.isAuthenticated ? open(provider.dashboardURL) : signIn(provider)
    }
}

/// What the keyboard has to be reconciled against: the rows on screen, and the
/// query that chose them.
private struct PanelRows: Equatable {
    let ids: [String]
    let query: String
}

/// How tall the list drew itself, reported upward from the content stack.
///
/// `max` rather than last-wins because the content stack is one subtree and the
/// reduction should be the tallest thing that reported, not whichever the
/// traversal happened to finish on.
private struct RestingListHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    /// The status line beside the wordmark, drawn only while
    /// `showsHeaderSummary` is on. It used to sit under the title; it says the
    /// same thing on the same line now.
    public let summary: String?
    /// Shorter ways of saying `summary`, longest first. The header draws the
    /// longest one that fits its own line, so a full sentence is dropped for a
    /// shorter sentence rather than losing its tail to an ellipsis.
    public let alternates: [String]
    /// The query, when one is being typed, drawn in the summary's own slot.
    ///
    /// **There is no `TextField` and no fifth header button**, and the reasons are
    /// height, width and chrome in that order. A field that is always there costs
    /// a `lineBox` plus a gap at the top of a 300–500pt window, paid on every open
    /// by every user who never filters. A fifth `iconButton` takes the cluster
    /// from 94pt to 118pt of a 356pt line, which drops the summary's
    /// `ViewThatFits` to its fifteen-character form at the default width — a
    /// permanently worse header traded for a feature almost nobody clicks. And a
    /// SwiftUI `TextField` brings a bezel, the system focus ring and the system's
    /// own field font; `focusEffectDisabled()`, the only way to suppress the ring,
    /// is macOS 14, and this app targets 13.
    public let filter: String?
    /// How many rows the query matched. Drawn on the same rail `SectionLabel`
    /// gives its count, because it is the same kind of number in the same place.
    public let matchCount: Int

    private let trailing: Trailing

    public init(
        appearance: AppearanceSettings,
        levels: [Double] = [],
        topPercent: Double = 0,
        summary: String?,
        alternates: [String] = [],
        filter: String? = nil,
        matchCount: Int = 0,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self._appearance = ObservedObject(wrappedValue: appearance)
        self.levels = levels
        self.topPercent = topPercent
        self.summary = summary
        self.alternates = alternates
        self.filter = filter
        self.matchCount = matchCount
        self.trailing = trailing()
    }

    public var body: some View {
        // One line, not a title over a subtitle. A bold all-caps masthead with a
        // caption stacked under it is the dated treatment, and it also spent a
        // second line of the panel's height on something that is chrome rather
        // than a reading. Everything the header says now says it on one baseline.
        let column = PanelAxis.leadingColumn(for: appearance)
        return HStack(spacing: Tokens.Space.medium) {
            // The masthead is the header's leading column and its name, and it is
            // laid out as a row's leading column and its name: `column` is the
            // rows' own measurement and the gap after the mark is the rows' own
            // gap, so the wordmark begins on the same x as every service name
            // below it whatever the logo settings are.
            HStack(spacing: Tokens.Space.leadingColumn) {
                if column > 0 {
                    // `Tokens.Control.headerGlyph`, not `menuBarGlyphHeight`: that
                    // setting exists because the menu bar's row height is the
                    // system's and the mark has to be tuned into it. A header sets
                    // its own height, so the setting does not apply here.
                    //
                    // Centred in the rows' box rather than laid against its
                    // leading edge, because a `ProviderLogo` centres its glyph
                    // inside its own box too (glyphSide is 0.76 of the box before
                    // the optical correction). Leading-aligned, the two boxes
                    // would share an edge and the two *inks* would sit about 2pt
                    // apart, which is the offset a reader can actually see.
                    //
                    // `Ink.body`, and there is no longer an app colour to prefer
                    // over it. The closed list Arc used to head — this mark, the
                    // About mark, a text link, the sign-in affordance, the connect
                    // dialog's buttons — is closed by deletion: the palette keeps
                    // two hues, amber and red, and both mean alarm, so identity is
                    // carried by the mark's silhouette, which is what a mark is
                    // for. `body` rather than `mark` because the header is where
                    // the app names itself rather than labels something, and it is
                    // the same rung the wordmark beside it takes — the two are one
                    // masthead and were being inked two ways.
                    AppMark(size: Tokens.Control.headerGlyph, tint: Tokens.Ink.body)
                        .frame(width: column - Tokens.Space.leadingColumn, alignment: .center)
                }

                // A wordmark, so it takes `Ramp.title` rather than the panel's
                // scaled `titleSize`: the text-scale slider sizes the reading
                // matter, and a masthead that grows with it starts competing with
                // the figures it is a label for. Set at the same size and weight
                // as a service name, because it is the same kind of thing — a name.
                Text(Wordmark.text)
                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                    .foregroundColor(Tokens.Ink.body)
                    // A wrapped title grows the header, which pushes the rule and
                    // every row below it down and makes the window resize to follow.
                    .lineLimit(1)
                    // Measured, never squeezed. The name is the header; it is two
                    // words shorter than anything else on the line and there is no
                    // width at which shortening it to "aiba…" is the right answer.
                    .fixedSize()
            }

            summarySlot

            // One cluster, tight enough to read as a set rather than as four
            // unrelated controls scattered along the edge. Fixed, so a long
            // sentence can never squeeze a control's hit area.
            HStack(spacing: Tokens.Space.tight) {
                trailing
            }
            .fixedSize()
        }
        // The rows' own padding, which is the outer half of the same alignment
        // `column` makes above: the padding puts the mark's box on the rows' mark
        // axis and the column puts the wordmark on the rows' name axis. Between
        // them the header takes both of its axes from the rows' own measurement,
        // so neither can drift when `logoSize`, `logoStyle` or `meterStyle`
        // moves — which is the whole of the repair. It used to hand-roll the
        // second axis as a 14pt mark and a `Space.medium`, and the two were
        // measured against a mark that has since narrowed to 15pt: at the shipped
        // gutter the wordmark stood at 12 + 15 + 8 = 35 while a row's name stood
        // at 12 + 18 + 10 = 40, and at a 40pt logo the gap was 27pt. The pair
        // agreed at no logo size at all.
        .padding(.horizontal, appearance.metrics.rowHorizontalPadding)
        // A point asymmetric: the rule beneath reads as the header's own bottom
        // edge rather than as the list's top one, so the gap down to it is the
        // smaller of the two.
        .padding(.top, Tokens.Space.headerTop)
        .padding(.bottom, Tokens.Space.headerBottom)
    }

    /// The one flexible slot on the header's line, held at exactly one line box.
    ///
    /// **The fixed box is what makes the whole filter safe.** Without it the slot
    /// is as tall as whichever of a `Text` and an `Image`-plus-`Rectangle` is
    /// taller, so it would grow by about a point the instant the user starts
    /// typing — which is `MenuBarExtra` resizing the window on the first
    /// keystroke. `Tokens.lineBox` is documented as existing for exactly this
    /// ("a `ProgressView`, a status dot and a percentage are each taller than the
    /// text beside them"); the header had the same latent problem and this closes
    /// it.
    ///
    /// The filter line is drawn **regardless of `showsHeaderSummary`**: that
    /// setting governs the summary, not the filter, and a user who turned the
    /// summary off has not asked to be typing blind.
    @ViewBuilder
    private var summarySlot: some View {
        Group {
            if let filter {
                FilterLine(query: filter, matchCount: matchCount, appearance: appearance)
            } else if appearance.showsHeaderSummary, !candidates.isEmpty {
                // The line's only flexible element, which is the fix: the
                // `Spacer` that used to sit here took its width at priority 0,
                // before a summary at priority −1 was measured at all, so the
                // sentence was cut 22pt early with the empty space sitting
                // beside it. Nothing between the summary and the buttons now —
                // the summary's own frame is the gap.
                ViewThatFits(in: .horizontal) {
                    summaryText(at: 0)
                    summaryText(at: 1)
                    summaryText(at: 2)
                }
            } else {
                // What the `Spacer` did: with no summary there is nothing
                // flexible left to push the cluster onto the panel's right edge.
                Color.clear.frame(minWidth: Tokens.Space.medium)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Tokens.lineBox(appearance.metrics.detailSize))
    }

    /// The lines the header may draw, longest first.
    ///
    /// Padded to three by repeating the last rather than assembled with `if`,
    /// because every child of `ViewThatFits` counts as a candidate and a branch
    /// that produces nothing produces an `EmptyView` — which fits any width, so
    /// a narrow panel would answer with a blank line instead of a short one.
    private var candidates: [String] {
        let all = ([summary].compactMap { $0 } + alternates).filter { !$0.isEmpty }
        guard let last = all.last else { return [] }
        return all + Array(repeating: last, count: max(0, 3 - all.count))
    }

    /// One candidate, or the shortest one if the caller asks past the end.
    ///
    /// SF Pro with tabular digits, not SF Mono: "updated 12s ago" is a run with
    /// words in it, and the mono face is reserved for runs that are only digits
    /// and separators. The tabular figures still matter, because the age does move
    /// — but not on a clock. Nothing republishes this on a timer: `updatedText`
    /// reads `Date()` during body evaluation, and the only things that re-render
    /// the panel are `AppState`'s published properties, which move on a refresh.
    /// Open the panel five seconds after a sweep and it reads "updated 5s ago" for
    /// a full minute and then jumps to "updated 1m ago". The clause claiming a
    /// per-second count described a timer that has never existed, and it is
    /// corrected here rather than left because the filter takes over this slot:
    /// the filter line re-renders because `keyboard` is `@State` on the panel, and
    /// that is the only reason it does.
    ///
    /// The tooltip is the whole of the filter's discoverability. No banner, no
    /// hint line, no first-run coach mark — a hint that costs a line of the panel
    /// to teach a feature that costs nothing to discover by accident is the wrong
    /// trade, and the summary is exactly the surface the affordance takes over.
    private func summaryText(at index: Int) -> some View {
        let lines = candidates
        let line = lines.indices.contains(index) ? lines[index] : (lines.last ?? "")
        return Text(line)
            .font(.system(
                size: appearance.metrics.detailSize,
                weight: .regular
            ).monospacedDigit())
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
            // Reached only by the last candidate, and only if the panel is
            // narrower than fifteen characters of caption.
            .truncationMode(.tail)
            .help("Type to filter · ⌘F")
    }
}

/// The query, drawn in the slot the header summary already occupies.
///
/// Revealed by the first keystroke and gone again on Escape or a backspace past
/// the first character, so it costs nothing at all to a user who never filters —
/// which is the point of putting it here rather than in a permanent control.
///
/// **No `fixedSize()` anywhere in this view.** Every run is `lineLimit(1)` inside
/// the header's own padding, and that is what keeps it inside the panel-width
/// contract at 300pt with a 32-character query in it.
private struct FilterLine: View {
    let query: String
    let matchCount: Int
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        let metrics = appearance.metrics
        return HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.snug) {
            // A fixed 12pt column so the query starts on one x whatever the glyph
            // renders at — the same argument `DisclosureHeader.chevronColumn`
            // makes for its chevron.
            Image(systemName: "magnifyingglass")
                .font(.system(size: metrics.detailSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.muted)
                .frame(width: Tokens.Space.large, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) {
                    ProviderRow.controlBaseline($0, titleSize: metrics.detailSize)
                }

            // Empty is context and takes `Ink.muted` at `.regular`; a real query
            // is the answer and takes `Ink.body` at `titleWeight`, which is the
            // ramp's whole rule. `.head` truncation because the tail is what was
            // just typed, so the head is the part that may go.
            Text(query.isEmpty ? "Filter" : query)
                .font(.system(
                    size: metrics.detailSize,
                    weight: query.isEmpty ? .regular : Tokens.Ramp.titleWeight
                ))
                .foregroundColor(query.isEmpty ? Tokens.Ink.muted : Tokens.Ink.body)
                .lineLimit(1)
                .truncationMode(.head)

            // **It does not blink.** `Tokens.Motion` closes the list of five
            // animations in this app, and a caret at 0.5Hz would be a sixth
            // running continuously in a panel whose premise is stillness. It does
            // not need to: it is only ever on screen while a hand is on the
            // keyboard.
            Rectangle()
                .fill(Tokens.Ink.body)
                .frame(width: Tokens.Space.hairline, height: metrics.detailSize)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }

            Spacer(minLength: Tokens.Space.small)

            Text("\(matchCount)")
                .font(.system(
                    size: metrics.detailSize,
                    weight: .regular,
                    design: Tokens.Ramp.figureDesign
                ))
                .foregroundColor(Tokens.Ink.muted)
                .frame(width: Tokens.figureWidth(metrics.detailSize, digits: 2), alignment: .trailing)
        }
        // One element, not five: a magnifier, a word, a rule and a number read
        // back one after another is four announcements for one line of state.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filter")
        .accessibilityValue(query.isEmpty ? "empty" : query)
        .accessibilityHint("\(matchCount) matching \(matchCount == 1 ? "service" : "services")")
    }
}

/// The one leading column the panel has, taken from a row.
///
/// Outside `PanelHeader` for the same reason `Wordmark` is: that type is generic
/// over its trailing view, and `PanelAxis.leadingColumn(for:)` would then have to
/// be spelled with a placeholder at every call site including the tests'.
enum PanelAxis {
    /// The rows' leading column — whatever is in it, plus the gap to the text
    /// after it — for the settings the panel is being drawn with.
    ///
    /// `RowGeometry` and not arithmetic of its own. That is the point: the header
    /// held a private copy of this sum, the copy was written against a mark and a
    /// gap that have both since moved, and the two columns had drifted apart at
    /// every logo size. There is one arithmetic now and the header is a caller of
    /// it, so the header cannot be left behind by a change to the rows again.
    ///
    /// `lines: []` because the answer does not depend on them — `leadingWidth` is
    /// the logo, the dial and one gap, none of which is a line — and a header has
    /// no lines to declare. `ProviderRow` asks the same question the same way when
    /// it needs a text column without knowing its own lines yet.
    ///
    /// Zero has a meaning and it is honoured: with the logos hidden and the meter
    /// off the dial, a row draws no leading column at all, and a header mark
    /// standing in front of a list with no marks in it is the "indent in front of
    /// nothing" the row itself refuses.
    @MainActor
    static func leadingColumn(for appearance: AppearanceSettings) -> CGFloat {
        RowGeometry(
            metrics: appearance.metrics,
            showsPercentage: appearance.showsPercentage,
            meterStyle: appearance.meterStyle,
            logoStyle: appearance.logoStyle,
            logoSize: CGFloat(appearance.logoSize),
            panelWidth: CGFloat(appearance.panelWidth),
            rowActions: appearance.rowActions,
            lines: []
        ).leadingWidth
    }
}

/// The panel's masthead.
///
/// Outside `PanelHeader` because that type is generic over its trailing view and
/// Swift will not hold a static stored property inside a generic one.
private enum Wordmark {
    /// The app's name, lower case, at body size and body weight.
    ///
    /// It was `AI USAGE` — bold, all caps, letter-spaced — which is a masthead
    /// treatment, and a masthead is the loudest thing a panel can open with. The
    /// panel is a list of readings and its header is a label on that list; the
    /// name of the app is not the news. Nothing is tracked here any more either:
    /// SF has its optical tracking baked in, and the spacing that rescues an
    /// all-caps run is damage on a lower-case one.
    static let text = "aibars"
}

/// A quiet group divider that folds the rows beneath it away.
struct DisclosureHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var fontSize: CGFloat = Tokens.Ramp.detail

    @State private var isHovered = false

    /// How far the chevron pushes the title in, so a section drawn without one
    /// can match rather than hang a chevron's width to the left of its
    /// neighbours.
    static func chevronColumn(at fontSize: CGFloat) -> CGFloat {
        fontSize + labelSpacing
    }

    private static let labelSpacing: CGFloat = Tokens.Space.small

    /// Open or folded, as a word, because the only other place the state was
    /// written was the chevron's `rotationEffect` and a rotation is not spoken.
    ///
    /// An `accessibilityValue` and deliberately not a trait. `.isToggle` is the
    /// trait that means this and it is macOS 14, a version above the floor
    /// `project.yml` pins. `.isSelected` reads as "selected", which is the word
    /// `DesignSystem`'s sidebar rows already use for the chosen Settings pane —
    /// a folded group and a chosen pane would then sound identical. And
    /// `DisclosureGroup`, which would carry the trait for free, animates its
    /// content in: `MenuBarExtra` sizes its window to its content, so animating
    /// rows in makes the window chase a moving target, which is the thing the
    /// toggle below deletes on purpose.
    static func expansionValue(isExpanded: Bool) -> String {
        isExpanded ? "Expanded" : "Collapsed"
    }

    /// What pressing it would do, which is the other half of the same sentence.
    /// The counted form both ways round: the folded tooltip said "Show 3 more"
    /// and the open one said "Hide", one word naming neither the subject nor
    /// what it would leave behind.
    static func expansionHint(isExpanded: Bool, count: Int) -> String {
        isExpanded ? "Hides \(count) services" : "Shows \(count) services"
    }

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
                    // Two points under the label rather than a fraction of it: a
                    // chevron is a mark beside the word, not a letter in it, and
                    // at the label's own size it starts reading as punctuation.
                    // Semibold because a 9pt glyph in `Ink.muted` is the one
                    // mark in the panel thin enough to disappear at `.medium`.
                    .font(.system(size: fontSize - 2, weight: .semibold))
                    .foregroundColor(Tokens.Ink.muted)
                    // A fixed box, or the column `chevronColumn` promises is
                    // whatever width the glyph happened to render at.
                    .frame(width: fontSize)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // The one thing on this header that moves, and the only
                    // motion the panel allows here: the rows themselves appear
                    // and disappear without animation, for the reason on the
                    // toggle above. At the panel's one duration — a chevron
                    // turning on a different clock from the plate under it is two
                    // clocks in one gesture.
                    .animation(Tokens.Motion.hover, value:isExpanded)
                    // Out of the spoken name. A chevron is how the state is drawn
                    // and `accessibilityValue` is how it is said; leaving the
                    // symbol in the combined label puts "chevron.right" between
                    // the group's name and its count.
                    .accessibilityHidden(true)
                SectionLabel(title: title, count: count, fontSize: fontSize)
            }
            .padding(.leading, Tokens.Space.gutter)
            .contentShape(Rectangle())
        }
        // Held inside the gutter exactly as a row card is, so the plate and the
        // cards below it share one edge.
        .buttonStyle(ControlPlate(
            radius: Tokens.Radius.chip,
            inset: Tokens.Space.cardInset,
            isHovered: isHovered
        ))
        .onHover { isHovered = $0 }
        .animation(Tokens.Motion.hover, value:isHovered)
        .accessibilityValue(Self.expansionValue(isExpanded: isExpanded))
        .accessibilityHint(Self.expansionHint(isExpanded: isExpanded, count: count))
        .help(isExpanded ? "Hide \(count) services" : "Show \(count) more")
    }
}

/// A quiet group divider for the dropdown list, and the app's only definition of
/// what a group header looks like: `Ramp.detail`, sentence case, medium, muted,
/// untracked, and unscaled. `DisclosureHeader` draws this one rather than a second
/// copy of it, so a collapsible block and a whole one cannot disagree.
///
/// It was a rule with a word on it — uppercased, letter-spaced, its count in a
/// filled capsule, and a hairline running from the count to the panel's edge.
/// That is three pieces of furniture to say one word. A header is a word.
struct SectionLabel: View {
    let title: String
    let count: Int
    var fontSize: CGFloat = Tokens.Ramp.detail

    var body: some View {
        HStack(spacing: Tokens.Space.small) {
            // Sentence case, as it arrives. `.uppercased()` was doing two jobs
            // and both of them badly: it is locale-sensitive on a string that is
            // sometimes a service's own word, and an all-caps run needs tracking
            // to stay legible, which is the tracking this panel no longer has.
            // `titleWeight`: a group header is the name of a block, and it is the
            // one thing on this line that is a name — the count beside it is
            // regular, which is the whole of the contrast between them.
            Text(title)
                .font(.system(size: fontSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.muted)
                .lineLimit(1)
            // A run that is only digits, so it takes the mono face like every
            // other figure in the panel — a count set in SF Pro beside nine
            // percentages set in SF Mono is the one number that looks borrowed.
            //
            // And so it takes a rail, trailing-aligned like every other mono run
            // in the app: two digits, which is every count this panel can
            // produce. The capsule behind it is gone — a fill on a two-digit
            // number is chrome, and the number reads perfectly well as a number.
            Text("\(count)")
                .font(.system(
                    size: fontSize,
                    weight: .regular,
                    design: Tokens.Ramp.figureDesign
                ))
                .foregroundColor(Tokens.Ink.muted)
                .frame(width: Tokens.figureWidth(fontSize, digits: 2), alignment: .trailing)
            // What the deleted hairline used to do: hold the header open to the
            // panel's full width, so the hover plate a disclosure draws behind
            // this is a card's width rather than a word's.
            Spacer(minLength: 0)
        }
        .padding(.trailing, Tokens.Space.gutter)
        // The recipe both kinds of header are drawn by, held here rather than on
        // the disclosure: a collapsible block and a whole one have to be the same
        // height, and they were not while only one of them carried this.
        .padding(.vertical, Tokens.Space.snug)
        .padding(.bottom, Tokens.Space.tight)
    }
}

/// The header's cluster, as a closed list of what each control is called.
///
/// Refresh, history, settings and quit are never hideable — they are the only
/// way out of an app with no Dock icon and no window — and they are enumerated
/// here rather than written as four literals at the call site because "what it is
/// called" is exactly the thing that went missing: every one of them announced
/// its SF Symbol to VoiceOver. A case cannot be added without answering both
/// questions below, and `PanelA11yTests` walks `allCases`, so the list the header
/// builds from and the list under test are one list.
///
/// The symbol and the name only. One of the four interpolates the refresh age
/// into its tooltip and all four carry a closure, so the hint and the action stay
/// at the call site where they can be read beside what they do.
enum HeaderControl: CaseIterable {
    case refreshAll, history, settings, quit

    var systemName: String {
        switch self {
        case .refreshAll: return "arrow.clockwise"
        case .history:    return "chart.xyaxis.line"
        case .settings:   return "gearshape"
        case .quit:       return "power"
        }
    }

    /// What VoiceOver calls it. A noun where the control *is* the thing —
    /// "Settings", "Usage history" — and a verb where it acts on the whole panel,
    /// because "Refresh all" and "Quit aibars" are not places to arrive at.
    var name: String {
        switch self {
        case .refreshAll: return "Refresh all"
        case .history:    return "Usage history"
        case .settings:   return "Settings"
        case .quit:       return "Quit aibars"
        }
    }
}

/// A borderless icon button that reveals a rounded hover background, matching
/// the affordances in system menu bar panels.
struct HoverIconButton: View {
    let systemName: String
    /// What the button *is*, for VoiceOver.
    ///
    /// Required, and that is the fix rather than an implementation detail of it.
    /// The label used to be a bare `Image(systemName:)` and the only text on the
    /// button was `.help`, which sets the accessibility *hint* — the sentence
    /// about what clicking would do. A hint is not a name, so all six of these
    /// announced their SF Symbol: "arrow.clockwise", "gearshape", "power". A
    /// defaulted parameter would have closed the six that exist and left the
    /// seventh nameless, which is exactly how these six happened.
    let name: String
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

    /// What the spinner that stands in for one of these is called while a fetch
    /// is out.
    ///
    /// Written once because it is the same claim in two files: the header's
    /// cluster and a row's actions each replace a named button with a bare
    /// `ProgressView`, which announces as an unlabelled progress indicator — the
    /// one control in the panel that reports what the app is doing, saying
    /// nothing, for as long as the fetch takes.
    static let inFlightName = "Refreshing"

    init(
        systemName: String,
        name: String,
        help: String,
        size: CGFloat = Tokens.Control.iconButton,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.name = name
        self.help = help
        self.size = size
        self.action = action
    }

    /// One of the header's four, which carry their own symbol and name.
    init(
        _ control: HeaderControl,
        help: String,
        size: CGFloat = Tokens.Control.iconButton,
        action: @escaping () -> Void
    ) {
        self.init(
            systemName: control.systemName,
            name: control.name,
            help: help,
            size: size,
            action: action
        )
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Tokens.Control.iconGlyph, weight: Tokens.Ramp.titleWeight))
                .frame(width: size, height: size)
        }
        // The plate and the glyph's ink both come from here, because a press is
        // only reported to a `ButtonStyle`. `Ink.muted` at rest — the same ink as
        // every caption in the panel — stepping to `Ink.body` under the pointer:
        // the plate says "this is a control" and the ink says "this one", which is
        // the second channel hover was missing.
        .buttonStyle(ControlPlate(
            radius: Tokens.Radius.control,
            isHovered: isHovered,
            litInk: Tokens.Ink.body
        ))
        .onHover { isHovered = $0 }
        // The plate arrives rather than appearing. One of the five things in the
        // panel that animate, and at the same duration as a row card's own fill.
        .animation(Tokens.Motion.hover, value: isHovered)
        // Both channels, and in that order: the name says which control this is,
        // the hint says what pressing it would do. `.help` alone gave the second
        // and left the first to the symbol.
        .accessibilityLabel(name)
        .help(help)
    }
}

/// The panel's control plate: nothing at rest, a fill under the pointer, a
/// heavier fill while the pointer is down.
///
/// A `ButtonStyle` because that is the only place SwiftUI reports a press, and
/// both of the panel's own controls — the header cluster and a section's
/// disclosure — used to answer a click with nothing at all. The press is a fill
/// and only a fill: no scale, no shadow, no geometry, because a control that
/// moves under the pointer moves the thing being clicked.
private struct ControlPlate: ButtonStyle {
    let radius: CGFloat
    /// How far the plate is held inside its own bounds. A section header's plate
    /// stops at the card edge the rows below it share; an icon button's plate is
    /// the button.
    var inset: CGFloat = 0
    let isHovered: Bool
    /// What the label's ink becomes once the pointer is over or on it, or nil
    /// where the label already carries its own colours.
    var litInk: Color?

    func makeBody(configuration: Configuration) -> some View {
        let isLit = isHovered || configuration.isPressed
        return configuration.label
            .foregroundColor(litInk.map { isLit ? $0 : Tokens.Ink.muted })
            .background(
                Tokens.surface(radius)
                    .fill(Tokens.quiet(fill(isPressed: configuration.isPressed)))
                    .padding(.horizontal, inset)
            )
            // Down with the click, back on a fade. Only the press is timed here;
            // hover is animated by the button that owns the hover state.
            .animation(Tokens.Motion.press(configuration.isPressed), value: configuration.isPressed)
    }

    private func fill(isPressed: Bool) -> Double {
        if isPressed { return Tokens.Fill.pressed }
        return isHovered ? Tokens.Fill.controlHover : 0
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
