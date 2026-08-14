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
    /// A fetch this row asked for is in flight, and the row still holds the
    /// reading it had. Drawn as the refresh glyph becoming a spinner inside the
    /// box that button already occupies — nothing moves, nothing is discarded and
    /// the row does not change height, which is what a refresh used to do to the
    /// whole panel: the reading was dropped first, the row collapsed to its
    /// loading height, and the window resized under the pointer.
    public let isRefreshing: Bool
    /// The row the keyboard is on: the one Return would act on.
    ///
    /// A fill and an accessibility trait, and nothing else. It is not an input to
    /// `RowGeometry` and must never become one — see the note on `geometry` — so a
    /// panel with a selection measures exactly the same as the same panel without
    /// one, and arrowing down a list cannot resize the window.
    public let isSelected: Bool

    /// The budgets, read plainly rather than observed — the reasoning
    /// `ForecastLine` writes down for the trend store applies unchanged here.
    /// Budgets are set in a settings window that cannot be open at the same time
    /// as the panel, and a budget arriving on its own between refreshes would
    /// grow the row under the pointer, which is the resize `RowActions` reserves
    /// its space to avoid.
    private let budgets: BudgetStore
    /// The samples the pace line is fitted from, read the same way and for the
    /// same reason, and handed on to the one view that states a projection.
    private let trend: UsageTrendStore
    /// The row's own last twenty-four hours, already bucketed. Read plainly and
    /// never observed, for the reason above and one more of its own: it is
    /// rebuilt by the same sweep that publishes the reading this row is drawn
    /// from, so the row is already being rebuilt whenever it has moved, and
    /// observing would let a trace arrive on its own between refreshes.
    private let sparklines: RowSparklineStore

    @State private var isHovered = false

    public init(
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?,
        onSignIn: @escaping () -> Void,
        onOpenDashboard: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        showsAllWindows: Bool? = nil,
        showsPlanName: Bool? = nil,
        isRefreshing: Bool = false,
        appearance: AppearanceSettings? = nil,
        // Ahead of the three stores rather than after them, so no existing call
        // site has to reorder an argument to gain a defaulted one.
        isSelected: Bool = false,
        budgets: BudgetStore? = nil,
        trend: UsageTrendStore? = nil,
        sparklines: RowSparklineStore? = nil
    ) {
        self.provider = provider
        self.result = result
        self.onSignIn = onSignIn
        self.onOpenDashboard = onOpenDashboard
        self.onRefresh = onRefresh
        self.showsAllWindows = showsAllWindows
        self.showsPlanName = showsPlanName
        self.isRefreshing = isRefreshing
        self.isSelected = isSelected
        // Resolved here rather than as default arguments: a default argument is
        // evaluated at the call site, and all four shared objects are
        // main-actor isolated, so that would constrain who is allowed to build
        // a row.
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
        self.budgets = budgets ?? BudgetStore.shared
        self.trend = trend ?? UsageTrendStore.shared
        self.sparklines = sparklines ?? RowSparklineStore.shared
    }

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }

    /// Every measurement this row makes.
    ///
    /// Built here rather than handed down, and that is the same statement: each
    /// input is a setting, so nine rows drawn under one `AppearanceSettings`
    /// reach the same rails by construction. No reading, no plan name and no
    /// fetch state is an input, which is what makes "the panel hands the same
    /// figure column to a row with a percentage, a row still loading and a row
    /// that will never have one" structural rather than a promise between call
    /// sites. Only `height` varies row by row, and only `cardRadius` reads it.
    ///
    /// Internal rather than private, and the one reason is that it has to be
    /// assertable. Nothing in the app frames a row to this number, so a
    /// reservation that disagreed with the drawing sat there for two releases
    /// with every test in the suite green; `RowReservationTests` reads it here so
    /// the reservation is checked against the same states the drawing is.
    ///
    /// `isSelected` is absent from this list for the same reason `result` is, and
    /// it must stay absent. A selection changes one card's fill and nothing else,
    /// so it cannot change a row's height — the moment it could, arrowing down a
    /// filtered list would resize the window under the reader's eye, which is the
    /// resize this whole model exists to forbid.
    var geometry: RowGeometry { rowGeometry(lines: lines) }

    /// The same measurements at a stated set of lines.
    ///
    /// It exists for one caller, `chipLimit`, and for one reason: how many chips
    /// fit is a question about `textColumnWidth`, which is the panel minus its
    /// gutters minus the leading column and is not a function of the lines at all
    /// — but the answer decides whether the caption line has any content, which
    /// decides which lines the row has. Asking `geometry` from inside `lines` is
    /// that circle, and it ends in a stack overflow rather than a wrong number.
    /// Naming an explicit set breaks it, and nothing read through this path is
    /// line-dependent.
    private func rowGeometry(lines: RowGeometry.Lines) -> RowGeometry {
        RowGeometry(
            metrics: metrics,
            showsPercentage: appearance.showsPercentage,
            meterStyle: appearance.meterStyle,
            logoStyle: appearance.logoStyle,
            logoSize: CGFloat(appearance.logoSize),
            panelWidth: CGFloat(appearance.panelWidth),
            // The buttons are reserved space on the title line, so whether the
            // user has them switched off is a measurement and not a drawing
            // detail: reserved height has to equal drawn height under every
            // setting, or the panel holds two points per row it never uses.
            rowActions: appearance.rowActions,
            // The further-window ladder, from the settings. Handed in here and
            // not only to `geometry`, because `rowGeometry(lines:)` is the one
            // place a row is measured and a second route that skipped it would be
            // a second answer about the row's height.
            secondaryLines: secondaryLines,
            lines: lines
        )
    }

    /// How many further-window lines this row holds open, under the one style
    /// that spends height on them.
    ///
    /// **The stepper, never `data.secondary.count`.** That is the whole of this
    /// property and it is the second half of the fix `RowGeometry.secondaryLines`
    /// exists for: under `.expanded` the row drew one line per window the fetch
    /// happened to return, so a service answering with three of them grew its row
    /// by 3 × (contentSpacing + lineBox(detailSize)) — 60pt at cozy/100% — the
    /// moment the answer landed, and `MenuBarExtra`, which sizes its window to its
    /// content, moved the panel under the pointer. The **Dashboard** preset ships
    /// `.expanded` with a limit of six, so this was default-on for anyone who
    /// chose it.
    ///
    /// Reserving the ceiling rather than the count is the trade, argued in full
    /// at `RowGeometry.init`. What it costs is a service that reports one window
    /// under a limit of six holding five empty lines, and what makes that
    /// affordable is that the stepper is the remedy and it is the control the user
    /// already has: under `.expanded` it now means exactly "how many
    /// further-window lines every row makes room for". The panel's list is inside
    /// a `ScrollView` capped at `maximumListHeight`, so a deep ladder lengthens a
    /// scroll rather than a window — which is the one direction this is allowed
    /// to be wrong in.
    ///
    /// The same opening bit as `lines`, and it has to be the same bit. A row
    /// nobody has connected draws nothing at all under its title, so a ladder
    /// reserved under it would be fifteen empty ladders on a first run — and the
    /// bit flips at most once per row per launch, which is what keeps this a
    /// reservation rather than a reading.
    private var secondaryLines: Int {
        guard provider.isAuthenticated || result != nil else { return 0 }
        guard appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .expanded else { return 0 }
        return appearance.secondaryWindowLimit
    }

    /// Which of the three optional lines this row draws. Presence only — never
    /// what they say.
    ///
    /// The pace caption is deliberately never claimed, for the reason
    /// `drawsDetail` gives: answering would mean running the fit a second time
    /// per row. It costs nothing here either, because the one thing this feeds is
    /// `cardRadius`, and a row carrying a pace caption is three lines tall — the
    /// radius has saturated at `Radius.row` long before that. The corners only
    /// need protecting on the short row, which is the row with no forecast.
    ///
    /// A row's height is a function of the settings and of one bit: does this row
    /// hold a reading at all. Not which error, not how many digits, not whether a
    /// spinner is turning — and the bit flips at most once per row per launch.
    ///
    /// So a row that has anything to report reserves its meter slot in every
    /// state it can be in, and one line under it whenever the settings put
    /// anything on that line, and the states that differ from a reporting row by
    /// less than a line — loading, failed — occupy the same box with different
    /// words in it. A row nobody has connected is the one short row: its rail
    /// says `Sign in` and there is nothing under its name to draw.
    ///
    /// It asked the *result* two questions until this pass and both were wrong.
    /// It asked whether the caption had content, which is true of a reading and
    /// false of the same row a second earlier, so a Minimal row was 15pt shorter
    /// the moment its first reading landed and the whole panel shrank around it.
    /// And it read `isAuthenticated` alone, so a session expiring while the panel
    /// was open collapsed the row by its whole detail block and threw away the
    /// one sentence written for that state. `result != nil` is what keeps the box
    /// a row has already earned; `reservesWindowLine` is what stops the box
    /// depending on what came back in it.
    private var lines: RowGeometry.Lines {
        // A never-connected row has no snapshot, so first-run is fifteen short
        // rows exactly as before; a row that has reported keeps its box when its
        // session dies under it.
        guard provider.isAuthenticated || result != nil else { return [] }
        // Reserved for every row that has something to report, under the setting,
        // in every state that row can be in: reporting, loading, failed,
        // quotaless. It is a setting and one bit — has this row anything to say —
        // and neither of those flips while the panel is open, which is the whole
        // contract. Whether the trace has a single hour in it is not asked, here
        // or anywhere: a slot that appeared when the first hour landed would grow
        // the row a day after the service was connected.
        var lines: RowGeometry.Lines = appearance.showsRowSparkline ? [.meter, .sparkline] : [.meter]
        if reservesWindowLine { lines.insert(.window) }
        if reservesBudgetLine { lines.insert(.budget) }
        return lines
    }

    /// Whether this row holds a budget block open, asked of the budget the user
    /// set and of nothing the network said.
    ///
    /// The same shape as `reservesWindowLine` one property down, and it exists
    /// for the same reason: the reservation and the drawing must read one
    /// predicate, or they differ by a block and the row resizes on a fetch with
    /// the reservation then lying about it. That is not hypothetical here — it is
    /// what shipped. `detailContent` drew `BudgetMeter` on `budgetLine(for:) !=
    /// nil`, which asks `BudgetPolicy` to compare `data.spend` against the
    /// budget, and `data.spend` is whatever the last fetch carried. So a budgeted
    /// row grew 22 / 26 / 30pt at compact / cozy / comfortable when its first
    /// reading landed. The full argument, and why folding is not available to
    /// this block the way it was to the pace, is at `RowGeometry.Lines.budget`.
    ///
    /// A budget is a setting: it is written in a settings window that cannot be
    /// open at the same time as the panel, which is the same reason `budgets` is
    /// read plainly rather than observed. So this cannot flip while a row is on
    /// screen, which is the whole contract.
    ///
    /// Keyed on `serviceID` and not on the row, exactly as `budgetLine` is: two
    /// Claude accounts are one subscription to the person paying, so they reserve
    /// alike and neither of them is measured against the other's spend.
    private var reservesBudgetLine: Bool {
        budgets.budget(for: provider.serviceID) != nil
    }

    /// Whether this row keeps a line under its meter, asked of the settings and
    /// of nothing else.
    ///
    /// The single predicate behind four decisions — this reservation, what
    /// `UsageBar` draws, what the ring branch draws, and `drawsDetail`'s
    /// alignment — because the failure mode is not any one of them being wrong.
    /// It is two of them disagreeing: the reservation and the drawing diverged by
    /// exactly one `lineBox` and the row resized on a fetch, with the reservation
    /// then lying about it.
    ///
    /// Every term is a setting, so the answer cannot change while a row is on
    /// screen. What that costs is stated rather than hidden: under Minimal, where
    /// amounts, countdowns and the further windows are all off, the line is not
    /// reserved and therefore not drawn in *any* state — a row still checking
    /// puts its spinner in the figure rail and a row that failed puts a triangle
    /// there, and the sentence each of them would have written lives in the row's
    /// tooltip. That is the preset's whole premise, a name and a number, held to
    /// in every state rather than only once a reading lands.
    private var reservesWindowLine: Bool {
        appearance.showsAmounts
            || appearance.showsCountdowns
            || appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .chips
    }

    /// Connected, asked, and nothing back yet.
    private var isLoading: Bool { provider.isAuthenticated && result == nil }

    /// Connected and answering: the one state in which the brand mark is allowed
    /// to carry the brand's own hue. It carries it at `Ink.mark`'s own lightness,
    /// so going live moves the hue and not the weight — within 0.35:1 of the
    /// neutral on every ground in the app. Loading, an error, an expired session
    /// and a locked one all draw it muted, which is the leading column's share of
    /// "this row is not reporting right now".
    private var isLive: Bool {
        guard provider.isAuthenticated, case .success = result else { return false }
        return true
    }

    /// Reporting a state rather than a quota — ChatGPT's and Copilot's case.
    /// There is no figure for the rail and no track for the slot, so the rail
    /// carries the one non-text proof of connection a row like this has.
    private var isStatusOnly: Bool {
        guard case .success(let data) = result else { return false }
        return data.primary.limit <= 0
    }

    /// A credential the user has to go and fix, as opposed to a request that
    /// simply failed. The two ask for different things and the row says so
    /// differently: this one puts the word `Sign in` in the figure rail, the
    /// other a warning triangle in the same slot.
    private var needsUser: Bool { failure?.isAuth == true }

    public var body: some View {
        // A row is a button in every state it can be in — it opens a usage page
        // or it starts a sign-in — so it is written as one rather than as a
        // rectangle with a tap gesture on it. That is where the pressed state
        // comes from: a 66pt target that lights up on hover and then says nothing
        // at all when it is clicked is the clearest "side project" tell the panel
        // had. The buttons inside the row keep their own hits, exactly as they did
        // under the tap gesture — the row's handler sits at the row's level, and
        // the innermost control wins.
        Button {
            provider.isAuthenticated ? onOpenDashboard() : onSignIn()
        } label: {
            content
        }
        .buttonStyle(
            RowButtonStyle(
                radius: geometry.cardRadius,
                style: appearance.rowBackground,
                isHovered: isHovered,
                isSelected: isSelected
            )
        )
        .onHover { isHovered = $0 }
        // The second channel, and the one that is actually missing today from
        // every selectable thing in the app that is not a `SelectableChip`: the
        // fill is a drawing and a drawing is not spoken. The same line
        // `SelectableChip` carries, for the same reason.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(rowHelp)
        // The panel is the only place a row can be dismissed from. A user who
        // subscribes to two of eleven services otherwise has to find Settings →
        // Services and switch nine of them off one at a time, and the row the
        // panel is shouting at them offers no way to say "not this one". Off the
        // provider's own flag, so it survives a relaunch and comes back from the
        // same list it would have been switched off in.
        .contextMenu {
            Button("Hide \(provider.displayName)") { provider.setEnabled(false) }
        }
    }

    // MARK: - The content

    /// Everything the row draws, inside its own padding. The card behind it
    /// belongs to `RowButtonStyle`, which is the only thing that knows whether the
    /// row is currently held down.
    private var content: some View {
        // Top alignment lines the brand mark up with the name rather than with
        // the middle of the block under it — but a row with nothing under its
        // title is one 13pt line beside that mark, and top alignment leaves it
        // hanging from the ceiling of the row.
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failure: ProviderError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    /// A row is a button whichever state it is in, so it says what clicking it
    /// does — including the case where it does nothing. A connected service with
    /// no usage page of its own hovers like every other row and used to answer
    /// with an empty string, which reads as a tooltip that failed to load.
    ///
    /// It is also where the tenth of a percent the panel drops lives. No
    /// decimals anywhere in the panel: a tenth on a five-hour window is noise
    /// you cannot act on, and it costs two of the four characters the figure
    /// rail holds on every row. Here it is asked for rather than scanned past.
    ///
    /// And it is the one place a failure's raw text is allowed to surface. The
    /// row draws a sentence we wrote; what the server actually said — a truncated
    /// JSON body, a Cloudflare challenge id — is diagnostic rather than
    /// information, and it belongs where it is asked for rather than printed
    /// across two lines of a 356pt panel.
    ///
    /// The failure is answered before the credential and not after it, which is
    /// the fix for the one state where those two are true at once. A session that
    /// expires during a sweep clears `isAuthenticated` in the same main-actor
    /// turn that stores the failure, so the tooltip used to answer "Sign in to X"
    /// and drop "Session expired — sign in again" and its diagnostic on the
    /// floor. Both are kept and the action clause still says what clicking does.
    private var rowHelp: String {
        let action = provider.isAuthenticated
            ? (provider.dashboardURL != nil
               ? "Open \(provider.displayName) usage page"
               : "\(provider.displayName) has no usage page")
            : "Sign in to \(provider.displayName)"
        if let failure {
            return [failure.errorDescription, failure.diagnostic, action]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
        guard provider.isAuthenticated, let reading = preciseReading else { return action }
        return "\(reading)\n\(action)"
    }

    /// The headline window at the precision the row itself refuses to print.
    /// Formatted rather than interpolated, so the separator stays the reader's.
    private var preciseReading: String? {
        guard case .success(let data) = result, data.primary.limit > 0 else { return nil }
        let percent = data.primary.percent.formatted(.percent.precision(.fractionLength(1)))
        return "\(data.primary.label): \(percent) used"
    }

    // MARK: - Leading column

    /// False collapses the gap as well as the column — a 10pt indent in front
    /// of nothing reads as a broken layout, not as a text list.
    ///
    /// Read off the measurement rather than off the two settings behind it: the
    /// column is nonzero exactly when there is something in it, and asking the
    /// same question twice in two places is how the Appearance pane's preview
    /// came to disagree with the row it previews.
    private var hasLeading: Bool { geometry.leadingWidth > 0 }

    @ViewBuilder
    private var leading: some View {
        if hasLeading {
            HStack(spacing: Tokens.Space.leadingItems) {
                if appearance.logoStyle != .hidden {
                    mark
                }

                if appearance.meterStyle == .ring {
                    // The dial is this row's meter, and a meter slot has exactly
                    // two drawings: a track with a fill in it, or nothing. So the
                    // dial appears where there is a quota to draw and the column
                    // holds its width — never its ink — where there is not.
                    // Drawn at full strength on a row that is loading, failed or
                    // quotaless, an empty track reports "nothing is being used",
                    // which is a reading this row does not have.
                    if let percent = primaryPercent {
                        UsageRing(
                            percent: percent,
                            diameter: metrics.ringDiameter,
                            thickness: metrics.barHeight,
                            tint: tint(for: percent),
                            isNearCap: Self.isNearCap(
                                percent: percent,
                                warning: appearance.warningThreshold
                            )
                        )
                        // A dial is a shape and says nothing on its own, so it is
                        // made an element and given its reading.
                        .accessibilityElement()
                        .accessibilityLabel("Usage")
                        .accessibilityValue(ringValue)
                    } else {
                        // The column's width, and nothing in it: the text beside
                        // it must start at the same x on every row of the panel,
                        // whether or not a reading has arrived.
                        Color.clear
                            .frame(width: metrics.ringDiameter, height: metrics.ringDiameter)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// The brand mark, in the ink the row's state calls for.
    ///
    /// State is drawn in ink and never in opacity. A mark faded to 0.55 over the
    /// panel's ground put two of the paler marks under 2:1 — a first run is
    /// fifteen rows of "not reporting yet", so that was the whole panel below the
    /// floor a meaningful graphic needs. Muted at full strength is the ink the
    /// name and the caption take in the same state, which makes "this row is not
    /// telling me anything" one statement rather than three treatments.
    ///
    /// Handed down rather than resolved in the mark, because the row is the only
    /// thing that knows the state — and resolved off the settings rather than off
    /// a ternary here, because the other two inputs to the answer are the user's:
    /// the brand-colour switch and the colour ramp. `ProviderLogo.ink` has no
    /// default left to fall back on, so this row and the four surfaces outside the
    /// panel that draw a mark all have to state which state they are in, and all
    /// four reach the same function to turn that into a colour.
    private var mark: some View {
        ProviderLogo(
            providerID: provider.serviceID,
            fallbackName: provider.displayName,
            size: appearance.logoSize,
            showsTile: appearance.logoStyle == .tile,
            ink: appearance.markInk(for: provider.serviceID, isLive: isLive)
        )
    }

    // MARK: - Title

    /// The name, the account, the plan, the buttons and the figure, on one
    /// baseline.
    ///
    /// `.firstTextBaseline` rather than `.center`: the name and the figure are
    /// two sizes and two weights in one line box, and centring lands their cap
    /// heights on two baselines a point apart — exactly the kind of thing that
    /// reads as sloppy without being nameable. It was worse when the two were
    /// also two *faces*; one face has not made the alignment unnecessary, because
    /// a 13pt name and a 16pt figure still centre differently. Everything on the line that has no baseline of its
    /// own — the buttons, a rail glyph, the status dot — is put on the band the
    /// eye reads the line in by `controlBaseline`.
    ///
    /// One size and one weight for both now. The name was set a step heavier than
    /// everything else in the panel and the figure a step larger, which between
    /// them are what made the panel shout; hierarchy on this line is carried by
    /// the face, the reserved rail and the colour, none of which cost loudness.
    ///
    /// Held at `geometry.titleLineHeight`, which is the box `RowGeometry`
    /// reserved for it, so that *what is on the line* cannot reach the row's
    /// height. That was not true and the drawing is where it broke: the buttons
    /// are reserved off the `rowActions` setting and were drawn off
    /// `provider.isAuthenticated`, so a row that had reported and whose session
    /// then died lost 2pt at cozy/100% and 4pt at cozy/85% and compact/85% —
    /// measured on a hosted row — while still reserving them. `SessionStore`
    /// clears the credential in the same main-actor turn it stores the failure,
    /// so with the panel open that is the window resizing under the pointer, four
    /// rows at a time. The floor closes the whole class rather than that one
    /// case: the rail's five states, the buttons and the name are now all things
    /// this line contains rather than things it is measured by.
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.small) {
            Text(provider.displayName)
                // `titleWeight`, which is the name's own token and is what the
                // Appearance preview sets its sample name in. The two used to
                // reach for different tokens that happened to resolve to the
                // same weight, which is a divergence waiting for one of them to
                // move.
                .font(.system(size: metrics.titleSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(nameTint)
                .lineLimit(1)
                // The name is the one thing the row cannot be read without, so
                // it takes its width before the run that says which account.
                .layoutPriority(1)

            identity

            Spacer(minLength: Tokens.Space.medium)

            // Only an authenticated row has anything to refresh or open, so a
            // disconnected one gives the *width* back — the account run and the
            // name are what want it — and keeps the band.
            if provider.isAuthenticated {
                RowActions(
                    visibility: appearance.rowActions,
                    isHovered: isHovered,
                    hasDashboard: provider.dashboardURL != nil,
                    isRefreshing: isRefreshing,
                    refreshHelp: "Refresh \(provider.displayName)",
                    onRefresh: onRefresh,
                    onOpenDashboard: onOpenDashboard
                )
                .alignmentGuide(.firstTextBaseline, computeValue: controlBaseline)
            } else if appearance.rowActions != .never {
                // The band the buttons would have occupied, with no buttons in it
                // and no width taken. Zero-width rather than `rowIconButton`
                // wide, because reclaiming the horizontal space is right and was
                // never the defect; what was wrong is that the *vertical* space
                // went with it.
                //
                // A floor on the line is not enough to close this on its own, and
                // the reason is `controlBaseline`: the buttons hang from
                // `centre + 0.40 × titleSize` rather than from the text baseline,
                // so at large type they push the line about a point past the box
                // `Tokens.lineBox` reserves for it. A live row therefore drew
                // 59pt at compact/130% where a dead one drew 58 even with both
                // floored at 18. Standing the same 18pt box on the same guide is
                // what makes the two lines the same line — reserved or not,
                // whatever the type scale does to the arithmetic — because it is
                // the same measurement rather than a second one that agrees.
                Color.clear
                    .frame(width: 0, height: Tokens.Control.rowIconButton)
                    .alignmentGuide(.firstTextBaseline, computeValue: controlBaseline)
                    .accessibilityHidden(true)
            }

            trailingValue
        }
        // And the reservation as a floor under the whole line, which is the part
        // the stand-in above cannot reach: with `rowActions == .never` there is
        // no band to stand in, and the reservation still counts the figure's box
        // on a row whose rail is drawing the word `Sign in` instead. Two
        // mechanisms because there are two failures — one keeps the *band* the
        // same, this keeps the *box* no smaller than what was reserved — and the
        // second is the one that generalises: whatever the rail is asked to hold
        // next, the line cannot come out under its reservation.
        //
        // A floor and not a frame. A text line at 130% measures a fraction over
        // `lineBox`, and a row would rather be a point tall than clip a
        // descender: reserved > drawn is the one direction this is allowed to be
        // wrong in, and drawn > reserved is the resize.
        //
        // Centred, which is the default alignment and what the band wants. On a
        // live row the buttons are the tallest thing on the line and
        // `controlBaseline` — centre plus 0.40 of the title size — puts the name
        // about 3.4pt below the line's top at cozy/85%; centring a shorter line
        // in the same box puts it at 2.9pt. Half a point, against the 4pt of row
        // height this is buying back.
        .frame(minHeight: geometry.titleLineHeight)
    }

    /// Which account this row is, and on what plan: one muted run, joined by the
    /// panel's own middle dot.
    ///
    /// It was two things — a label and a filled pill — and at 300pt the pill
    /// squeezed to nothing and still drew its own padding and fill, so the row
    /// read `GitHub Copil…` followed by a bare grey blob, while the account label
    /// beside it was given zero width and vanished entirely. That is the wrong way
    /// round: which account this is, is the reason the line exists.
    ///
    /// So it is one run at one rank, and it gives way in whole steps rather than
    /// by the character: account and plan, then account alone, then nothing. A
    /// long service name simply takes the width, since it holds the priority.
    @ViewBuilder
    private var identity: some View {
        let parts = identityParts
        if !parts.isEmpty {
            ViewThatFits(in: .horizontal) {
                identityRun(parts.joined(separator: " · "))
                // The step that keeps the plan. A work address can be sixty
                // characters — `ada.lovelace.engineering@verylongcompanyname.example.com`
                // is a real shape — and dropping to "account alone" does not help,
                // because the account is the part that did not fit. Elided in the
                // string rather than left to `truncationMode`, so the candidate
                // has an ideal width `ViewThatFits` can actually measure: a view
                // that only truncates once it is squeezed reports its full width
                // when asked and is rejected whole.
                if parts.count > 1 {
                    identityRun(Self.elided(parts))
                }
                // The step that keeps the account and gives up the plan — and it
                // has to be the *elided* account, not the whole one.
                //
                // It was `identityRun(first)`. Whenever the account alone is what
                // did not fit, that candidate is wider than the elided pair above
                // it and can therefore never be chosen: `ViewThatFits` skips
                // straight to the empty last candidate and the row draws neither
                // the account nor the plan. Measured on a 60-character work
                // address at the shipped 356pt, `OpenRouter Enterprise Platform…`
                // lost both its account and "Enterprise Unlimited" and left 100pt
                // of empty line beside its name — the exact shape the doc two
                // candidates up names as the motivating case. Elided, the ladder
                // is monotone in width by construction, which is the property
                // `ViewThatFits` needs to walk it at all.
                if parts.count > 1, let first = parts.first {
                    identityRun(Self.elided([first]))
                }
                // The last candidate is the one `ViewThatFits` falls back on when
                // none of the others fit, so it has to be something that always
                // does: the run drops out whole, and the name keeps the line.
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    /// The parts of that run, in the order they give way: the account first,
    /// because it is the only one that tells two subscriptions to one service
    /// apart. Whichever the settings switch on compose it.
    private var identityParts: [String] {
        var parts: [String] = []
        if appearance.showsAccountLabels, let account = accountLabel { parts.append(account) }
        if showsPlan, let plan = planName { parts.append(plan) }
        return parts
    }

    /// The same run with the first part shortened from its middle.
    ///
    /// Only the first part is touched, because only the first part is unbounded:
    /// a plan name is a word the provider chose ("Max 20x", "Pay as you go") and
    /// an account label is whatever the user's employer put in front of an @.
    /// Middle, for the same reason `identityRun` truncates that way — two
    /// addresses at one company differ at the start and at the end, never in the
    /// middle.
    private static func elided(_ parts: [String]) -> String {
        guard let first = parts.first else { return "" }
        var head = first
        // Eighteen characters is where an address stops being a shape you
        // recognise and starts being an ellipsis with punctuation round it. Below
        // that the whole run gives way instead.
        let budget = 18
        if head.count > budget {
            let side = (budget - 1) / 2
            head = head.prefix(side) + "…" + head.suffix(side)
        }
        return ([head] + parts.dropFirst()).joined(separator: " · ")
    }

    private func identityRun(_ text: String) -> some View {
        Text(text)
            .font(.system(size: metrics.detailSize, weight: .regular))
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
            // Middle, not tail: the end of an address is the part that identifies
            // it — `ada@example.com` and `ada@work.example.com` differ at the end.
            .truncationMode(.middle)
    }

    /// Where a control with no text in it sits on the title line's baseline.
    ///
    /// A view SwiftUI can find no baseline in is aligned by its bottom edge, so a
    /// 20pt button block would stand its whole height above the name's baseline
    /// and drag the line taller than the box `RowGeometry` holds for it — a few
    /// points per row, nine rows deep, on a panel whose window is sized to its
    /// content. Its centre belongs on the band the eye reads the line in instead,
    /// a little above the baseline, which is what centring gave for free.
    ///
    /// Measured rather than derived: at this fraction the row comes out at exactly
    /// the height the centred line came out at, across all three densities and all
    /// four text scales. A cap-height derivation says 0.36 and leaves one point on
    /// the table at cozy, which is a point the panel would pay nine times.
    private func controlBaseline(_ dimensions: ViewDimensions) -> CGFloat {
        Self.controlBaseline(dimensions, titleSize: metrics.titleSize)
    }

    /// The same guide, reachable by the Appearance preview.
    ///
    /// Shared rather than restated: the preview drew its buttons with no guide
    /// at all, which left the sample row a point short of the row it claims to
    /// be showing at the one preset that turns the buttons on permanently. A
    /// guide the panel applies and the preview does not is the divergence the
    /// preview exists to make impossible.
    public static func controlBaseline(
        _ dimensions: ViewDimensions,
        titleSize: CGFloat
    ) -> CGFloat {
        dimensions[VerticalAlignment.center] + titleSize * controlBaselineDrop
    }

    private static let controlBaselineDrop: CGFloat = 0.40

    /// The name's ink, which is the row's own quietest state channel.
    ///
    /// Muted while a row has nothing to report — loading, failed, or not
    /// connected — and full body ink the moment it does.
    ///
    /// A failed row is muted too, and that is a correction. Two docs stated
    /// opposite rules for one state: `AppearanceSettings.markInk` — "not
    /// reporting, which is loading, failed, expired, locked or not connected, is
    /// `Ink.muted`" — drove the mark, and this drove the name, and the row drew
    /// both. Measured on the Grok row: a `Ink.muted` mark at 7.73:1 under an
    /// `Ink.body` name at 15.8:1, **28 L\* apart inside one row**, so a row that
    /// had *failed* read healthier than the row above it that was merely
    /// loading. One ink for the whole row is what `Ink.muted`'s own doc promises
    /// — "mark and name and caption together" — and the sentence on the line
    /// below is what carries the difference between failed and loading, in
    /// English, where a reader can act on it.
    private var nameTint: Color {
        isLoading || !provider.isAuthenticated || failure != nil
            ? Tokens.Ink.muted
            : Tokens.Ink.body
    }

    /// The figure rail — which is the row's state column, and answers "what is
    /// this row" in one of five ways: a figure, a connection dot, a warning
    /// triangle, the word `Sign in`, or nothing at all.
    ///
    /// This is the invariant the whole panel is squared against — tabular digits
    /// fix the width of a digit, not the length of a string, so "9%" still
    /// reflows to "92%" unless the column is reserved. Nothing shifts as
    /// readings arrive and drop out, and every reading in the panel ends at one
    /// x.
    ///
    /// It is where the row's state is drawn because it is the one place on the row
    /// nothing else competes for, and because putting it here leaves every detail
    /// line starting at the text column's own left edge. The glyphs it can hold
    /// are different widths, so they share one fixed square: measured,
    /// `exclamationmark.triangle.fill` at 11pt renders 14×13 and `lock.fill`
    /// 11×13, and a slot sized to whichever glyph is in hand moves the rail's edge
    /// by up to 3pt as the row changes state.
    @ViewBuilder
    private var trailingValue: some View {
        if !provider.isAuthenticated || needsUser {
            // One affordance for "this needs your credential", whether the
            // session was never there or has expired: the word for the action,
            // rather than a padlock the reader has to decode. It also takes the
            // last saturated amber off a first-run panel.
            signIn
        } else if failure != nil {
            // The request failed rather than the credential: shape, not colour.
            // Red belongs to the ramp — a red triangle on a row whose whole
            // premise is that red means near-cap says the wrong thing loudly.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: metrics.detailSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.muted)
                // Trailing inside the shared square, which is the rule the dot
                // two branches down already states and this branch was silent
                // about. It buys nothing today and that is worth saying: measured
                // before and after, the triangle's ink ends at 343.0 either way,
                // because `exclamationmark.triangle.fill` at 11pt renders 14pt
                // wide in a 14pt box and the remaining point is the symbol's own
                // side bearing, which no alignment can reach. What it buys is
                // that the rail's three glyph branches now all name the same
                // rule, so a symbol or a size that renders narrower cannot
                // quietly land 4pt inside the column the way the dot once did.
                .frame(width: Self.railGlyph, height: Self.railGlyph, alignment: .trailing)
                .frame(minWidth: geometry.headlineRail, alignment: .trailing)
                .alignmentGuide(.firstTextBaseline, computeValue: controlBaseline)
                .accessibilityLabel("Not reporting")
        } else if isStatusOnly {
            // The dot is doing real work: a service with no quota has no meter and
            // no figure to prove the connection is up, so the dot is the proof. In
            // the rail rather than in front of its own line, so no glyph ever
            // precedes text in the text column.
            //
            // It was green — `Ink.ok`, now deleted. Green is not in the palette's
            // vocabulary: two hues are left, amber and red, and both mean alarm.
            // What replaces the hue is a lit-versus-unlit pair against the
            // `Ink.muted` this same rail draws for a service that is not
            // reporting. `body` measures 10.66:1 light and 10.72:1 dark on the
            // worst plane in the panel, and stands 2.22:1 light / 2.23:1 dark
            // clear of `muted` — so the two states of this one dot are further
            // apart in weight than green and grey ever were in hue, and the
            // distinction survives a greyscale screenshot, which green did not.
            Circle()
                .fill(Tokens.Ink.body)
                .frame(width: Tokens.Control.dot, height: Tokens.Control.dot)
                // Trailing inside the shared square, not centred. The triangle
                // fills its 14pt box and the digits fill theirs, so both land on
                // the rail's own edge; a 6pt dot centred in the same box lands
                // 4pt inside it — measured at 340.0pt against 344.0pt for every
                // other thing the rail can hold, which is a visible step in the
                // one column the eye scans down.
                .frame(width: Self.railGlyph, height: Self.railGlyph, alignment: .trailing)
                .frame(minWidth: geometry.headlineRail, alignment: .trailing)
                .alignmentGuide(.firstTextBaseline, computeValue: controlBaseline)
                .accessibilityLabel("Connected")
        } else if appearance.showsUsageNumber, let percent = primaryFigure {
            UsageFigure(
                percent: percent,
                size: metrics.figureSize,
                unitSize: metrics.unitSize,
                // The weight channel of the near-cap contract. The only weight in
                // the app above `titleWeight`, so the change is unambiguous — and
                // it survives greyscale, which the tint below does not.
                weight: Self.figureWeight(percent: percent, warning: appearance.warningThreshold),
                // Neutral until the reading is worth a colour. A panel of nine
                // resting rows spends the eye's whole colour budget on the least
                // informative state it has if the digits are tinted too, and the
                // digits are the column being scanned — so colour arriving on a
                // number is itself the event. The bar beside it now agrees: its
                // resting stop is grey rather than a hue.
                tint: figureTint(for: percent),
                animatesDigits: true
            )
            .frame(width: geometry.headlineRail, alignment: .trailing)
        } else if isLoading, !reservesWindowLine {
            // The one state that has nowhere else to be drawn. With the window
            // line unreserved — Minimal, and any hand-made settings like it —
            // "Checking…" is not written under the title in any state, so a row
            // waiting on its first answer would otherwise be a service name and
            // an empty rail, which is what a row nobody has connected looks like.
            // The spinner goes in the same 14pt square the failure triangle takes,
            // for the same reason it does: the rail is the row's state column.
            ProgressView()
                .controlSize(.mini)
                .frame(width: Self.railGlyph, height: Self.railGlyph, alignment: .trailing)
                .frame(minWidth: geometry.headlineRail, alignment: .trailing)
                .alignmentGuide(.firstTextBaseline, computeValue: controlBaseline)
                .accessibilityLabel("Checking")
        } else {
            // Loading with a line under the title to say so, or the number
            // switched off. The rail stands empty rather than closing up: a row
            // that is still checking must end on the same x as the row above it
            // that already knows.
            Color.clear
                .frame(width: geometry.headlineRail, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// The invitation, in the rail, in the loudest neutral the panel has.
    ///
    /// It was `Ink.arc`, the app's own indigo, and that token is deleted: the
    /// palette keeps two hues, amber and red, and both mean alarm. Nothing is
    /// lost here, because hue was never what made this legible. It is the only
    /// *word* in a column of figures — every other thing the rail can hold is
    /// three digits, a 14pt triangle or a 6pt dot — so shape already carries it,
    /// and it is set at `Ramp.titleWeight` like a name rather than at a caption's
    /// weight. `body` is the rung for something being answered rather than
    /// labelled, and it is what the figures in the same rail take.
    ///
    /// Plain, not bordered. First launch is fifteen unconnected rows, and fifteen
    /// bordered buttons is a wall rather than a call to action; one word per row is
    /// an invitation. The whole row is already a sign-in target with a tooltip
    /// saying so, and this is the second way to reach it, not the only one.
    private var signIn: some View {
        Button(action: onSignIn) {
            Text("Sign in")
                .font(.system(size: metrics.detailSize, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.body)
                // The one control on a row with no reading, so it is the last
                // thing that should give: a crowded title line otherwise squeezes
                // it to "Si…".
                .fixedSize()
        }
        .buttonStyle(.plain)
        // The rail is a floor here rather than a width: a word is wider than
        // three digits, and this row has no reading to line up with anyway.
        .frame(minWidth: geometry.headlineRail, alignment: .trailing)
    }

    /// The square every glyph in the rail is drawn in, whichever glyph it is.
    private static let railGlyph: CGFloat = 14

    // MARK: - Body of the row

    /// Whether anything at all is drawn beneath the title line. Has to agree
    /// with `detailContent` below, since the row's vertical alignment turns on
    /// it — the two are kept next to each other for that reason.
    ///
    /// The pace line is the one piece of detail this does not ask about, and
    /// deliberately: answering would mean running the fit a second time per row
    /// to choose a vertical alignment, and the alignment it would choose is the
    /// one already chosen. Top alignment exists for a row with a block under its
    /// title; a row whose only detail is a single pace caption is two lines
    /// beside an 18pt mark, which is exactly the case centring is here for.
    ///
    /// Off the same two questions `lines` asks and in the same order, because the
    /// two must agree: this chooses the alignment for the block `lines` reserved
    /// the height of, and a row that reserved a detail block and then centred as
    /// though it had none put its mark half a line off the title it belongs to.
    private var drawsDetail: Bool {
        // Nothing under the title on a row nobody has connected and that has
        // never reported: the rail says `Sign in`, and that one line beside the
        // mark is exactly the case centring is here for. It is also why the row is
        // 38pt rather than 66 — vertical space in proportion to what the row has
        // to say.
        guard provider.isAuthenticated || result != nil else { return false }
        // The trace is a block under the title, so a row that draws one is top
        // aligned however empty the rest of its text column is. Under the ring
        // with amounts and countdowns off this is the only block there is, and
        // centring it against an 18pt mark would hang the name off the ceiling.
        if appearance.showsRowSparkline { return true }
        // Every style but the ring draws its meter in the text column, and that
        // slot is occupied on every row — a quota, a reading of zero, a service
        // that reports no quota at all, and a row still waiting each fill it with
        // something.
        guard appearance.meterStyle == .ring else { return true }
        // Under the ring the dial is the meter and the leading column has paid
        // for it, so the text column can genuinely be empty. What is left there is
        // the window line, which is exactly what `reservesWindowLine` answers —
        // the further-window ladder, which is a setting — and one
        // content-dependent extra that can only add to them.
        if reservesWindowLine { return true }
        // The ladder, asked of the settings and not of the payload. It read
        // `!data.secondary.isEmpty` until this pass, which was the drawing's own
        // half of the unreserved-ladder defect: the row centred its mark against
        // a single title line and then drew three windows under it the moment a
        // fetch came back with three. The slots are held open now, so the block
        // exists from the settings alone and the alignment follows it.
        if secondaryLines > 0 { return true }
        // The budget block, likewise. This asked the *result* — `guard case
        // .success(let data) = result else { return false }` and then
        // `budgetLine(for: data) != nil` — which was the drawing's half of the
        // unreserved-budget defect, in the same words as the ladder's: a budgeted
        // ring row with amounts and countdowns off centred its mark against one
        // title line and then grew a track and a figure under it when the spend
        // landed. It is a setting now, so the alignment follows the reservation.
        return reservesBudgetLine
    }

    @ViewBuilder
    private var detailContent: some View {
        if !provider.isAuthenticated, result == nil {
            // Nothing. The line that used to read "Not connected" said what the
            // rail beside it says in the word for the action, on a row that has no
            // reading to explain — fifteen of them on a first run, each paying a
            // reserved line and a reserved meter slot to repeat the one thing the
            // row already makes obvious.
            //
            // Both halves of the condition, not just the flag. A session that dies
            // while the panel is open clears the flag with the failure already
            // stored, and this returned `EmptyView` to a row `lines` had just
            // reserved a box for — so the row collapsed and "Session expired —
            // sign in again", the one sentence written for this exact state, was
            // unreachable from a sweep for every provider in the app.
            EmptyView()
        } else if let result {
            switch result {
            case .success(let data):
                primaryMetric(data)
                // The trace is a sibling of the meter block and not part of it,
                // and it is written at all three connected states rather than
                // wrapped once around them: these are already the enclosing
                // stack's children at `contentSpacing`, which is exactly the
                // pitch `RowGeometry` reserved, and a stack introduced to save
                // two lines would be a second opinion about that pitch. All
                // three states reserve the slot, so all three fill it.
                sparkline
                // The pace claim used to be drawn here, as a fourth child of this
                // stack between the meter and the further windows. It is gone
                // from this position rather than moved within it: it now rides at
                // the tail of the caption line `primaryMetric` already drew, and
                // `ForecastLine`'s own comment records the full argument. The
                // short version is that a block here was unreserved height —
                // `RowGeometry.Lines` knew how to hold it and nothing ever asked
                // — so the first projection to qualify grew the row 19pt while
                // the panel was open, which `MenuBarExtra` answers by resizing its
                // window under the pointer.
                secondaryWindows(data.secondary)
                // Last, under every window the service itself reports. A budget
                // is the user's number and a quota is the service's, so it is
                // never the headline and never interrupts the ladder of meters
                // above it.
                budget(for: data)
            case .failure(let error):
                // One sentence, on the same line every other row draws its
                // caption on, and no glyph in front of it: the state is in the
                // rail, so the text column has one left edge in every state the
                // row can be in. One line and never two — the eight sentences the
                // panel is allowed to print are each short enough to fit, and
                // whatever the server actually said is in the row's tooltip.
                stated(error.errorDescription ?? "Not reporting")
                sparkline
                // The ladder, empty. Written at all three connected states for
                // the reason the trace above is, and for one more of its own:
                // these are the states the row is in *before* it knows how many
                // windows the service has, and a ladder that appeared with the
                // first answer would be the resize this reservation exists to
                // close, seen from the other side.
                secondaryWindows([])
                // The budget block, empty. Same argument as the ladder's: a row
                // that failed this refresh still holds the block its settings
                // reserved, so the block does not arrive with the next answer.
                budget(for: nil)
            }
        } else {
            // Loading, which is the state a real launch spends its first seconds
            // in: connected, asked, nothing back yet. It used to draw a name and
            // nothing else — four mystery rows with a service name in them — and
            // it now occupies exactly the box it will occupy once it reports, so
            // the row does not grow when the answer lands.
            stated("Checking…")
            sparkline
            secondaryWindows([])
            // And the budget block, empty. This was the one connected state that
            // did not draw it, and the omission was the reservation's own defect
            // seen from the other side: `lines` inserts `.budget` off the store
            // and never off the result, so a budgeted row reserved 20pt here at
            // cozy/100% and drew nothing in it — then grew by exactly that when
            // the first reading landed. A row that is still checking has to
            // occupy the box it will occupy once it reports, which is what the
            // paragraph above says about every other slot on this line.
            budget(for: nil)
        }
    }

    /// The row's own last day, under the meter that reads the same window at an
    /// instant. Past, then present in the rail, then future in the pace line.
    ///
    /// The slot is placed whenever the setting is on, and holds nothing when
    /// there is nothing — never `EmptyView`, which would be a row drawing
    /// `contentSpacing + sparklineHeight` less than `RowGeometry` reserved for it.
    /// The store answers nil for a row it has not built a trace for yet, and an
    /// empty array draws a box with no ink in it, which is the correct picture of
    /// "no history" and is the same thing the meter slot does on a row with no
    /// quota.
    @ViewBuilder
    private var sparkline: some View {
        if appearance.showsRowSparkline {
            RowSparkline(
                peaks: sparklines.series(for: provider.id)?.peaks ?? [],
                height: metrics.sparklineHeight
            )
        }
    }

    /// A row with no reading: its reserved meter slot, and one line saying why.
    ///
    /// The slot draws nothing at all. It is held open because the bit that decides
    /// a row's height is whether the row has a reading, and it must not flip when
    /// a fetch resolves — and because a rule drawn where a meter would go reads as
    /// a table rule rather than as an absence.
    ///
    /// The sentence is drawn only where the row reserves a line for it. Where it
    /// does not — Minimal — this state costs exactly what a reporting row costs,
    /// which is the slot and nothing else, and the state is in the rail instead:
    /// a spinner while the fetch is out, the warning triangle when it failed. The
    /// alternative was a Minimal panel that stood 15pt per row taller for its
    /// first two seconds and then shrank under the pointer, which is the defect
    /// this whole predicate exists to close.
    @ViewBuilder
    private func stated(_ text: String) -> some View {
        // The sentence first and the empty slot under it — the same two children
        // at the same spacing, so the row measures to the point what it measured
        // before and `RowGeometry` is untouched. What changes is where the hole
        // falls, and that is the panel's largest rhythm defect.
        //
        // Measured on the shipped render at cozy/100%: on a row with no reading —
        // ChatGPT, Claude Code, Grok — the 5 + 3 = 8pt of reserved-but-undrawn
        // slot stood *between* the name and the name's own caption, so the gap
        // inside a row was **18.0pt against 26.0pt between two rows, a ratio of
        // 1.44**. A list whose objects are held together barely more tightly than
        // they are held apart is a wall of text; that is exactly what the panel
        // was reading as. Under the shipped Minimal preset, where `MeterSlot`
        // draws nothing on *every* row, the same measurement is 12.5 against
        // 15.0 — 1.20× on 100% of rows.
        //
        // With the slot last, that air joins the seam instead: 10.0pt inside
        // against 34.0pt between, a ratio of 3.40, which is the same order as the
        // 3.06 the three rows that draw a real bar already had. One list of
        // objects rather than one column of text.
        //
        // The cost, stated because it is real: a row that is loading and then
        // lands a quota redraws as slot-then-line, so its caption drops 8pt once,
        // in the first seconds after a cold launch with the panel open. The
        // panel does not resize — the height is identical either way — and the
        // rows that are permanently quotaless, which is the whole set this is
        // for, never make that transition at all.
        // Both children are conditional, so the stack itself has to be — and it
        // was not. Under the ring with the window line unreserved there is
        // nothing to say and no slot to say it over, and the empty `VStack` that
        // was returned anyway is still a subview of the row's own
        // `VStack(spacing: contentSpacing)`, which charges the full pitch for it.
        // The success path in the same settings emits `Optional.none` from the
        // ring branch of `primaryMetric` and costs nothing, and `RowGeometry`
        // computes `meterBlock == 0` and adds no pitch either — so the row stood
        // **contentSpacing taller while waiting and while failed and shrank when
        // its first answer landed**: 4 / 6 / 8pt at compact / cozy / comfortable,
        // measured on a hosted row, which is 8pt a row and 120pt down a panel of
        // fifteen at the comfortable density.
        //
        // No shipped preset lands here — Monochrome is the only ring preset and
        // it ships amounts, countdowns and chips all on, and `.chips` forces
        // `reservesWindowLine` — but all four terms are switches in the
        // Appearance pane, so it was four clicks from the defaults. An empty
        // container is not free in a stack that spaces its children, and that is
        // the general lesson: the row must place nothing, not place an empty
        // something.
        if reservesWindowLine || appearance.meterStyle != .ring {
            VStack(alignment: .leading, spacing: metrics.captionGap) {
                if reservesWindowLine {
                    Text(text)
                        .font(.system(size: metrics.detailSize, weight: .regular))
                        .foregroundColor(Tokens.Ink.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minHeight: Tokens.lineBox(metrics.detailSize), alignment: .leading)
                }
                reservedMeterSlot
            }
        }
    }

    /// The meter slot with nothing in it.
    ///
    /// Not placed at all under the ring, where the dial in the leading column is
    /// the meter and this space was never the row's to spend.
    @ViewBuilder
    private var reservedMeterSlot: some View {
        if appearance.meterStyle != .ring {
            Color.clear
                .frame(height: metrics.barHeight)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func primaryMetric(_ data: UsageData) -> some View {
        let metric = data.primary
        let run = chipRun(data)
        if metric.limit > 0 {
            switch appearance.meterStyle {
            case .bar, .numberOnly:
                // One view for both, because the difference between them is what
                // fills the meter slot rather than whether there is one: a bar
                // draws a track, and a bare number leaves the slot empty because
                // the figure on the title line is the meter there. Row height
                // stops being a function of the setting.
                //
                // The further windows ride down here rather than being drawn as a
                // block of their own, which is what makes them cost no height at
                // all: they are the trailing half of the caption line.
                UsageBar(
                    metric: metric,
                    accent: provider.accentColor,
                    appearance: appearance,
                    spend: data.spend,
                    chips: run.chips,
                    overflow: run.overflow,
                    reservesLine: reservesWindowLine,
                    pace: paceText(for: data)
                )
            case .ring:
                // The dial in the leading column and the trailing percentage
                // are the meter here; only the context line is left to draw.
                // Reserved or absent, never "drawn when there happens to be
                // something to say": with the line reserved, a caption with
                // nothing in it holds its box open so the row measures the same
                // before and after its first reading.
                if reservesWindowLine {
                    let line = primaryCaption(data)
                    if line.hasContent { line } else { ReservedTextLine(size: metrics.detailSize) }
                }
            }
        } else {
            // A service that reports a state rather than a quota. The slot is
            // reserved and empty, and the distinction the hairline used to attempt
            // — "reports no quota" against "is at 0%" — is made in the rail
            // instead: a figure means there is a quota, a dot means there is not.
            // A rule drawn between a title and a caption was indistinguishable
            // from a row divider, which is a poor way to make a fine distinction.
            //
            // The status line goes with the window line, because a row cannot know
            // it is quotaless until it reports: reserving a line for the sentence
            // only when a service turns out to have one is the same fetch-time
            // resize seen from its other side. Where the line is unreserved the
            // dot in the rail is the whole of what a quotaless row says, which is
            // what it says while it is loading too.
            if reservesWindowLine {
                slotted(metric) {
                    StatusLine(
                        metric: metric,
                        accent: provider.accentColor,
                        appearance: appearance,
                        spend: data.spend,
                        chips: run.chips,
                        overflow: run.overflow
                    )
                }
            } else {
                reservedMeterSlot
            }
        }
    }

    /// A headline window's meter slot with its line under it, for the one case
    /// `UsageBar` does not cover — a service reporting a state rather than a
    /// quota.
    ///
    /// The slot is dropped under the ring and only there, because that style
    /// draws its meter in the leading column instead and drawing a second one
    /// here would be a hybrid row that exists nowhere in the app.
    @ViewBuilder
    private func slotted<Line: View>(
        _ metric: UsageMetric,
        @ViewBuilder line: () -> Line
    ) -> some View {
        // Line first, slot second, for the reason written out at `stated` — and
        // here the slot is provably always empty rather than usually: this is
        // only ever reached from the `metric.limit > 0` false branch of
        // `primaryMetric`, and `MeterSlot.drawsTrack` requires `limit > 0`. So
        // the reorder cannot move a drawing, only a hole.
        VStack(alignment: .leading, spacing: metrics.captionGap) {
            line()
            if appearance.meterStyle != .ring {
                MeterSlot(
                    metric: metric,
                    accent: provider.accentColor,
                    appearance: appearance
                )
            }
        }
    }

    /// The further windows, for the one style that still spends height on them.
    ///
    /// `.chips` draws nothing here: those fold onto the trailing half of the
    /// caption line above and cost no vertical space at all, which is what a
    /// weekly window is worth beside the window the row is actually about. A
    /// second full-width meter per window was 24pt each, nine times down the
    /// panel, and it is what painted every row amber.
    ///
    /// **A ladder of `secondaryLines` slots, not one child per window.** That is
    /// the change this pass made and it is the only shape in which the drawing
    /// can equal the reservation: the count came from the fetch, so the row that
    /// drew it was a row whose height was a function of what the provider
    /// happened to answer with. The slots past the answer are held open and left
    /// empty, exactly as the meter slot and the trace slot already are — a row
    /// with one window under a limit of six draws it and five clear lines, and it
    /// draws them before its first answer, after a failure, and after an answer
    /// with more windows in it than the last one had.
    @ViewBuilder
    private func secondaryWindows(_ windows: [UsageMetric]) -> some View {
        if secondaryLines > 0 {
            // One line per window, not one meter. A weekly cap you are 80%
            // through still deserves naming and a figure of its own; it does not
            // deserve a second bar the width of the row.
            //
            // On the enclosing VStack's own spacing, with nothing added on top:
            // the pitch from the primary meter to the first secondary one is then
            // the same as the pitch between two secondaries, so the third window
            // of one service sits on the same line as the third of the next. A
            // ladder of one depth on every row is what finally makes that claim
            // true of two services that report different numbers of windows,
            // which is the argument the pitch was already making.
            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                // Keyed on position rather than on the window's name: a service
                // can report two windows under one label, and a repeated `ForEach`
                // id draws one of them and silently drops the rest. Position is
                // also what an empty slot has instead of a metric.
                //
                // `numbered(_:limit:)` was here and is deleted with the last
                // caller that could take fewer slots than the settings hold open.
                ForEach(0..<secondaryLines, id: \.self) { index in
                    if index < windows.count {
                        secondaryWindow(windows[index])
                    } else {
                        // An unfilled rung, marked rather than left blank.
                        //
                        // Everywhere else in the row a reservation with nothing
                        // in it draws nothing — the meter slot, the trace slot,
                        // the budget block — and that is right, because each of
                        // those is one hole in a row that has other things to
                        // say. This ladder is the case where the rule stops
                        // working: the Dashboard preset held six rungs open, and
                        // a service reporting one window drew five consecutive
                        // empty lines, so four such rows in a row read as a panel
                        // that had failed to render rather than as a panel making
                        // room. Reserved space has to look reserved.
                        //
                        // Height is untouched — the rule is centred inside the
                        // same `lineBox(detailSize)` the stand-in occupies, and
                        // the stand-in is still what sets it — so this cannot
                        // reach the row's height however many rungs are empty.
                        EmptyRung(size: metrics.detailSize)
                    }
                }
            }
        }
    }

    /// The user's own line, under every window the service itself reports.
    ///
    /// Reserved from `reservesBudgetLine`, which is a setting, and therefore
    /// **drawn in every state the row can be in** — which is the whole reason
    /// this is a function taking an optional rather than an `if let` at the one
    /// call site that has a reading. `detailContent` built `BudgetMeter` inline on
    /// `budgetLine(for: data) != nil`, and that predicate asks `BudgetPolicy` to
    /// compare `data.spend` against the budget: a spend is whatever the last
    /// fetch carried, so the block arrived with the answer. Measured on a hosted
    /// row at the shipped 356pt, a budgeted Claude row grew **22 / 26 / 30pt at
    /// compact / cozy / comfortable** the moment its first reading landed, and
    /// `MenuBarExtra` sizes its window to its content. The full argument, and why
    /// folding onto an existing line is not available to a track and a figure the
    /// way it was to the pace claim, is at `RowGeometry.Lines.budget`.
    ///
    /// Nil is the loading state and the failed one; a non-nil reading with no
    /// comparison in it is the third — no spend, a budget of zero, or two
    /// currencies, which are the refusals `budgetLine` already owns. All three
    /// draw the same empty block, so they are answered here in one branch rather
    /// than asked of each caller in turn.
    ///
    /// The empty block is the same two parts at the same pitch with no ink in
    /// them: `secondaryBarHeight` of track and one `lineBox(detailSize)` of line,
    /// joined by `captionGap` — 3 + 3 + 14 = 20pt at cozy/100%, which is the
    /// arithmetic `RowGeometry` reserves and the stack `BudgetMeter` sets.
    @ViewBuilder
    private func budget(for data: UsageData?) -> some View {
        if reservesBudgetLine {
            if let data, let line = budgetLine(for: data) {
                BudgetMeter(
                    status: line.status,
                    budget: line.budget,
                    spend: line.spend,
                    accent: provider.accentColor,
                    appearance: appearance
                )
            } else {
                // Track first and line second, which is the one place this file
                // does *not* follow `stated(_:)`'s reorder. That reorder puts the
                // hole last so the reserved-but-undrawn air joins the seam between
                // two rows instead of standing between a name and its own caption;
                // this block is already the last child of the row's stack, so both
                // orders put the air at the same place on the panel. What is left
                // is that the empty block should read in the same order as the
                // full one, so a reader comparing the two branches is comparing
                // one arrangement rather than two.
                VStack(alignment: .leading, spacing: metrics.captionGap) {
                    Color.clear
                        .frame(height: metrics.secondaryBarHeight)
                        .accessibilityHidden(true)
                    ReservedTextLine(size: metrics.detailSize)
                }
            }
        }
    }

    /// The windows the caption line carries, and how many it had no room for.
    /// Empty under every style but `.chips`, which is the only one that puts them
    /// on a line that already exists.
    private func chipRun(
        _ data: UsageData
    ) -> (chips: [UsageMetric], overflow: Int) {
        let windows = data.secondary
        guard !windows.isEmpty,
              appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .chips
        else { return ([], 0) }
        let split = chipSplit(
            windows.count,
            carriesSpend: data.spend != nil,
            yieldsToTheSentence: yieldsToTheSentence(data)
        )
        return (Array(windows.prefix(split.shown)), split.hidden)
    }

    /// Whether the caption's sentence outranks one of the chips beside it.
    ///
    /// At or above caution it does, and the measurement is what makes the case.
    /// The panel's flagship row — a 5-hour window at 92% — reads `5h session` at
    /// the shipped 356pt and keeps `Opus wee… 12%`: the `resets in 1h 19m` is the
    /// candidate `ViewThatFits` drops *first*, because the chip run is
    /// `.fixedSize()` and takes its width before the sentence is offered
    /// anything. So the row that is about to be cut off does not say when it
    /// comes back, in order to show a 12% reading of a different window.
    ///
    /// Above caution the reset time is the one fact on the row a user can act
    /// on — wait, or stop — and the further windows are context. Below it the
    /// ranking is the other way round and nothing here fires.
    ///
    /// Width only, and that is what makes it safe: the caption is one `lineBox`
    /// whatever is on it, so the number of chips has never been an input to row
    /// height. A *height* that moved with the reading would be the resize
    /// `RowGeometry` exists to forbid; a width that does is the line choosing
    /// what to say with the room it has.
    ///
    /// It costs no reservation either. `RowGeometry.chipCap` is still asked for
    /// the geometric limit, so each chip is capped exactly as before and the run
    /// is bounded by the same arithmetic — one fewer chip inside a bound is
    /// still inside it.
    private func yieldsToTheSentence(_ data: UsageData) -> Bool {
        guard appearance.showsCountdowns, data.primary.resetDate != nil else { return false }
        return data.primary.percent >= appearance.cautionThreshold
    }

    /// How many chips the line holds, and the user's own ceiling on top of it.
    ///
    /// The width half of that is `RowGeometry`'s, which owns the chip's two
    /// reserved runs and the gap between them. `RowGeometry.chipLimit`
    /// deliberately does not clamp upward, because the ceiling is not a
    /// measurement: a stepper set to six windows says how many the user wants to
    /// see, not how many fit. This is the only place the two ends meet.
    ///
    /// `carriesSpend` is presence of a `SpendReport` and nothing about its
    /// amount. It belongs here and not in `lines` for a reason worth stating:
    /// `SpendFigure` leads the caption at `layoutPriority(1)` in every candidate
    /// and cannot be dropped, so it takes width off the same line the chips ride
    /// — but it takes no *height*, because the line is one `lineBox` whatever is
    /// on it. A width-only input cannot resize a row when a bill lands, which is
    /// the whole reason the reservation is otherwise content-free.
    private func chipLimit(carriesSpend: Bool) -> Int {
        min(
            appearance.secondaryWindowLimit,
            RowGeometry.chipLimit(
                // Off `rowGeometry(lines:)` rather than `geometry`, for the reason
                // written there: this is asked while the row is still working out
                // which lines it has, and the width does not depend on them.
                textColumnWidth: rowGeometry(lines: []).textColumnWidth,
                // The size the chips are actually set in. It was `captionSize`,
                // which is a point smaller at every density, so the budget was
                // measured one type step below the type being drawn.
                chipSize: metrics.detailSize,
                carriesSpend: carriesSpend
            )
        )
    }

    /// How the windows split between chips of their own and the "+N" that stands
    /// for the rest.
    ///
    /// The line silently began at the front of the list: a user who set the limit
    /// to six and got two chips on a narrow panel could not tell a service with
    /// two caps from one with six, which is the difference between "I am fine"
    /// and "I have not looked at four of these". The overflow chip takes a slot
    /// off the line rather than being added to it — pushed past the trailing edge
    /// it would be truncated away, which is the failure it exists to report — and
    /// one real chip is always kept, since "+6" alone names no window at all.
    ///
    /// That last clause is the one case where the run draws one item more than the
    /// limit, and `RowGeometry.chipLimit` pays for it by reserving the "+N"'s
    /// three cells before it divides rather than after.
    private func chipSplit(
        _ count: Int,
        carriesSpend: Bool,
        yieldsToTheSentence: Bool = false
    ) -> (shown: Int, hidden: Int) {
        RowGeometry.chipSplit(
            count: count,
            limit: chipLimit(carriesSpend: carriesSpend),
            yieldsToTheSentence: yieldsToTheSentence
        )
    }

    /// One further window: its name, and its reading in the secondary rail.
    ///
    /// No meter of any kind, under any meter style. A second track down the row
    /// is what made a 61% weekly window paint a second amber bar on every row in
    /// the panel, and the number carries that reading on its own — which is the
    /// whole argument for a reserved figure column in the first place.
    @ViewBuilder
    private func secondaryWindow(_ metric: UsageMetric) -> some View {
        if metric.limit > 0 {
            MetricCaption(
                metric: metric,
                isSecondary: true,
                accent: provider.accentColor,
                appearance: appearance
            )
        } else {
            // No ceiling: a percentage would be a division by nothing, so the
            // rail carries the bare value instead.
            SecondaryValue(metric: metric, appearance: appearance)
        }
    }

    /// The line under the headline meter, chips and all.
    ///
    /// Asked for three times — to draw, to decide whether the row reserves that
    /// line, and to choose the row's vertical alignment — so it is built in one
    /// place. The chips are part of it by construction, which is what stops the
    /// row reserving no line and then drawing chips on it.
    private func primaryCaption(_ data: UsageData) -> MetricCaption {
        let run = chipRun(data)
        return MetricCaption(
            metric: data.primary,
            isSecondary: false,
            accent: provider.accentColor,
            appearance: appearance,
            spend: data.spend,
            chips: run.chips,
            overflow: run.overflow,
            pace: paceText(for: data)
        )
    }

    /// The pace claim for this row's headline window, or nil when there is
    /// nothing honest to say.
    ///
    /// Asked here and handed down as a string, never asked by the caption. The
    /// caption reads the answer three times — for the separator in front of the
    /// run, for `hasContent`, and for the run itself — and a view that asked the
    /// trend store once per reading would be three fits per row per render, on
    /// the main actor, for one sentence.
    ///
    /// Every refusal behind it belongs to `UsageForecast`: too few samples, a
    /// flat or falling slope, an arrival past the horizon. This adds only the
    /// setting, and `ForecastLine.text` is where those two meet.
    private func paceText(for data: UsageData) -> String? {
        ForecastLine.text(
            projection: trend.projection(for: provider.id),
            now: Date(),
            showsPace: trend.showsPaceInPanel,
            // The caption prints a countdown for this same `resetDate` two runs
            // ahead of the pace, so the `resetsFirst` sentence would have said it
            // again — `resets in 25m · resets in 25m, you'll finish under`.
            // Asked of the setting and the date rather than of what the caption
            // finally fits: the candidate ladder can drop the countdown to make
            // room, and a claim whose *wording* depended on which candidate won
            // would be a string that changes when the panel is dragged wider.
            namesReset: appearance.showsCountdowns && data.primary.resetDate != nil
        )
    }

    /// A meter's colour: the ramp at every level, including the resting one.
    private func tint(for percent: Double) -> Color {
        appearance.tint(for: percent, providerAccent: provider.accentColor)
    }

    /// A figure's colour, which is the same ramp with one band held back — the
    /// digits stay neutral until there is something to say. The two are separate
    /// calls rather than one with a flag because they answer different questions,
    /// and the meter must not quietly follow the figure's rule.
    private func figureTint(for percent: Double) -> Color {
        appearance.figureTint(for: percent, providerAccent: provider.accentColor)
    }

    private var showsPlan: Bool { showsPlanName ?? appearance.showsPlanNames }

    private var primaryPercent: Double? {
        guard case .success(let data) = result, data.primary.limit > 0 else { return nil }
        return data.primary.percent
    }

    /// The same reading for the figure, which is the one place the clamp is
    /// wrong — see `UsageMetric.rawPercent`. The dial and the bar keep
    /// `primaryPercent`, because a length has an end and a number does not.
    ///
    /// The rail is unchanged and does not need to change: it reserves three
    /// digits and a unit, which is exactly what "147%" takes.
    private var primaryFigure: Double? {
        guard case .success(let data) = result, data.primary.limit > 0 else { return nil }
        return data.primary.rawPercent
    }

    /// The budget this row is allowed to report on, and what it says. Nil is the
    /// common case and means one of four things `BudgetPolicy` refuses to answer
    /// — no spend, no budget, a budget of zero, or two currencies — every one of
    /// which is "there is no comparison to make" rather than a reading of zero.
    private func budgetLine(
        for data: UsageData
    ) -> (status: BudgetStatus, budget: Budget, spend: SpendReport)? {
        // Keyed on the service rather than on the row: two Claude accounts are
        // one subscription as far as the person paying is concerned.
        guard let spend = data.spend,
              let budget = budgets.budget(for: provider.serviceID),
              let status = BudgetPolicy.status(spend: spend, budget: budget) else { return nil }
        return (status, budget, spend)
    }

    /// What the leading dial reads out. Empty when it is a placeholder, which is
    /// also when it is hidden from assistive tech.
    private var ringValue: String {
        guard let percent = primaryPercent else { return "" }
        return "\(Int((min(max(percent, 0), 1) * 100).rounded()))% used"
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

// MARK: - The near-cap contract

extension ProviderRow {
    /// The weight a figure is set at, which is one of the three channels that
    /// carry "at or above the warning threshold".
    ///
    /// Pure, and pure on purpose: colour is the weakest channel and the only one
    /// a greyscale panel, a colour-blind eye or `ColorRamp.mono` takes away.
    /// Nothing here reads the ramp, so the other two cannot quietly come to
    /// depend on it.
    public static func figureWeight(percent: Double, warning: Double) -> Font.Weight {
        isNearCap(percent: percent, warning: warning)
            ? Tokens.Ramp.alertWeight
            : Tokens.Ramp.titleWeight
    }

    /// The two drawn channels of the near-cap contract, for one reading.
    ///
    /// - `squareCap` is shape: the fill's trailing end squares off.
    /// - `heavyFigure` is weight: the figure goes to `Ramp.alertWeight`.
    ///
    /// The third channel is length and needs no function: at or above the warning
    /// threshold the fill occupies at least 95% of its track, which reads as full
    /// without anything being asked of it.
    ///
    /// Two channels that used to be here are gone with the drawings they belonged
    /// to. The spine — an unexplained coloured bar down the row's leading edge —
    /// could not be read without documentation, and a row that wants the user now
    /// says so in words — `Sign in` — in its own figure rail. The pace riser, and
    /// with it "the fill has crossed the boundary", was one drawing standing in for a
    /// sentence `ForecastLine` already writes out.
    ///
    /// Colour is the third thing and is never asked to carry this alone. Convert
    /// the panel to greyscale and a row at or above the threshold is still
    /// identifiable by a square cap, a heavier figure and a full bar. That is the
    /// promise; this is where it is written down so it can be asserted rather
    /// than hoped for.
    public static func nearCapChannels(
        percent: Double,
        warning: Double
    ) -> (squareCap: Bool, heavyFigure: Bool) {
        let nearCap = isNearCap(percent: percent, warning: warning)
        return (squareCap: nearCap, heavyFigure: nearCap)
    }

    /// At or above the threshold. A non-finite figure is not near a cap: it is
    /// no reading at all, and `>=` would answer false for it anyway — this says
    /// so out loud rather than relying on that.
    public static func isNearCap(percent: Double, warning: Double) -> Bool {
        guard percent.isFinite, warning.isFinite else { return false }
        return percent >= warning
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

// MARK: - Figures

/// A percentage, set the way every figure in this app is set: the number and its
/// unit in one mono run on one baseline, at one size.
///
/// The unit is not the reading. `%` is a separate `Text` in `Ink.muted` at the
/// resting weight, in every band and under every ramp, so colour and weight land
/// on the digits alone. It is no longer a *smaller* run: a large number with a
/// tiny raised tick beside it is fussy rather than fine, and it was the single
/// most conspicuous piece of house styling on the panel.
///
/// Two `Text`s in a baseline-aligned stack rather than one concatenation: the
/// two runs differ in size, weight and ink, and the `Text`-returning
/// `foregroundStyle` is macOS 14, so a `+` would have to spell the tick in a
/// deprecated modifier. The stack shares the same baseline and the same line
/// box, and costs nothing.
///
/// Both runs are tabular, and every one of the three call sites frames this in a
/// reserved trailing-aligned rail — the headline rail on the title line, the
/// secondary rail on a caption and under a budget. Tabular digits outside a rail
/// are a column that still reflows: they fix the width of a digit and not the
/// length of a string, so `9%` becomes `92%` and drags its neighbour. The rail is
/// the part that makes it a column.
///
/// `.number` over a scaled ratio rather than `.percent`, for the same reason
/// `HistoryChart` does it: `.percent` writes the sign into the run, and the sign
/// is the part being set separately here. It is still a `FormatStyle` and never
/// an interpolation, so the separator stays the reader's.
public struct UsageFigure: View {
    /// 0...1, though not clamped there: a budget is a line you can keep walking
    /// past, and a figure that stops at 100% would hide exactly the overspend
    /// the budget was set to find.
    public let percent: Double
    public let size: CGFloat
    public let unitSize: CGFloat
    public let weight: Font.Weight
    public let tint: Color
    /// Only the headline figure animates its digits. A caption that rolled every
    /// number on every refresh would be nine rows of movement to report nothing.
    public let animatesDigits: Bool

    public init(
        percent: Double,
        size: CGFloat,
        unitSize: CGFloat,
        weight: Font.Weight = Tokens.Ramp.titleWeight,
        tint: Color,
        animatesDigits: Bool = false
    ) {
        self.percent = percent
        self.size = size
        self.unitSize = unitSize
        self.weight = weight
        self.tint = tint
        self.animatesDigits = animatesDigits
    }

    /// The unit's size, which is now the figure's own — the same rule
    /// `AppearanceSettings.Metrics` applies to the headline pair. Kept as a
    /// function rather than deleted so a caption still asks the question in one
    /// place, and so the two ends of every rail are measured the same way:
    /// `secondaryRail` is three digits plus one unit cell, both at the caption's
    /// size.
    public static func unitSize(for size: CGFloat) -> CGFloat { size }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number
            // Verbatim: this is a unit tick, not a word to be looked up, and a
            // localised percent sign arrives with the number it belongs to.
            //
            // Neutral in every band and under every ramp, without exception, and
            // at the resting weight however heavy the digits go. The unit is an
            // annotation on the number rather than part of the reading, and
            // holding it here is what keeps the digits the only column in the
            // panel that colour ever arrives on.
            Text(verbatim: "%")
                .font(Tokens.Ramp.figureFont(unitSize))
                .foregroundColor(Tokens.Ink.muted)
        }
        .lineLimit(1)
        // A threshold crossing is an event, not a mood: the digits may roll, the
        // ink may never cross-fade. Held here rather than at the call sites so a
        // figure cannot pick up an animation from whatever it is nested in.
        .animation(nil, value: tint)
        // Unconstrained, a figure in a column too narrow for it wraps rather
        // than truncates: "100%" becomes "100" over "%" and the row grows a
        // line. It never gives width either — a truncated name is still a name,
        // "10…" is a different reading of 100%.
        .fixedSize()
    }

    @ViewBuilder
    private var number: some View {
        if #available(macOS 14.0, *), animatesDigits {
            figure.contentTransition(.numericText())
        } else {
            figure
        }
    }

    private var figure: some View {
        // No decimals. A tenth of a percent on a five-hour window is noise you
        // cannot act on; the row's tooltip is where it survives.
        Text(scaled, format: .number.precision(.fractionLength(0)))
            .font(Tokens.Ramp.figureFont(size, weight: weight))
            .foregroundColor(tint)
    }

    /// A NaN would reach the formatter and print as "NaN" in the middle of a
    /// column of readings, so it answers zero here instead.
    private var scaled: Double {
        guard percent.isFinite else { return 0 }
        return max(percent, 0) * 100
    }
}

/// An amount a service says has been spent.
///
/// Mono, because it is digits and separators — the currency symbol included.
/// The qualifier beside it is a word and is therefore not: an estimate is a
/// local token count priced against a published rate card, and a row that
/// presented that as the provider's own accounting would be lying about how
/// much the number is worth.
///
/// The amount sizes itself, and that is a rail deliberately given up. It *leads*
/// the caption line — it does not sit in a column of other amounts — so a
/// trailing-aligned eight-cell frame around a short bill indented the whole
/// caption by the slack: `$42.12 Credits · resets in 1h 19m` started 9pt right of
/// the meter above it and of the captions on every other row, and the indent moved
/// as the bill grew. There is at most one spend figure per row and never two above
/// each other, so nothing here has decimals to line up with; the mono face and the
/// two decimals stay, which is what the reading actually needed.
struct SpendFigure: View {
    let spend: SpendReport
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.snug) {
            Text(spend.display)
                .font(Tokens.Ramp.figureFont(size, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.muted)
                .lineLimit(1)
                // It never gives width: "$1,23…" is not a smaller number, it is no
                // number at all.
                .fixedSize()
            if spend.confidence == .estimated {
                // The same ink as the amount it qualifies. A third grey below the
                // caption grey was a rank the panel does not have, and `.tertiary`
                // is off the ladder entirely now.
                Text("est.")
                    .font(.system(size: size, weight: .regular))
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
            }
        }
        .help(spend.confidence == .estimated
              ? "Estimated locally from token counts and published prices, not a billed figure"
              : "Reported by the service")
    }
}

// MARK: - Meters

/// The meter itself, in two layers: the empty track and the fill.
///
/// It was four. The elapsed share of the track, the riser standing at the window
/// boundary and the slit cut through the fill where the fill had overtaken it
/// were one instrument saying how much of the *window* was gone — a second
/// quantity, drawn in a vocabulary a reader had to be taught. `ForecastLine`
/// already states it in a sentence, which is where a quiet interface puts a
/// claim, so this is a drawing deleted rather than a reading lost. It is also
/// what pinned the bar at 5pt: nothing punches through a 4pt fill.
///
/// One implementation, because the panel row, the settings sample and the budget
/// line all draw this; a private copy per call site is exactly how a preview
/// comes to disagree with the thing it previews.
public struct MeterTrack: View {
    public let percent: Double
    public let height: CGFloat
    public let tint: Color
    /// At or above the warning threshold, where the fill's trailing end squares
    /// off. The shape channel of the near-cap contract, and the one that
    /// survives greyscale and `ColorRamp.mono` alike.
    public let isNearCap: Bool
    /// Where the redline stands, as a fraction of the track. Zero draws none.
    ///
    /// `warningThreshold`, handed down rather than read here, for the same reason
    /// `isNearCap` is: the setting belongs to the caller and two views resolving
    /// one threshold in two places is how a mark and a state come to disagree.
    public let warning: Double

    public init(
        percent: Double,
        height: CGFloat,
        tint: Color,
        isNearCap: Bool = false,
        warning: Double = 0
    ) {
        self.percent = percent
        self.height = height
        self.tint = tint
        self.isNearCap = isNearCap
        self.warning = warning
    }

    /// One point, which is two device pixels on the panel this is drawn on.
    ///
    /// It was 1.5 for half a render and that was too wide: the shipped threshold
    /// is 0.95, so on a 160pt track the mark stands 152pt along and leaves 8pt of
    /// track behind it — and a 1.5pt gap in front of an 8pt round-ended remainder
    /// reads as a second, detached pill rather than as a scored line. At 1pt the
    /// remainder still separates and the mark reads as a cut. The lesson is
    /// general: this rule's width is measured against what is *left* of the track
    /// beyond it, not against the track's length.
    private static let redlineWidth: CGFloat = 1

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Tokens.Meter.track)
                // Flat. A gradient on a 4pt bar is a fill that reads as two
                // different tints depending on how full it is, which is one
                // reading too many for a meter.
                MeterFill(squareTrailing: isNearCap)
                    .fill(tint)
                    .frame(
                        width: MeterGeometry.fillWidth(
                            percent: percent,
                            track: geo.size.width,
                            thickness: height
                        )
                    )
                // The redline, and it is what turns this drawing from a progress
                // bar into a gauge.
                //
                // A progress bar fills towards a desirable completion; a quota
                // meter empties towards a cliff, so the informative half of the
                // reading is the part that is *left* — and until this mark
                // existed the drawing gave the empty half the least ink. At 92%
                // the remainder was 23pt of track at 1.43:1 against the ground
                // while the used half took 278pt of saturated amber, so the row
                // pre-attentively read "long bright bar, plenty", which is the
                // opposite of what it says. Hue was the only thing reversing that,
                // and hue is the channel the palette spends most carefully.
                //
                // It is a *position* channel, which is the argument for it over
                // everything else in the near-cap contract. Measured on the
                // shipped panel, the square cap is 2.5pt of corner on a 5pt bar —
                // 0.19% of the fill's area, and invisible between 95% and 99.5% —
                // and the weight step is +5.5% of stem ink. A tick the fill either
                // has or has not reached survives greyscale exactly, survives
                // deuteranopia exactly, survives `ColorRamp.mono` exactly, and
                // reads at 5pt.
                //
                // Drawn in `Surface.base` and over the fill, not under it, so that
                // it is a notch cut through the bar rather than a mark the reading
                // paints over: below the threshold it stands in the empty track,
                // at it the fill's edge meets it, above it the fill visibly runs
                // past. Same quantity the fill is already measuring, so unlike the
                // pace riser this replaces there is nothing for a reader to learn.
                if warning > 0, warning < 1 {
                    Rectangle()
                        .fill(Tokens.Surface.base)
                        .frame(width: Self.redlineWidth, height: height)
                        .offset(x: geo.size.width * CGFloat(warning) - Self.redlineWidth / 2)
                }
            }
        }
        .frame(height: height)
        // The fill's width is the reading changing and is worth watching; its ink
        // is a threshold being crossed and is not. A bar that cross-faded grey to
        // amber over a third of a second would turn the one event the panel exists
        // to report into a mood.
        .animation(Tokens.Motion.fill, value: percent)
        .animation(nil, value: tint)
    }

    // Where the reading becomes a length is `MeterGeometry`, shared with the
    // dial: a bar and a ring drawn from the same 7% may not disagree about how
    // long that is, and a private copy of the arithmetic per view is how they
    // would. The floor there is two thicknesses, because one thickness drew a
    // round-capped fill exactly as wide as it was tall — a dot, identical at 0.5%
    // and at 1%, and read as a bullet rather than as a small quantity.
}

/// A meter held to `MeterGeometry.trackWidth(in:)` of the column it is offered,
/// on that column's leading edge, with the rest of the line given back.
///
/// One modifier for the row's meter and the budget's, because "the budget line is
/// never longer than the quota above it" has to be one arithmetic rather than two
/// call sites that currently agree. It was two `.frame(maxWidth:)` calls each,
/// written out at both sites, and that was safe only while the length was a
/// constant — a growing track turns a duplicated ceiling into two meters that can
/// disagree about how wide the row is.
///
/// The trailing frame is what hands the width back: without it the slot would
/// shrink to the track and the caption's own trailing run would have a different
/// idea of where the line ends. The reader is width-only and the height is fixed
/// by the caller, so this cannot move a row vertically.
private struct TrackWidth: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content.frame(width: MeterGeometry.trackWidth(in: geo.size.width), height: height)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The row's meter slot, and it has exactly two drawings: a track with a fill in
/// it, or nothing.
///
/// The rule it used to draw instead of nothing was one drawing standing in four
/// unrelated situations — a bare-number panel, a quotaless service, a row still
/// loading, a row that failed — so it could not distinguish any of them, and
/// full-width between a title and a caption it read as a row divider. Under the
/// **Minimal** preset every row in the panel drew one, with nothing beneath it and
/// the last one dangling at the window's bottom edge.
///
/// The distinction it was attempting is made in the figure rail now: a figure means
/// there is a quota, a dot means there is not. The slot keeps its height in both
/// cases, which is what the row is squared against.
public struct MeterSlot: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    /// The service's brand colour, which `colorRamp == .provider` paints with.
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

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }
    private var height: CGFloat { metrics.barHeight }

    /// A track is drawn for a real quota under the bar. Under `numberOnly` the
    /// figure on the title line is the meter, and under the ring the dial in the
    /// leading column is — so the slot is held open and left empty there rather
    /// than drawing a second meter or a rule that stands in for one.
    private var drawsTrack: Bool {
        metric.limit > 0 && appearance.meterStyle == .bar
    }

    public var body: some View {
        Group {
            if drawsTrack {
                MeterTrack(
                    percent: metric.percent,
                    height: height,
                    tint: appearance.tint(for: metric.percent, providerAccent: accent),
                    isNearCap: ProviderRow.isNearCap(
                        percent: metric.percent,
                        warning: appearance.warningThreshold
                    ),
                    warning: appearance.warningThreshold
                )
            } else {
                Color.clear
            }
        }
        // The slot, whether or not there is anything in it. Both cases are the
        // same height, which is what the row is squared against.
        .frame(height: height)
        // The length, and only the length — `MeterGeometry.trackWidth(in:)`
        // carries the measurements. Leading, because the shared left edge is what
        // lets one row's reading be compared with the next one's down the column,
        // and it is the same x the name, the caption and the meter have always
        // started on.
        //
        // Read off a `GeometryReader` rather than plumbed down from `RowGeometry`,
        // and the reason is that the two would be the same number arrived at
        // twice: the slot is the only child of the row's text column that asks for
        // the whole of it, so the width proposed here *is* `textColumnWidth`, and
        // a second copy computed from `panelWidth`, `logoStyle`, `logoSize` and
        // `ringDiameter` is exactly the private-arithmetic drift `RowGeometry`
        // exists to have deleted. It also keeps the two callers of this view — the
        // panel row and the Appearance sample — agreeing without either of them
        // being handed anything.
        //
        // A reader takes the proposal and does not change it, so this is width-only
        // in both directions: nothing here can widen the row, and the height is
        // still the `.frame(height:)` above. Width is not an input to
        // `RowGeometry.height`, so no row moves by a point.
        .modifier(TrackWidth(height: height))
        // A shape says nothing out loud. Whoever wraps this owns the reading:
        // `UsageBar` speaks its fill, the title line speaks the figure.
        .accessibilityHidden(true)
    }
}

/// The headline usage bar: the meter slot, and one line of context underneath.
///
/// `isSecondary` no longer draws a second bar — a further window gets a line and
/// a figure and nothing else. The flag survives because the line it produces is
/// still a different sentence: a secondary window has to name itself, where the
/// headline one has already been named by the row.
public struct UsageBar: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    /// A further window rather than the headline one: no track at all, and the
    /// window's own name in front so "7d" and "GPT-4o" are told apart.
    public let isSecondary: Bool
    /// The service's brand colour, which `colorRamp == .provider` paints with.
    public let accent: Color
    /// What this service says it has spent, when it says anything. Carried into
    /// the caption rather than drawn here: money is a reading of the row, not of
    /// the meter.
    public let spend: SpendReport?
    /// The further windows riding on the trailing half of the caption line, and
    /// the count of the ones that did not fit. The row decides both; this only
    /// passes them to the line that carries them.
    public let chips: [UsageMetric]
    public let overflow: Int
    /// Whether the row has reserved a line under this meter — `ProviderRow`'s
    /// `reservesWindowLine`, handed down rather than worked out again here.
    ///
    /// The bar cannot answer it: the predicate reads the row's own
    /// `showsAllWindows` override, and two views deciding the same thing in two
    /// ways is precisely how the reservation and the drawing came to differ by a
    /// line in the first place. True is the right default for the one caller that
    /// does not say — the settings sample, whose whole job is to look like the
    /// panel's busiest row.
    public let reservesLine: Bool
    /// The pace claim about this window, already resolved by the row.
    ///
    /// Passed through untouched, exactly as `spend` and `chips` are: the bar
    /// draws no part of it and makes no decision about it, but the caption it
    /// owns is the line the claim rides on, and a caption built without it would
    /// silently drop the pace under every meter style but the ring. Defaulted so
    /// the settings sample and the tests that predate the fold keep compiling.
    public let pace: String?

    public init(
        metric: UsageMetric,
        isSecondary: Bool = false,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil,
        spend: SpendReport? = nil,
        chips: [UsageMetric] = [],
        overflow: Int = 0,
        reservesLine: Bool = true,
        pace: String? = nil
    ) {
        self.metric = metric
        self.isSecondary = isSecondary
        self.accent = accent
        self.spend = spend
        self.chips = chips
        self.overflow = overflow
        self.reservesLine = reservesLine
        self.pace = pace
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }

    /// Whether the meter slot goes under the caption rather than over it, which
    /// it does exactly when there is nothing in it to draw. A setting and only a
    /// setting — see the two call sites in `body`.
    private var placesSlotLast: Bool { appearance.meterStyle == .numberOnly }

    private var caption: MetricCaption {
        MetricCaption(
            metric: metric,
            isSecondary: isSecondary,
            accent: accent,
            appearance: appearance,
            spend: spend,
            chips: chips,
            overflow: overflow,
            pace: pace
        )
    }

    public var body: some View {
        // A caption belongs to the bar above it, so it sits at half the pitch
        // that separates one meter from the next — one rule for both kinds of
        // bar, resolved once in `Metrics`.
        let bar = VStack(alignment: .leading, spacing: metrics.captionGap) {
            // Only the headline window occupies a meter slot. A second full-width
            // track per window cost 24pt of row height each and painted the panel
            // one colour; the figure in the secondary rail carries that reading on
            // its own, which is what a reserved figure column is for.
            //
            // Above the caption when there is a track to draw, and under it when
            // there is not — the reason is written out at `ProviderRow.stated`.
            // Here the test is `meterStyle == .numberOnly` and nothing else, which
            // is a *setting*: this view is only reached from the `limit > 0`
            // branch, so under `.bar` the slot always has a track in it and under
            // `numberOnly` it never does. The empty case is the Minimal preset,
            // where the hole was between the name and its caption on every row in
            // the panel at once — 12.5pt inside against 15.0 between.
            if !isSecondary, !placesSlotLast {
                MeterSlot(metric: metric, accent: accent, appearance: appearance)
            }
            // Whether there is a line here is the settings' answer; what goes on
            // it is the reading's. Those two used to be one question — a caption
            // with nothing in it drew nothing and cost nothing — so a row that had
            // reserved a line stood a whole `lineBox` shorter the moment its first
            // reading landed and every row beneath it moved up.
            //
            // The outer `if` is what makes it settings-only, and it is the reason
            // an unreserved line drops a spend as well as a countdown: money is
            // the one thing `MetricCaption.hasContent` returns true for that no
            // setting governs, so drawing it here would put the line back on a
            // Minimal row the instant a bill arrived — a row growing on a fetch,
            // which is the defect, wearing a currency symbol.
            if reservesLine {
                if caption.hasContent {
                    caption
                } else {
                    ReservedTextLine(size: metrics.detailSize)
                }
            }
            if !isSecondary, placesSlotLast {
                MeterSlot(metric: metric, accent: accent, appearance: appearance)
            }
        }
        // The meter says nothing out loud — the fill fraction is the whole
        // reading, so it is spoken as the meter's value. Clamped, because an
        // overage would otherwise announce "137% used".
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((min(max(metric.percent, 0), 1) * 100).rounded()))% used")

        // The caption's own text is the label whenever one is drawn, and naming
        // the bar here would throw the amounts and the countdown away. With no
        // line under the meter, or with both halves of the caption switched off,
        // there is no text left — so then, and only then, the window names
        // itself. It has to ask both questions the drawing above asks, or a
        // Minimal row goes out unnamed to a screen reader.
        if reservesLine, caption.hasContent {
            bar
        } else {
            bar.accessibilityLabel(metric.label)
        }
    }
}

/// The window line with nothing written on it.
///
/// The same trick `reservedMeterSlot` plays one line up, for the same reason: a
/// row's height must be a function of its settings and not of what came back
/// from the network, so a line the settings reserve is a line the row occupies
/// in every state — with a countdown in it, with an error in it, and with
/// nothing in it. Sized at `Tokens.lineBox`, which is the floor every
/// single-line detail in the panel is held at, so the empty box and the four
/// things that can fill it are one height.
///
/// One implementation and not a `Color.clear` written out at each of the four
/// call sites, because four copies of a reservation is how a reservation comes
/// to disagree with itself.
///
/// **An empty run and not an empty box**, which is a distinction worth 0.7pt a
/// line and was worth nothing until the ladder made lines countable. This was
/// `Color.clear.frame(height: Tokens.lineBox(size))` — the raw box, to the
/// fraction. A `Text` is not: SwiftUI resolves a line of type to whole points, so
/// at cozy/130% a real caption stands 18.0pt where `lineBox(14.3)` is 17.3, and at
/// comfortable/130% 19.0 against 18.6. One line of that is the "point over the
/// reservation" the row already accepts, and the empty box and the filled line
/// differing by it was invisible while there was at most one of each per row.
///
/// The further-window ladder made it visible and made it a defect: six rungs at
/// 0.7 is 4.2pt, and *which* rungs are filled is exactly what the fetch decides.
/// So the stand-in is now a run of one space, set in the same face and size as the
/// line it stands in for and held at the same floor — measured at all nine
/// density × text-scale combinations, it is the same height as a
/// `MetricCaption(isSecondary: true)` and a `SecondaryValue` to the point. A row
/// that reports one window under a limit of six is the height of the same row
/// reporting six.
struct ReservedTextLine: View {
    /// `Metrics.detailSize` — the size of the text this stands in for.
    let size: CGFloat

    var body: some View {
        Text(verbatim: " ")
            // `.regular` written out, as every run of prose in the panel is: this
            // stands in for a caption, and a caption is regular.
            .font(.system(size: size, weight: .regular))
            // The same floor `MetricCaption` and `SecondaryValue` hold themselves
            // at, so the empty line and the filled one are one measurement rather
            // than two that happen to agree.
            .frame(minHeight: Tokens.lineBox(size), alignment: .leading)
            // A space is not something to read out. The line is a hole in the
            // layout and holes have nothing to say.
            .accessibilityHidden(true)
    }
}

/// A rung of the further-windows ladder with no window in it: the same box
/// `ReservedTextLine` holds, with a short rule standing in the label's column.
///
/// The rule is where a window's name would start and it is as long as one — a
/// third of the label column, which at every density lands between the width of
/// `Weekly` and the width of `Opus weekly`. It is not a dash and not an em rule:
/// a glyph would be read, and this is the absence of a reading rather than a
/// value that happens to be missing. What it says is "a line belongs here", which
/// is exactly what the reservation means.
///
/// Drawn through `Tokens.quiet` at `Tokens.ruleOpacity`, which is the panel's
/// one rule — the same ink and the same weight as the hairline under the header,
/// stepped up by the same accessor under Increase Contrast. So a ladder of empty
/// rungs reads as ruling rather than as content, and it reads that way for
/// everyone: it is not a second faint grey with its own opinion about how faint
/// to be.
struct EmptyRung: View {
    /// `Metrics.detailSize` — the size of the line this stands in for.
    let size: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .leading) {
            // The stand-in still owns the height, so the rule cannot become the
            // measurement: one `lineBox(size)`, the same as a filled rung.
            ReservedTextLine(size: size)

            Rectangle()
                .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
                .frame(width: size * 3, height: Tokens.Control.hairline)
        }
        .accessibilityHidden(true)
    }
}

/// A compact dial, for `meterStyle == .ring`. Carries no number of its own —
/// at the diameters this is drawn at, two digits inside the ring are smaller
/// than the captions beside them, and the percentage is already on the title
/// line.
public struct UsageRing: View {
    public let percent: Double
    public let diameter: CGFloat
    public let thickness: CGFloat
    public let tint: Color
    /// At or above the warning threshold: the arc's trailing cap squares off,
    /// which is the same shape channel the bar carries.
    public let isNearCap: Bool

    public init(
        percent: Double,
        diameter: CGFloat,
        thickness: CGFloat,
        tint: Color,
        isNearCap: Bool = false
    ) {
        self.percent = percent
        self.diameter = diameter
        self.thickness = thickness
        self.tint = tint
        self.isNearCap = isNearCap
    }

    /// A 12pt stroke on an 18pt dial is a disc with a dimple. Whatever the
    /// meter thickness, the ring keeps a hole a third of its width.
    private var stroke: CGFloat { min(thickness, diameter / 3) }

    /// How far round the dial the arc is painted, floored at two strokes so the
    /// smallest reading is a stub with a direction rather than a dot. Off
    /// `MeterGeometry`, shared with the bar, because a dial and a bar reading the
    /// same number may not disagree about how much that is.
    private var fill: Double {
        MeterGeometry.ringTrim(percent: percent, diameter: diameter, stroke: stroke)
    }

    /// One stroke of arc as a share of the dial, which is exactly what a round
    /// cap adds to the paint at each end of a trim — half at the start, half at
    /// the finish.
    private var capFraction: Double {
        MeterGeometry.ringCapFraction(diameter: diameter, stroke: stroke)
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Tokens.Meter.track, lineWidth: stroke)
            if fill > 0 {
                arc(to: fill, colour: tint, cap: isNearCap ? .butt : .round)
            }
        }
        .frame(width: diameter, height: diameter)
        // The arc's length is the reading; its ink is a threshold. Same rule as
        // the bar, so a dial and a bar on the same number cannot behave
        // differently.
        .animation(Tokens.Motion.fill, value: percent)
        .animation(nil, value: tint)
    }

    /// `strokeBorder` insets the track for us; a trimmed path has to be inset by
    /// hand or the arc overhangs it.
    ///
    /// `end` is where the paint has to stop, so the trim stops short of it: a
    /// round cap is drawn *outside* the trim it caps, half a stroke at each end,
    /// and a dial that ignored that painted every reading a full stroke long —
    /// 9.4 points at the shipped size, against a figure on the same line that was
    /// telling the truth. A butt cap adds nothing and is inset by nothing, which
    /// is also what keeps the near-cap dial's square finish landing exactly on its
    /// reading.
    private func arc(to end: Double, colour: Color, cap: CGLineCap) -> some View {
        // Never inverted, and never wider than the arc it is trimming: below the
        // floor there is not a whole cap's room, and half of what there is at each
        // end still paints exactly `end`.
        let inset = cap == .round ? min(capFraction / 2, end / 2) : 0
        return Circle()
            .inset(by: stroke / 2)
            .trim(from: inset, to: max(inset, end - inset))
            .stroke(colour, style: StrokeStyle(lineWidth: stroke, lineCap: cap))
            .rotationEffect(.degrees(-90))
    }
}

/// The line of context under a meter: what the window is called, how much of it
/// is gone, when it comes back, and — on the headline line — the further windows
/// this service reports. Every part of it is optional, so it also answers
/// whether it would draw anything at all.
///
/// Two columns, not one run of text. What the window is, how much of it is gone
/// and when it comes back read from the left as one sentence; the other windows
/// are pushed to the trailing edge, where they land on the same x on every row
/// instead of wherever the sentence before them happened to stop.
///
/// The further windows live here rather than on a line of their own, and that is
/// the whole of what made them affordable: a weekly cap is worth naming and worth
/// a figure, and it is not worth 24pt of a 65pt row.
public struct MetricCaption: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    public let isSecondary: Bool
    public let accent: Color
    /// Money this service reports, on the headline line only: a spend covers the
    /// account rather than one of its windows, and repeating it under every
    /// window would read as several bills.
    public let spend: SpendReport?
    /// The further windows folded onto the trailing half of this line, and the
    /// count of the ones there was no room for. The row owns both decisions —
    /// which style is in force and how many fit the residual width — because only
    /// the row knows how wide its text column is.
    public let chips: [UsageMetric]
    public let overflow: Int
    /// The pace claim about *this* window — "on pace to cap in 40m" — resolved by
    /// the row and drawn at the tail of the sentence.
    ///
    /// A string and never a store, for the reason `ForecastLine.phrase` gives:
    /// the separator in front of it, `hasContent`, and the run itself are three
    /// readings of one decision, and a caption that asked the trend store again
    /// would be a second copy of it.
    ///
    /// Headline only, like the spend beside it: a further window is not the
    /// window the samples were taken against. `isSecondary` drops it the same way
    /// `shownSpend` drops money.
    ///
    /// It takes width and never height — the line is one `lineBox` whatever is on
    /// it — so a projection arriving mid-refresh cannot resize the row. That is
    /// the whole of why the pace lives here instead of in a block of its own; see
    /// `ForecastLine`.
    public let pace: String?

    public init(
        metric: UsageMetric,
        isSecondary: Bool = false,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil,
        spend: SpendReport? = nil,
        chips: [UsageMetric] = [],
        overflow: Int = 0,
        pace: String? = nil
    ) {
        self.metric = metric
        self.isSecondary = isSecondary
        self.accent = accent
        self.spend = spend
        self.chips = chips
        self.overflow = overflow
        self.pace = pace
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    /// One size for both lines. The panel has two type sizes and a secondary
    /// window is not a third rank — it is the same rank about a different window,
    /// and setting it a point smaller was a hierarchy the row does not have.
    private var size: CGFloat { appearance.metrics.detailSize }

    /// A secondary window always keeps its name — without it the row has two
    /// unlabelled figures and no way to tell which cap is which. The primary
    /// window is already named by the row itself, so it can vanish entirely —
    /// unless there is money to report, or a chip riding on the line, neither of
    /// which anything else on the row carries.
    public var hasContent: Bool {
        if isSecondary { return true }
        if shownSpend != nil { return true }
        if !chips.isEmpty || overflow > 0 { return true }
        // A pace on its own is content: with amounts and countdowns both off but
        // the chips style reserving this line, the claim is the only thing there
        // is to put on it, and answering false here would draw a `ReservedTextLine`
        // over the top of it. It cannot change the row's height either way — both
        // are one `lineBox` — so this is about what is said, not what is measured.
        if shownPace != nil { return true }
        return (appearance.showsAmounts && !amountText.isEmpty)
            || (appearance.showsCountdowns && resetText != nil)
    }

    public var body: some View {
        // Left unconstrained, a Text narrower than its content wraps rather than
        // truncates, so at 300pt these would quietly become three lines and
        // shove the row apart.
        // The gap to the trailing half is the stack's own spacing and not a
        // `Spacer`, and that is the same fix the header line needed. A `Spacer`
        // sits at priority 0 with no ceiling, so it competes for slack with a
        // sentence asking for `maxWidth: .infinity` and takes a share of it: the
        // caption's sentence was offered 56pt of the 65.5pt actually going spare
        // and clipped `5h session` to `5h sessi…` by three points. The sentence's
        // own frame is what pushes the windows to the trailing edge; nothing else
        // needs to.
        HStack(spacing: Tokens.Space.medium) {
            if isSecondary {
                Text(metric.label)
                    .font(.system(size: size, weight: .regular))
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Each part is dropped whole rather than truncated, and that is
                // the fix for a caption that used to read `5h sessi… · resets
                // in…`: "resets in…" carries no information whatsoever, and the
                // point it truncated at moved as the reading crossed 10 and 100.
                //
                // The count gives way after the countdown, and that is the third
                // candidate rather than an ellipsis because a clipped figure is
                // worse than an absent one. Measured at the shipped 356pt with two
                // chips on the line, the second candidate is offered ~110pt and
                // `3.2k / 5.0k` wants 74 — but the same row at `Max 20x` with a
                // `Weekly Opus 180/300` chip beside it drew `3.2k / 5.…`, a figure
                // cut mid-number, which reads as a different quantity. A dropped
                // count costs nothing the row does not already say: the percentage
                // in the rail is the same reading, and the window is named by the
                // row itself.
                //
                // Money is in every candidate and never gives way — it is the one
                // figure on the line that nothing else on the row reports.
                //
                // The last candidate names the window rather than saying nothing,
                // and that is not a nicety. `includesAmount: false` on a counted
                // window left an *empty* run, and an empty run took the slack and
                // handed the line's whole left half to no one: at 356pt with two
                // chips on it a `3.2k / 5.0k` row drew its caption starting at
                // 112pt while the row directly above it started at 39.5pt — two
                // adjacent detail lines 72pt out of register, in the panel and in
                // the Appearance pane's own preview. A window's name is the
                // cheapest thing that can hold that edge, and it is the one part
                // of the line the row cannot say twice: the rail repeats the
                // figure, nothing repeats "5h session".
                // The pace is the first thing dropped, and the ladder under it is
                // the ladder that was there before this run existed, unchanged
                // and in the same order. That is deliberate and it is the
                // property worth holding: the fold adds one richer candidate at
                // the top rather than rewriting the ranking, so a line too tight
                // to carry the claim draws exactly what it drew without it —
                // never less. Nothing the caption used to say can be lost to a
                // projection arriving.
                //
                // Dropped before the countdown and not after, because the
                // countdown is a fact the provider published and the pace is a
                // claim fitted from half an hour of samples. Where the two
                // compete for the last thirty points of a 300pt panel, the fact
                // wins.
                //
                // `includesCountdown` is asked *and* gated on
                // `countdownRidesTheEdge`, which collapses the first two rungs into
                // one on a row whose countdown has gone to the trailing edge. Two
                // identical candidates cost a measurement and change nothing —
                // `ViewThatFits` takes the first that fits — and writing the ladder
                // as a conditional instead would hand `ViewThatFits` a group where
                // it needs a list of siblings.
                ViewThatFits(in: .horizontal) {
                    leadingRun(includesCountdown: true, includesPace: true, reading: .amount)
                    leadingRun(includesCountdown: true, includesPace: false, reading: .amount)
                    leadingRun(includesCountdown: false, includesPace: false, reading: .amount)
                    leadingRun(includesCountdown: false, includesPace: false, reading: .name)
                    leadingRun(includesCountdown: false, includesPace: false, reading: .none)
                }
                // The sentence takes the slack rather than the `Spacer` behind
                // it, so it is offered the residual width rather than being
                // handed none at all by a gap.
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            trailing
        }
        .frame(minHeight: Tokens.lineBox(size))
    }

    /// How much of this window's own reading a candidate spells out.
    ///
    /// Three steps down, and never a shorter spelling of the same step — each one
    /// is drawn whole or not offered. The last step really is nothing, and only
    /// because the step above it may not be shaved: offered 10pt at a 300pt panel
    /// with two windows on the line, `5h session` truncates to `5`, a lone digit
    /// that reads as a reading. An absent sentence costs the line its left edge;
    /// a one-character sentence costs the line its meaning, and that is worse.
    fileprivate enum Reading {
        /// `3.2k / 5.0k` — or, for a percentage, the window's name, because the
        /// number is already in the rail.
        case amount
        /// The window's name alone: `5h session`.
        case name
        /// Nothing at all, for a line that has no room for a word.
        case none
    }

    /// The sentence half of the line: money, then what this window is and how
    /// much of it is gone, then when it comes back.
    ///
    /// The two parameters are how the candidates above differ, and they only ever
    /// turn a part down — a run asked for without its countdown is the same run
    /// with the countdown absent, never a shorter spelling of it. Nothing here
    /// abbreviates, because abbreviating is what produced `3.2k / 5.…`.
    private func leadingRun(
        includesCountdown: Bool,
        includesPace: Bool,
        reading: Reading
    ) -> some View {
        HStack(spacing: Tokens.Space.snug) {
            // Money leads the line when there is any. It is the one figure on the
            // row nothing else says, and the counts behind it are what should give
            // if the line runs out.
            if let spend = shownSpend {
                SpendFigure(spend: spend, size: size)
                    .layoutPriority(1)
            }
            if let text = readingText(reading) {
                // The one pair on this line that was joined by four points of
                // space and nothing else. `$10,000.00 5h session · resets in 19m`
                // reads as a single run — "$10,000.00 5h" — because every other
                // pair on the line carries a dot and this one did not, so the eye
                // takes the absence as "these belong together". Money and a
                // window are two facts of equal standing, like the window and its
                // countdown two lines down, so they take the same mark.
                //
                // Reserved as well as drawn: `RowGeometry.spendReserve` counts it,
                // because `SpendFigure` is `layoutPriority(1)` and `fixedSize`, so
                // anything added beside it comes out of the chips' budget rather
                // than out of slack.
                if shownSpend != nil { separator }
                amount(text)
            }

            if includesCountdown, !countdownRidesTheEdge, appearance.showsCountdowns, let reset = resetText {
                // Two facts about one window, so they are separated the way the
                // panel separates everything else — a middle dot, in the same ink.
                // Without it "5h session resets in 1h 19m" reads as one sentence
                // with a word missing, which is what four points of space says at
                // 11pt.
                if leadsCountdown { separator }
                // A run with a word in it, so SF Pro with tabular digits rather
                // than the figure face. Full mono on "resets in 1h 20m" is the
                // terminal pastiche the direction rules out.
                //
                // The window line is one rank however many parts it has: the
                // counts and the countdown are both the provider stating a fact
                // about this window, and a third ink to separate two facts of
                // equal standing is a hierarchy the row does not have.
                Text(reset)
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
            }

            if includesPace, let pace = shownPace {
                // Last on the line and separated like everything else on it. It
                // is never the only thing here without a mark in front of it:
                // `leadsPace` asks the same two questions the two runs above
                // answer, so a caption whose amount and countdown were both
                // switched off opens with the claim rather than with a dot.
                if leadsPace(includesCountdown: includesCountdown, reading: reading) { separator }
                ForecastLine(phrase: pace, appearance: appearance)
            }
        }
        // No `fixedSize` here, deliberately: `ViewThatFits` compares each
        // candidate's *ideal* width — the whole string — against the width it is
        // offered, so the choice is already made on the untruncated run. Fixing
        // the size as well would only stop the last candidate from truncating at
        // 300pt, where an unabbreviated count is worth an ellipsis.
    }

    /// Whether the countdown rides the trailing edge of this line rather than the
    /// tail of the sentence at the head of it.
    ///
    /// **The row's answer to a wide panel, and the job the full-width bar used to
    /// do.** Measured on the shipped render at 520pt, the widest interior void on a
    /// metered row was 274pt — 53% of the window — because the only thing reaching
    /// the trailing edge was the figure on the title line, so a row read as two
    /// columns with a canyon between them and a name sat 350pt from its own
    /// reading. The rows that did *not* read that way were the ones with a further
    /// window riding this line's trailing half: Claude's void at the same width was
    /// 20pt. So the fix is not to invent something to fill the gap, it is to give
    /// every metered row the same trailing column those rows already had, out of
    /// what the row already says.
    ///
    /// The countdown is what goes there because it is the row's second fact about
    /// the same window, and because right-aligned it becomes a column that can be
    /// read down the panel — "when does this come back" at one x on every row —
    /// which is a thing the panel could not do before and is worth more than the
    /// middle dot it gives up.
    ///
    /// Only when the trailing half is otherwise empty. A row with further windows
    /// on this line already has its trailing column and the countdown stays in the
    /// sentence, which is also the direction that cannot cost information: the
    /// chips are a reading the row states nowhere else, and the countdown is
    /// dropped by the candidate ladder before they are.
    ///
    /// **Width and never height.** The line is one `lineBox` whatever is on it and
    /// this changes nothing about that; and it is decided from settings and the
    /// presence of a reset date, both of which the row already turns into a
    /// `hasContent` answer, so nothing here can move a row when a fetch lands.
    private var countdownRidesTheEdge: Bool {
        !isSecondary
            && chips.isEmpty
            && overflow == 0
            && appearance.showsCountdowns
            && resetText != nil
    }

    /// What sits at the trailing edge of the line: the further windows on the
    /// headline line, the countdown when there are none, this window's own figure
    /// on a secondary one.
    ///
    /// The empty rail the headline line used to hold is kept only where there is
    /// nothing at all at the trailing edge. It exists so the sentence stops at the
    /// same x as the leading halves of the secondary lines under it; with chips or
    /// a countdown on the line, holding it as well would park them a rail's width
    /// in from the row's own edge, which is the misalignment it was there to
    /// prevent.
    @ViewBuilder
    private var trailing: some View {
        if isSecondary {
            if appearance.showsUsageNumber {
                UsageFigure(
                    percent: metric.percent,
                    size: size,
                    unitSize: UsageFigure.unitSize(for: size),
                    weight: ProviderRow.figureWeight(
                        percent: metric.percent,
                        warning: appearance.warningThreshold
                    ),
                    // A figure, so it follows the figures' rule and not the
                    // meter's: neutral below caution, the ramp from there up. The
                    // column of numbers down the panel is the one colour arrives
                    // on.
                    tint: appearance.figureTint(for: metric.percent, providerAccent: accent)
                )
                .layoutPriority(1)
                .frame(width: rail, alignment: .trailing)
            }
        } else if !chips.isEmpty || overflow > 0 {
            SecondaryChipRun(
                chips: chips,
                overflow: overflow,
                accent: accent,
                appearance: appearance,
                // The run's cap comes out of what is left of the line, and the
                // spend at the head of it is the part of that line nothing can
                // give back.
                carriesSpend: shownSpend != nil
            )
        } else if countdownRidesTheEdge, let reset = resetText {
            // SF Pro with tabular digits and `Ink.muted`, exactly as it is set at
            // the tail of the sentence — moving a run to the other end of the line
            // is a change of position and must not become a change of rank.
            Text(reset)
                .font(.system(size: size, weight: .regular))
                .monospacedDigit()
                .foregroundColor(Tokens.Ink.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                // It is served before the sentence, which is the opposite of the
                // priority the countdown has *inside* the sentence, and
                // deliberately: there it is one clause among several and the
                // ladder drops it to keep the reading; here it is the row's whole
                // trailing column and giving it up would put the canyon back. The
                // sentence has four candidates left to give way through and this
                // has none, so the flexible half is the one that should bend. It
                // can still truncate rather than overhang, which is what keeps
                // `PanelWidthContractTests` true at 300pt and 130% type.
                .layoutPriority(1)
        } else if appearance.showsUsageNumber {
            Color.clear
                .frame(width: rail, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Whether anything precedes the countdown on this line, and therefore
    /// whether the countdown needs a separator in front of it.
    private var leadsCountdown: Bool {
        shownSpend != nil || (appearance.showsAmounts && !amountText.isEmpty)
    }

    /// The one punctuation mark the panel uses between two facts of equal
    /// standing. Verbatim, and hidden from assistive tech — a screen reader
    /// reading "middle dot" between two phrases is noise where a pause is meant.
    private var separator: some View {
        Text(verbatim: "·")
            .font(.system(size: size, weight: .regular))
            .foregroundColor(Tokens.Ink.muted)
            .accessibilityHidden(true)
    }

    /// A raw count is a run with a unit or a slash in it, and often a word, so
    /// it is SF Pro with tabular digits — the rule is the run, not the number.
    private func amount(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size, weight: .regular))
            .monospacedDigit()
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
    }

    private var rail: CGFloat { appearance.metrics.secondaryRail }

    private var shownSpend: SpendReport? { isSecondary ? nil : spend }

    /// The pace claim, on the line that is entitled to carry it.
    ///
    /// Headline only, and dropped on a further window for the same reason money
    /// is: the samples were fitted against *this* row's leading window, so
    /// repeating the claim under a weekly cap would be a projection about one
    /// window printed under another. The setting is already applied upstream by
    /// `ForecastLine.text(projection:now:showsPace:)`, which is the one place the
    /// decision is made, so this only answers which line it belongs on.
    private var shownPace: String? { isSecondary ? nil : pace }

    /// Whether the pace needs a separator in front of it.
    ///
    /// It needs one whenever something precedes it on the line, and needs the
    /// absence whenever it opens the line — otherwise a caption whose amount and
    /// countdown are both switched off begins with a middle dot and no left-hand
    /// side, which reads as a run that failed to load rather than as a claim.
    ///
    /// The two questions asked here are the same two the runs above answer, in
    /// the same order, rather than a flag threaded down from the candidate: a
    /// second opinion about whether the countdown drew is exactly how the dot
    /// came to be printed against nothing in the first place.
    private func leadsPace(includesCountdown: Bool, reading: Reading) -> Bool {
        if shownSpend != nil { return true }
        if readingText(reading) != nil { return true }
        return includesCountdown && appearance.showsCountdowns && resetText != nil
    }

    /// What a candidate's reading step actually puts on the line, or nil when the
    /// user has switched every text channel on this line off and the caption is
    /// theirs to leave as money and chips.
    ///
    /// The name is offered under either text setting rather than under
    /// `showsAmounts` alone, because the case it exists to catch is a line whose
    /// countdown did not fit: dropping the countdown must not also drop the only
    /// thing holding the line's left edge.
    private func readingText(_ reading: Reading) -> String? {
        guard appearance.showsAmounts || appearance.showsCountdowns else { return nil }
        switch reading {
        case .amount:
            guard appearance.showsAmounts else { return nil }
            return amountText.isEmpty ? nil : amountText
        case .name:
            return metric.label.isEmpty ? nil : metric.label
        case .none:
            return nil
        }
    }

    private var amountText: String { Self.amountText(for: metric) }

    /// For percentage metrics the number is already in the trailing rail, so
    /// the line names the window instead of repeating "47 / 100".
    ///
    /// The denominator is drawn only where there is one. A limit of zero is a
    /// window with no ceiling — `ClaudeCodeProvider` reports all four of its
    /// windows that way — so it reads "45.0k tokens in the last 5h", which is the
    /// true sentence, rather than "45.0k / 0 tokens", which is a division by
    /// nothing. That is the distinction the panel draws everywhere: a figure means
    /// there is a quota, no figure means there is not.
    ///
    /// Static and pure so the copy can be asserted against a provider's real
    /// payload without hosting a caption, which is the arrangement
    /// `MenuBarStripContent.accessibilityLabel` is already in.
    static func amountText(for metric: UsageMetric) -> String {
        if metric.unit == "%" {
            return metric.label
        }
        let unit = metric.unit.map { " \($0)" } ?? ""
        if metric.limit > 0, metric.limit.isFinite {
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
///
/// The dot that used to lead this line is in the row's figure rail now — and it
/// is no longer green either, since `Ink.ok` is deleted and it is drawn lit
/// against `Ink.muted` instead of coloured against nothing. It is the same
/// statement — a service with no meter and no figure needs one non-text proof
/// that the connection is up — made in the column the row keeps for its state,
/// which leaves this line starting at the same x as every other detail line in
/// the panel. A glyph in front of one row's text and not the next is the
/// two-indent defect the rail exists to close.
public struct StatusLine: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    public let accent: Color
    /// A service can publish no quota and still cost money — Claude Code counts
    /// its own tokens and prices them locally — so this line carries the amount
    /// the caption would have carried under a meter.
    public let spend: SpendReport?
    /// The further windows, folded onto this line the way they fold onto a
    /// metered row's caption. A quotaless service reports windows too, and
    /// without this they would be the one case that lost them.
    public let chips: [UsageMetric]
    public let overflow: Int

    public init(
        metric: UsageMetric,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil,
        spend: SpendReport? = nil,
        chips: [UsageMetric] = [],
        overflow: Int = 0
    ) {
        self.metric = metric
        self.accent = accent
        self.spend = spend
        self.chips = chips
        self.overflow = overflow
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var size: CGFloat { appearance.metrics.detailSize }

    public var body: some View {
        // The gap is the stack's spacing rather than a `Spacer`, for the reason
        // `MetricCaption` gives: a priority-0 `Spacer` takes a share of the slack
        // a sentence at `maxWidth: .infinity` is asking for, and the sentence is
        // then measured — and clipped — against less width than the line has.
        HStack(spacing: Tokens.Space.medium) {
            // The countdown is dropped whole rather than truncated, the same rule
            // a metered row's caption keeps: `renew…` is a word cut in half to
            // report nothing at all.
            ViewThatFits(in: .horizontal) {
                run(includesCountdown: true)
                run(includesCountdown: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !chips.isEmpty || overflow > 0 {
                SecondaryChipRun(
                    chips: chips,
                    overflow: overflow,
                    accent: accent,
                    appearance: appearance,
                    carriesSpend: spend != nil
                )
            }
        }
        .frame(minHeight: Tokens.lineBox(size))
    }

    private func run(includesCountdown: Bool) -> some View {
        HStack(spacing: Tokens.Space.snug) {
            Text(text)
                .font(.system(size: size, weight: .regular))
                .monospacedDigit()
                .foregroundColor(Tokens.Ink.muted)
                .lineLimit(1)

            if let spend {
                SpendFigure(spend: spend, size: size)
                    .layoutPriority(1)
            }

            if includesCountdown,
               appearance.showsCountdowns,
               let reset = metric.resetDate,
               let countdown = Countdown.short(until: reset) {
                // Two facts about one window, separated the way the panel
                // separates every other pair of them: a middle dot in the same
                // ink. `Active renews in 11d 23h` at four points of space is one
                // sentence with a word missing.
                Text(verbatim: "·")
                    .font(.system(size: size, weight: .regular))
                    .foregroundColor(Tokens.Ink.muted)
                    .accessibilityHidden(true)
                Text("renews in \(countdown)")
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    // One rank, like every other window line: it is the same
                    // statement the metered row above makes, about a window with
                    // no ceiling on it.
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
            }
        }
    }

    private var text: String { Self.text(for: metric) }

    /// A unit is the provider saying "this is a count", so lead with the
    /// figure: "0 reqs this cycle" answers something, "GPT-4 class requests"
    /// does not. Without a unit the metric is a state — Copilot's "Active" —
    /// and prefixing it with a number would be nonsense.
    ///
    /// No denominator here in any branch, and that is correct rather than an
    /// omission: this line is only ever drawn for a window with no ceiling, so
    /// there is no figure to divide by. Static and pure for the reason
    /// `MetricCaption.amountText(for:)` is — the sweep that proves no uncapped
    /// window renders a "/0" has to be able to ask all four of these.
    static func text(for metric: UsageMetric) -> String {
        guard let unit = metric.unit else { return metric.label }
        return "\(metric.displayUsed) \(unit) \(metric.label.lowercased())"
    }
}

/// A further window that reports a figure but no ceiling: its name, and its
/// value in the rail a percentage would have stood in.
public struct SecondaryValue: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric

    public init(metric: UsageMetric, appearance: AppearanceSettings? = nil) {
        self.metric = metric
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var size: CGFloat { appearance.metrics.detailSize }

    public var body: some View {
        HStack(spacing: Tokens.Space.snug) {
            Text(metric.label)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(Tokens.Ink.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Tokens.Space.medium)
            // Governed by showsAmounts like every other raw count, but the
            // label stays: a bare window name is still a window this service
            // reports, and dropping the line would hide that.
            if appearance.showsAmounts {
                Text(value)
                    .font(Tokens.Ramp.figureFont(size, weight: Tokens.Ramp.titleWeight))
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
                    // A floor rather than a fixed width: this is a count with a
                    // unit on it rather than three digits and a sign, so it can
                    // be wider than the rail the percentages line up in — but it
                    // starts on their edge.
                    .frame(minWidth: appearance.metrics.secondaryRail, alignment: .trailing)
            }
        }
        .frame(minHeight: Tokens.lineBox(size))
    }

    private var value: String { Self.value(for: metric) }

    /// The value and its unit, and never a ceiling: this view is chosen precisely
    /// when the window has none, so a denominator here would be a figure the
    /// provider did not publish. Static and pure for the reason
    /// `MetricCaption.amountText(for:)` is.
    static func value(for metric: UsageMetric) -> String {
        let unit = metric.unit.map { " \($0)" } ?? ""
        return "\(metric.displayUsed)\(unit)"
    }
}

/// What a budget says about this service's spend, under everything the service
/// itself reports.
///
/// A secondary-thickness meter and never the headline: a budget is the user's
/// number and a quota is the service's, and a row whose largest figure was a
/// line the user drew themselves would be reporting the wrong subject.
struct BudgetMeter: View {
    @ObservedObject private var appearance: AppearanceSettings
    let status: BudgetStatus
    let budget: Budget
    let spend: SpendReport
    let accent: Color

    init(
        status: BudgetStatus,
        budget: Budget,
        spend: SpendReport,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil
    ) {
        self.status = status
        self.budget = budget
        self.spend = spend
        self.accent = accent
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }
    private var size: CGFloat { metrics.detailSize }
    /// The meter's tint. The figure beside it takes `figureTint` instead, for the
    /// reason every other figure in the panel does.
    private var tint: Color { appearance.tint(for: status.fraction, providerAccent: accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.captionGap) {
            MeterTrack(
                percent: status.fraction,
                height: metrics.secondaryBarHeight,
                tint: tint,
                isNearCap: ProviderRow.isNearCap(
                    percent: status.fraction,
                    warning: appearance.warningThreshold
                ),
                warning: appearance.warningThreshold
            )
            // The same length and the same leading edge the row's own meter
            // takes. A budget line drawn twice the length of the quota above it
            // would say the user's number outranks the service's, which is the
            // one thing this view's own doc says it must not do — and that is a
            // claim about the *same arithmetic*, not about the same constant, so
            // it survives the track growing with the panel only because both
            // meters ask `trackWidth(in:)` about the column they are actually in.
            // They are always in the same one: this sits in the row's text column
            // directly under the meter it must not outrank.
            .modifier(TrackWidth(height: metrics.secondaryBarHeight))

            HStack(spacing: Tokens.Space.snug) {
                Text("Budget")
                    .font(.system(size: size, weight: .regular))
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
                    .layoutPriority(1)
                // A run with a word in it, so SF Pro with tabular digits.
                //
                // Muted whether or not the budget is over, because the figure at
                // the other end of this line already carries the ramp: one
                // coloured thing per line, ever. Amber on the words and amber on
                // the number was the same statement made twice, and it made a
                // line the user drew themselves as loud as the service's own cap.
                Text(remainingText)
                    .font(.system(size: size, weight: .regular))
                    .monospacedDigit()
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)

                Spacer(minLength: Tokens.Space.medium)

                if status.includesEstimates {
                    // The figure beside this rests on arithmetic this app did,
                    // not on a bill. Saying so is the difference between a
                    // reading and a guess.
                    Text("est.")
                        .font(.system(size: size, weight: .regular))
                        .foregroundColor(Tokens.Ink.muted)
                        .lineLimit(1)
                }

                UsageFigure(
                    percent: status.fraction,
                    size: size,
                    unitSize: UsageFigure.unitSize(for: size),
                    weight: ProviderRow.figureWeight(
                        percent: status.fraction,
                        warning: appearance.warningThreshold
                    ),
                    tint: appearance.figureTint(for: status.fraction, providerAccent: accent)
                )
                .frame(width: metrics.secondaryRail, alignment: .trailing)
            }
            .frame(minHeight: Tokens.lineBox(size))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Budget")
        .accessibilityValue(remainingText)
    }

    /// Stated in the budget's own currency and at the report's own scale — the
    /// two are the same by construction, since `BudgetPolicy` refuses to compare
    /// a budget against a spend billed in anything else.
    private var remainingText: String {
        let amount = money(abs(status.remainingMinor))
        return status.isOver ? "\(amount) over" : "\(amount) left"
    }

    private func money(_ minor: Int) -> String {
        let value = Decimal(minor) * Decimal(sign: .plus, exponent: -spend.exponent, significand: 1)
        return value.formatted(
            .currency(code: budget.currency).precision(.fractionLength(min(spend.exponent, 2)))
        )
    }
}

/// A window and where it sits in the row, which is the only id it has that
/// cannot repeat.
///
/// A service can report two windows under one name: Claude's per-model weekly
/// caps all come back as "Weekly · per-model" whenever the payload names no
/// model, and Gemini's unrecognised buckets as "Window 2". Keyed on `label`, a
/// repeated `ForEach` id draws one of them and drops the rest, so a service with
/// four windows would quietly show three.
struct NumberedMetric: Identifiable {
    let id: Int
    let metric: UsageMetric
}

/// The further windows as they ride the trailing half of a caption line, for
/// `secondaryWindows == .chips`.
///
/// `fixedSize` on the run, so the caption to its left is what truncates: which
/// windows exist and how full they are is the reading, and the sentence beside it
/// is context that can afford an ellipsis.
///
/// What must not depend on content is how much of the line the run *costs*: sized
/// to what it currently says, the run grew as a reading crossed 10 and again at
/// 100, so the truncation point of the sentence beside it moved as the data
/// ticked — `Weekly 4%` and `Weekly 49%` charged the caption different amounts for
/// nothing. That is fixed one level down, in the chip: each reading holds a rail of
/// four cells, so a percentage chip is one width whatever the number in it.
///
/// And what the run *costs* is settled one level down as well, in the chip's own
/// cap. `RowGeometry.chipCap` says how wide one chip may draw and
/// `RowGeometry.chipLimit` says how many of them the line is offered, out of the
/// same arithmetic against the same text column — so the run's ideal width is a
/// function of the settings alone and the reservation is an upper bound on it by
/// construction. Reserving `chips.count × chipWidth` without capping the chip was
/// tried and measured and is the shipped bug: the estimate counted a capsule's
/// padding and a dot this chip does not draw and left out four cells of reading,
/// so a 356pt row was handed three slots for a 344pt run in a 304pt column, and
/// `fixedSize` meant the excess had nowhere to go but past the panel's edge.
struct SecondaryChipRun: View {
    let chips: [UsageMetric]
    let overflow: Int
    let accent: Color
    let appearance: AppearanceSettings
    /// Whether the caption's leading half carries a spend figure it cannot give
    /// back. The run does not draw it and cannot see it, but it takes width off
    /// the same line, so the cap has to know.
    let carriesSpend: Bool

    init(
        chips: [UsageMetric],
        overflow: Int,
        accent: Color,
        appearance: AppearanceSettings,
        carriesSpend: Bool = false
    ) {
        self.chips = chips
        self.overflow = overflow
        self.accent = accent
        self.appearance = appearance
        self.carriesSpend = carriesSpend
    }

    var body: some View {
        HStack(spacing: Tokens.Space.medium) {
            ForEach(numbered) { window in
                SecondaryChip(
                    metric: window.metric,
                    accent: accent,
                    appearance: appearance,
                    cap: cap
                )
            }
            if overflow > 0 {
                OverflowChip(count: overflow, appearance: appearance)
            }
        }
        // Fixed, and it has to be. Offered less than it wants, the run does not
        // shorten one label — it starves every label to nothing and leaves a line
        // of unlabelled figures: `3/25  12/50`, two readings of two windows the
        // row can no longer name. The width it needs is the width it draws, and
        // the line's other half is sized against that.
        //
        // What makes that safe now is the cap above rather than the caption's
        // good manners: the run cannot ask for more than the column has, so
        // "the width it needs" is a width the line is known to hold.
        .fixedSize()
    }

    /// The widest any one of these chips may draw.
    ///
    /// Read from `RowGeometry` off the settings, exactly as the row reads the
    /// chip *count* from it — the panel width, the leading column and the type
    /// size are all settings, so this is the same number the row divided to
    /// decide how many chips to hand over. Asked here rather than threaded down
    /// through `MetricCaption` and `StatusLine` because the run is the thing that
    /// must not overflow, and a value passed through two views is a value two
    /// views can forget to pass.
    private var cap: CGFloat {
        RowGeometry.chipCap(
            textColumnWidth: RowGeometry(
                metrics: appearance.metrics,
                showsPercentage: appearance.showsPercentage,
                meterStyle: appearance.meterStyle,
                logoStyle: appearance.logoStyle,
                logoSize: CGFloat(appearance.logoSize),
                panelWidth: CGFloat(appearance.panelWidth),
                rowActions: appearance.rowActions,
                // The text column is the panel minus its gutters minus the
                // leading column, and none of the three is a function of which
                // lines the row draws.
                lines: []
            ).textColumnWidth,
            chipSize: appearance.metrics.detailSize,
            carriesSpend: carriesSpend
        )
    }

    private var numbered: [NumberedMetric] {
        chips.enumerated().map { NumberedMetric(id: $0.offset, metric: $0.element) }
    }
}

/// A further window folded down to a name and a reading, for
/// `secondaryWindows == .chips`.
///
/// No capsule, no fill and no coloured dot. A pill is a container, and a
/// container is only worth drawing where something has to be told apart from what
/// is beside it — here the gap does that, and four filled pills on a caption line
/// were four more shapes on a panel whose complaint was that it looked busy. What
/// is left is the two runs that were always the point.
public struct SecondaryChip: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let metric: UsageMetric
    public let accent: Color
    /// The widest this chip may draw, from `RowGeometry.chipCap`.
    ///
    /// A ceiling and not a width: a chip whose two runs are shorter than this
    /// draws shorter than this. What it buys is that no chip is ever *wider*,
    /// which is what turns the row's chip budget from an estimate of a drawing
    /// into a bound on it.
    public let cap: CGFloat

    public init(
        metric: UsageMetric,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil,
        cap: CGFloat
    ) {
        self.metric = metric
        self.accent = accent
        self.cap = cap
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var size: CGFloat { appearance.metrics.detailSize }

    /// How the cap divides between the label and the reading. Named once and
    /// read twice, so the two frames below cannot be given caps that do not add
    /// up to the one this chip was handed.
    private var runs: (label: CGFloat, reading: CGFloat) {
        RowGeometry.chipRuns(cap: cap, chipSize: size)
    }

    /// The anti-jitter floor's unspent half, moved to the head of the chip.
    ///
    /// The floor is real and stays (see the reading's frame below); where it was
    /// *spent* was the defect. Trailing-aligned inside a four-cell frame, a
    /// one-character reading left every unspent cell standing between the label
    /// and its own number: measured on the shipped panel, `Credits`→`0` is
    /// **26.0pt** and `Weekly`→`61%` is 11.5, against **8.5pt between two whole
    /// chips**. Every chip's internal gap exceeded its external one — worst case
    /// 3.06× inverted, on the busiest line in the panel — so the line read as
    /// pairs that had come apart rather than as chips.
    ///
    /// Both runs are mono at one size, so the slack is arithmetic rather than a
    /// measurement: the floor's four cells less the cells the reading actually
    /// takes, clamped at zero for anything longer. Spending it here leaves the
    /// label 4pt from its reading and folds the remainder into the 8pt gap
    /// before the chip — which is the ordering the eye needs, and costs the chip
    /// not one point of width, so the reservation and the rail are untouched.
    /// The floor is clamped under the reading's own ceiling rather than stated
    /// flat, exactly as the `minWidth` it replaces was: a line too narrow to hold
    /// a whole chip hands the reading fewer than four cells, and slack that
    /// exceeded the run's ceiling would push the chip past the cap `RowGeometry`
    /// reserved for it. So `label + snug + min(reading, floor) == cap` at worst,
    /// which is the bound the whole chip section is built on.
    private var headSlack: CGFloat {
        let cells = reading.digits.count + (reading.unit?.count ?? 0)
        let floor = min(runs.reading, Self.jitterFloor(size))
        return max(0, floor - Tokens.figureWidth(size, digits: cells, weight: Tokens.Ramp.titleWeight))
    }

    /// Four cells, and the one number the chip floors its reading at. Named
    /// because `headSlack` and the frame below have to agree about it exactly —
    /// two copies of this constant is two chips of different widths.
    private static func jitterFloor(_ size: CGFloat) -> CGFloat {
        // At the weight the chip's reading is set in, like every other cell on
        // this line: the floor and the run it floors have to be one measurement.
        Tokens.figureWidth(size, digits: 4, weight: Tokens.Ramp.titleWeight)
    }

    public var body: some View {
        HStack(spacing: Tokens.Space.snug) {
            // Two runs, not one: the window's name is a word and the reading
            // beside it is digits and separators, and each takes its own face.
            Text(metric.label)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(Tokens.Ink.muted)
                // Four chips of a long-named window overflow a 300pt panel;
                // truncating one label is better than pushing the last chip
                // off the edge.
                .lineLimit(1)
                .truncationMode(.tail)
                // And that is a ceiling now rather than a hope. `lineLimit` alone
                // truncates only when something narrower than the text proposes a
                // width, and nothing does: the run above is `fixedSize`, so the
                // label was asking for its whole ideal — 100.5pt for
                // "Weekly · all models" at 11 — and taking it out of a column that
                // did not have it. Eight cells is what `RowGeometry` reserved for
                // this run, so eight cells is what it may draw, and the estimate
                // and the drawing are the same number rather than two guesses at
                // one.
                .frame(maxWidth: runs.label, alignment: .leading)
                // The floor's unspent half, ahead of the label. See `headSlack`.
                .padding(.leading, headSlack)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(reading.digits)
                    // A figure, so it takes the figures' rule and not the meter's:
                    // neutral below caution, the ramp from there up. It was reading
                    // `tint`, which is the one thing on the row entitled to carry a
                    // colour at rest — a bar — so four resting chips arrived
                    // coloured on a line of context.
                    //
                    // `chipFigureTint` and not `figureTint`: a chip is a
                    // subordinate reading and may not outrank the row's headline.
                    // Measured on the panel of the day, the Claude row's `92%` sat
                    // at `Ink.attention` (L* 65.73, since re-cut to 76.92) under two
                    // chips at `Ink.body` (95.82) — the two least important numbers
                    // on the row 2.37:1 brighter than the most important one, in
                    // colour and not only in greyscale. The re-cut narrows that to
                    // 1.68:1 without closing it, which is why this is a rank rule
                    // and not a lightness one. The ramp still reaches the chip the moment its
                    // own window wants attention; only the resting rung moves.
                    .foregroundColor(appearance.chipFigureTint(for: metric.percent,
                                                               providerAccent: accent))
                if let unit = reading.unit {
                    // The unit sits out of the ramp, here as everywhere: `UsageFigure`
                    // holds its own `%` at `Ink.muted` in every band, and a chip
                    // baking the sign into the tinted string put a red `%` on the
                    // caption of a row whose headline figure had a grey one — one
                    // glyph, two rules, 40pt apart on the same line.
                    Text(verbatim: unit)
                        .foregroundColor(Tokens.Ink.muted)
                }
            }
                .font(Tokens.Ramp.figureFont(size, weight: Tokens.Ramp.titleWeight))
                .lineLimit(1)
                // Four cells, trailing — the rail every other figure in the panel
                // gets, at the one place a reading sits on a line that runs along
                // the row instead of down the panel. It is not there to line the
                // chips up with each other: it is there so the chip's width stops
                // changing as its reading crosses 10 and 100, which is what used to
                // move the truncation point of the caption beside it. A floor
                // rather than a width, because "12/100" is a count and not a
                // percentage and may be wider.
                //
                // And a ceiling, at the nine cells `RowGeometry` reserves: a capped
                // count with both halves formatted — Cursor's `1.0k/1.0k` — is the
                // widest reading the formatter can put here in practice and it
                // takes exactly those nine.
                //
                // The four-cell floor was a `minWidth` here and is `headSlack`
                // above instead. Same arithmetic, same chip width to the point,
                // same trailing edge on the panel's rail — the floor's unspent
                // half now falls before the label rather than between the label
                // and its own number. Stating it in one place only matters
                // because the two would otherwise both apply and the chip would
                // be one floor too wide.
                .frame(maxWidth: runs.reading, alignment: .trailing)
                // The reading is why the chip is here, so it is the part that
                // must not be abbreviated away.
                //
                // The one figure in the panel with no rail around it, and the
                // reason is that a chip is not a column: it is sized to what
                // it says, on a line that runs along the row rather than down the
                // panel, so there is no edge for a reading to line up on.
                // `fixedSize` is what does the work the rail does elsewhere: the
                // figure cannot be squeezed, and the label is what gives instead.
                .fixedSize()
                // A threshold crossing is an event, not a mood — the same rule
                // the bar and the headline figure keep.
                .animation(nil, value: metric.percent)
        }
    }

    private var reading: (digits: String, unit: String?) { Self.reading(for: metric) }

    /// The reading split where the panel splits every reading: the digits, which
    /// the ramp may colour, and the unit, which it may not.
    ///
    /// A limit of zero means the window has no ceiling, and it is the one case
    /// this got wrong. `ClaudeCodeProvider` reports `Today`, `7 days` and `30
    /// days` at `limit: 0`, and the chip drew them as `644.6M/0` — which is not a
    /// window at 644.6 million of nothing, it is a fraction whose denominator is
    /// zero, and it read as a bug on every Claude Code row in the panel. The bare
    /// value is what the rest of the row already says about the same metric:
    /// `MetricCaption` writes "45.0k tokens in the last 5h" and `SecondaryValue`
    /// writes "644.6M tokens", both of them on the panel's one rule that a figure
    /// means there is a quota and no figure means there is not.
    ///
    /// No unit on the bare value, and that is the chip and not the rule. The rail
    /// beside the label is nine mono cells; "644.6M" is six of them and
    /// "644.6M tokens" is thirteen, so the unit would be truncated away by the
    /// cap and the reading with it. What the window counts is on the row's own
    /// headline line, which is where a chip's reader takes it from.
    ///
    /// Static and pure so the copy can be asserted against a provider's real
    /// payload without hosting a chip.
    static func reading(for metric: UsageMetric) -> (digits: String, unit: String?) {
        if metric.unit == "%" || metric.limit == 100 {
            return ("\(Int(metric.used.rounded()))", "%")
        }
        guard metric.limit > 0, metric.limit.isFinite else {
            return (metric.displayUsed, nil)
        }
        return ("\(metric.displayUsed)/\(metric.displayLimit)", nil)
    }
}

/// The chip that stands for the windows the line had no room for.
///
/// The same type as a `SecondaryChip`'s reading, in the caption ink: it is a
/// count of windows rather than a reading of one, and a usage tint would claim a
/// colour for a group of them. It is the row admitting what it left out, so it
/// stays quiet — the tooltip is where the number is spelled out, since a bare
/// "+4" is only unambiguous to someone who already knew.
public struct OverflowChip: View {
    @ObservedObject private var appearance: AppearanceSettings
    public let count: Int

    public init(count: Int, appearance: AppearanceSettings? = nil) {
        self.count = count
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    public var body: some View {
        Text("+\(count)")
            .font(Tokens.Ramp.figureFont(appearance.metrics.detailSize))
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
            // The one chip on the line that must never be truncated: an
            // ellipsis here says nothing about how much was dropped. No rail, for
            // the reason a `SecondaryChip`'s reading has none — and this one is a
            // count of windows rather than a reading of one, so it has nothing to
            // line up with even in principle.
            .fixedSize()
            .help(count == 1
                  ? "1 more window this row has no room for"
                  : "\(count) more windows this row has no room for")
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
/// place in the app whose job is to show what the panel will look like.
public struct RowActions: View {
    public let visibility: AppearanceSettings.RowActionVisibility
    public let isHovered: Bool
    /// A service with no usage page gets one button. The sample row passes true
    /// because the row it is drawing is a stand-in for any service.
    public let hasDashboard: Bool
    /// A fetch for this row is in flight. The refresh glyph becomes a spinner in
    /// the box it already occupies: same box, same width, nothing moves. It is the
    /// whole of the in-flight cue on the row, which is all a refresh is worth —
    /// the reading stays put and the row keeps its height.
    public let isRefreshing: Bool
    public let refreshHelp: String
    public let onRefresh: () -> Void
    public let onOpenDashboard: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    public init(
        visibility: AppearanceSettings.RowActionVisibility,
        isHovered: Bool,
        hasDashboard: Bool,
        isRefreshing: Bool = false,
        refreshHelp: String = "Refresh",
        onRefresh: @escaping () -> Void = {},
        onOpenDashboard: @escaping () -> Void = {}
    ) {
        self.visibility = visibility
        self.isHovered = isHovered
        self.hasDashboard = hasDashboard
        self.isRefreshing = isRefreshing
        self.refreshHelp = refreshHelp
        self.onRefresh = onRefresh
        self.onOpenDashboard = onOpenDashboard
    }

    private var isShown: Bool {
        // A fetch in flight is worth saying whether or not the pointer is on the
        // row: it is the answer to "did my click do anything".
        if isRefreshing { return true }
        switch visibility {
        // A hover that never happens hides these buttons for good from anyone
        // driving the app by voice, and the space is reserved either way — so
        // under VoiceOver "on hover" simply means shown.
        case .onHover: return isHovered || voiceOverEnabled
        case .always:  return true
        case .never:   return false
        }
    }

    public var body: some View {
        if visibility != .never {
            HStack(spacing: 0) {
                if isRefreshing {
                    // Indeterminate, because the row has no idea how long a
                    // provider will take, and mini so the dial fits the glyph's own
                    // box rather than the box growing to fit a spinner.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: Tokens.Control.rowIconButton,
                               height: Tokens.Control.rowIconButton)
                        .help(refreshHelp)
                        // It stands where a named button stands, so it is named
                        // too, and out of `HoverIconButton` so the header's
                        // spinner and this one cannot come to say two things.
                        .accessibilityLabel(HoverIconButton.inFlightName)
                } else {
                    HoverIconButton(
                        systemName: "arrow.clockwise",
                        // Already "Refresh Claude" / "Refresh ChatGPT", which is
                        // the name as well as the hint here — the row is one of
                        // nine and the service is the half that tells them apart.
                        name: refreshHelp,
                        help: refreshHelp,
                        size: Tokens.Control.rowIconButton,
                        action: onRefresh
                    )
                }
                if hasDashboard {
                    HoverIconButton(
                        systemName: "arrow.up.right",
                        name: "Open usage page",
                        help: "Open usage page",
                        size: Tokens.Control.rowIconButton,
                        action: onOpenDashboard
                    )
                } else {
                    // Reserved, not omitted. Three of the fifteen services have
                    // no usage page — MiniMax, Claude Code, OpenCode — and
                    // without this their refresh button sits one whole
                    // `rowIconButton` to the right of every other row's, which is
                    // plainly visible the moment two of them are on screen
                    // together. The row reserves everything else it might not
                    // draw; this was the one control that did not.
                    Color.clear
                        .frame(width: Tokens.Control.rowIconButton,
                               height: Tokens.Control.rowIconButton)
                        .accessibilityHidden(true)
                }
            }
            .opacity(isShown ? 1 : Tokens.Dim.reserved)
            // The panel's one pointer duration, so the buttons arrive with the
            // card lighting up rather than a beat behind it. Opacity only: the
            // space is reserved either way, so nothing here can move.
            .animation(Tokens.Motion.hover, value: isShown)
            // Invisible buttons must not be clickable.
            .allowsHitTesting(isShown)
        }
    }
}

/// The row's own card, and the row's press.
///
/// It is a `ButtonStyle` because `configuration.isPressed` is the only honest
/// source of that state — a 66pt target that lights up under the pointer and then
/// says nothing at all when it is clicked was the clearest "side project" tell the
/// panel had. Fill only: no scale, no shadow, no geometry change on press, ever.
/// The panel is nine of these in a column and a row that flinched would move its
/// neighbours.
struct RowButtonStyle: ButtonStyle {
    let radius: CGFloat
    /// The user's row-background setting and the pointer, handed straight through
    /// to `Tokens.rowBackground` — which owns all three steps, so the panel and the
    /// Appearance pane's sample cannot come to disagree about any of them.
    let style: AppearanceSettings.RowBackground
    let isHovered: Bool
    /// The keyboard's row. It resolves to `Fill.pressed`, the same plane a press
    /// lands on, and there is deliberately no fourth token between them — the two
    /// are the same sentence, "this is the row the next action lands on", arriving
    /// from the arrow keys in one case and the pointer in the other.
    ///
    /// One drawn channel is correct here, and the reason is worth having in
    /// writing so nobody "fixes" it: the two-and-three-channel rule in this
    /// codebase belongs to the near-cap contract (`nearCapChannels`), which is a
    /// *measurement* that has to survive greyscale, colour blindness and
    /// `ColorRamp.mono`. A selection is a transient interaction state the user
    /// made half a second ago with an arrow key, at most one row carries it, and
    /// it has no hue at all — so greyscale takes nothing away from it. The second
    /// channel it does need is for assistive tech, and that is the `.isSelected`
    /// trait on the row's own Button.
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let resting = Tokens.rowBackground(style, isHovered: isHovered, isSelected: isSelected)
        return configuration.label
            .background(
                Tokens.surface(radius)
                    .fill(Tokens.quiet(Tokens.rowBackground(
                        style,
                        isHovered: isHovered,
                        isPressed: configuration.isPressed,
                        isSelected: isSelected
                    )))
                    // Down at once and up over 0.12s. A press is the user's own
                    // action and has already happened by the time it is drawn;
                    // fading into it feels like latency, and fading out of it is
                    // what makes the release read as a release.
                    .animation(Tokens.Motion.press(configuration.isPressed),
                               value: configuration.isPressed)
                    // And the hover step on the same duration, short enough to
                    // read as the card lighting up rather than as a fade.
                    //
                    // The selection plate arrives on this same curve rather than
                    // on a second `.animation` of its own, because `resting` now
                    // folds `isSelected` in: moving the selection changes that
                    // value, so it is already the thing being watched. It is the
                    // same kind of event from the user's side as a hover, and the
                    // Motion list is closed at five.
                    .animation(Tokens.Motion.hover, value: resting)
                    // Held inside the gutter so a hovered card floats rather than
                    // touching the window edge.
                    .padding(.horizontal, Tokens.Space.cardInset)
            )
            // The whole row is the target, including the gaps between its words.
            .contentShape(Rectangle())
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
