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
            lines: lines
        )
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
        return lines
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
                isHovered: isHovered
            )
        )
        .onHover { isHovered = $0 }
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
    /// `.firstTextBaseline` rather than `.center`: the name is SF Pro and the
    /// figure is SF Mono, and the two faces put their cap heights in different
    /// places inside the same line box — centring lands them on two baselines a
    /// point apart, which is exactly the kind of thing that reads as sloppy
    /// without being nameable. Everything on the line that has no baseline of its
    /// own — the buttons, a rail glyph, the status dot — is put on the band the
    /// eye reads the line in by `controlBaseline`.
    ///
    /// One size and one weight for both now. The name was set a step heavier than
    /// everything else in the panel and the figure a step larger, which between
    /// them are what made the panel shout; hierarchy on this line is carried by
    /// the face, the reserved rail and the colour, none of which cost loudness.
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
            // disconnected one reclaims the space rather than reserving it for
            // buttons it will never draw.
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
            }

            trailingValue
        }
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
                if parts.count > 1, let first = parts.first {
                    identityRun(first)
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
    /// Muted while a row has nothing to report — loading, or not connected —
    /// and full body ink the moment it does. A failed or expired row keeps the
    /// body ink: it has something to say and is saying it on the line below.
    private var nameTint: Color {
        isLoading || !provider.isAuthenticated ? Tokens.Ink.muted : Tokens.Ink.body
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
                .frame(width: Self.railGlyph, height: Self.railGlyph)
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
        } else if appearance.showsUsageNumber, let percent = primaryPercent {
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
        // and two content-dependent extras that can only add to it.
        if reservesWindowLine { return true }
        guard case .success(let data) = result else { return false }
        if budgetLine(for: data) != nil { return true }
        return !data.secondary.isEmpty
            && appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .expanded
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
                // Under the headline meter and above the further windows,
                // because it is a reading of the headline window and of nothing
                // else. Draws nothing at all — no reserved height — until the
                // samples support a claim, so a row without a forecast is the
                // row it was before this line existed.
                ForecastLine(
                    providerID: provider.id,
                    resetDate: data.primary.resetDate,
                    appearance: appearance,
                    trend: trend
                )
                secondaryWindows(data.secondary)
                // Last, under every window the service itself reports. A budget
                // is the user's number and a quota is the service's, so it is
                // never the headline and never interrupts the ladder of meters
                // above it.
                if let line = budgetLine(for: data) {
                    BudgetMeter(
                        status: line.status,
                        budget: line.budget,
                        spend: line.spend,
                        accent: provider.accentColor,
                        appearance: appearance
                    )
                }
            case .failure(let error):
                // One sentence, on the same line every other row draws its
                // caption on, and no glyph in front of it: the state is in the
                // rail, so the text column has one left edge in every state the
                // row can be in. One line and never two — the eight sentences the
                // panel is allowed to print are each short enough to fit, and
                // whatever the server actually said is in the row's tooltip.
                stated(error.errorDescription ?? "Not reporting")
                sparkline
            }
        } else {
            // Loading, which is the state a real launch spends its first seconds
            // in: connected, asked, nothing back yet. It used to draw a name and
            // nothing else — four mystery rows with a service name in them — and
            // it now occupies exactly the box it will occupy once it reports, so
            // the row does not grow when the answer lands.
            stated("Checking…")
            sparkline
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
        VStack(alignment: .leading, spacing: metrics.captionGap) {
            reservedMeterSlot
            if reservesWindowLine {
                Text(text)
                    .font(.system(size: metrics.detailSize, weight: .regular))
                    .foregroundColor(Tokens.Ink.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: Tokens.lineBox(metrics.detailSize), alignment: .leading)
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
        let run = chipRun(data.secondary, carriesSpend: data.spend != nil)
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
                    reservesLine: reservesWindowLine
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
        VStack(alignment: .leading, spacing: metrics.captionGap) {
            if appearance.meterStyle != .ring {
                MeterSlot(
                    metric: metric,
                    accent: provider.accentColor,
                    appearance: appearance
                )
            }
            line()
        }
    }

    /// The further windows, for the one style that still spends height on them.
    ///
    /// `.chips` draws nothing here: those fold onto the trailing half of the
    /// caption line above and cost no vertical space at all, which is what a
    /// weekly window is worth beside the window the row is actually about. A
    /// second full-width meter per window was 24pt each, nine times down the
    /// panel, and it is what painted every row amber.
    @ViewBuilder
    private func secondaryWindows(_ windows: [UsageMetric]) -> some View {
        if !windows.isEmpty,
           appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .expanded {
            // One line per window, not one meter. A weekly cap you are 80%
            // through still deserves naming and a figure of its own; it does not
            // deserve a second bar the width of the row.
            //
            // On the enclosing VStack's own spacing, with nothing added on top:
            // the pitch from the primary meter to the first secondary one is then
            // the same as the pitch between two secondaries, so the third window
            // of one service sits on the same line as the third of the next.
            VStack(alignment: .leading, spacing: metrics.contentSpacing) {
                ForEach(numbered(windows, limit: appearance.secondaryWindowLimit)) { window in
                    secondaryWindow(window.metric)
                }
            }
        }
    }

    /// The windows the caption line carries, and how many it had no room for.
    /// Empty under every style but `.chips`, which is the only one that puts them
    /// on a line that already exists.
    private func chipRun(
        _ windows: [UsageMetric],
        carriesSpend: Bool
    ) -> (chips: [UsageMetric], overflow: Int) {
        guard !windows.isEmpty,
              appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .chips
        else { return ([], 0) }
        let split = chipSplit(windows.count, carriesSpend: carriesSpend)
        return (Array(windows.prefix(split.shown)), split.hidden)
    }

    private func numbered(_ windows: [UsageMetric], limit: Int) -> [NumberedMetric] {
        windows.prefix(limit).enumerated().map { NumberedMetric(id: $0.offset, metric: $0.element) }
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
    private func chipSplit(_ count: Int, carriesSpend: Bool) -> (shown: Int, hidden: Int) {
        let limit = chipLimit(carriesSpend: carriesSpend)
        guard count > limit else { return (count, 0) }
        let shown = max(1, limit - 1)
        return (shown, count - shown)
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
        let run = chipRun(data.secondary, carriesSpend: data.spend != nil)
        return MetricCaption(
            metric: data.primary,
            isSecondary: false,
            accent: provider.accentColor,
            appearance: appearance,
            spend: data.spend,
            chips: run.chips,
            overflow: run.overflow
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
/// Both runs are SF Mono, and every one of the three call sites frames this in a
/// reserved trailing-aligned rail — the headline rail on the title line, the
/// secondary rail on a caption and under a budget. Mono outside a rail is a
/// column that reflows, which is the whole thing the face was adopted to stop.
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
                .font(.system(size: unitSize, weight: .regular, design: Tokens.Ramp.figureDesign))
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
            .font(.system(size: size, weight: weight, design: Tokens.Ramp.figureDesign))
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
                .font(.system(size: size,
                              weight: Tokens.Ramp.titleWeight,
                              design: Tokens.Ramp.figureDesign))
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

    public init(
        percent: Double,
        height: CGFloat,
        tint: Color,
        isNearCap: Bool = false
    ) {
        self.percent = percent
        self.height = height
        self.tint = tint
        self.isNearCap = isNearCap
    }

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
                    )
                )
            } else {
                Color.clear
            }
        }
        // The slot, whether or not there is anything in it. Both cases are the
        // same height, which is what the row is squared against.
        .frame(height: height)
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

    public init(
        metric: UsageMetric,
        isSecondary: Bool = false,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil,
        spend: SpendReport? = nil,
        chips: [UsageMetric] = [],
        overflow: Int = 0,
        reservesLine: Bool = true
    ) {
        self.metric = metric
        self.isSecondary = isSecondary
        self.accent = accent
        self.spend = spend
        self.chips = chips
        self.overflow = overflow
        self.reservesLine = reservesLine
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    private var metrics: AppearanceSettings.Metrics { appearance.metrics }
    private var caption: MetricCaption {
        MetricCaption(
            metric: metric,
            isSecondary: isSecondary,
            accent: accent,
            appearance: appearance,
            spend: spend,
            chips: chips,
            overflow: overflow
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
            if !isSecondary {
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
/// One implementation and not a `Color.clear` written out at each of the three
/// call sites, because three copies of a reservation is how a reservation comes
/// to disagree with itself.
struct ReservedTextLine: View {
    /// `Metrics.detailSize` — the size of the text this stands in for.
    let size: CGFloat

    var body: some View {
        Color.clear
            .frame(height: Tokens.lineBox(size))
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

    public init(
        metric: UsageMetric,
        isSecondary: Bool = false,
        accent: Color = .accentColor,
        appearance: AppearanceSettings? = nil,
        spend: SpendReport? = nil,
        chips: [UsageMetric] = [],
        overflow: Int = 0
    ) {
        self.metric = metric
        self.isSecondary = isSecondary
        self.accent = accent
        self.spend = spend
        self.chips = chips
        self.overflow = overflow
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
                ViewThatFits(in: .horizontal) {
                    leadingRun(includesCountdown: true, reading: .amount)
                    leadingRun(includesCountdown: false, reading: .amount)
                    leadingRun(includesCountdown: false, reading: .name)
                    leadingRun(includesCountdown: false, reading: .none)
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
    private func leadingRun(includesCountdown: Bool, reading: Reading) -> some View {
        HStack(spacing: Tokens.Space.snug) {
            // Money leads the line when there is any. It is the one figure on the
            // row nothing else says, and the counts behind it are what should give
            // if the line runs out.
            if let spend = shownSpend {
                SpendFigure(spend: spend, size: size)
                    .layoutPriority(1)
            }
            if let text = readingText(reading) {
                amount(text)
            }

            if includesCountdown, appearance.showsCountdowns, let reset = resetText {
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
        }
        // No `fixedSize` here, deliberately: `ViewThatFits` compares each
        // candidate's *ideal* width — the whole string — against the width it is
        // offered, so the choice is already made on the untruncated run. Fixing
        // the size as well would only stop the last candidate from truncating at
        // 300pt, where an unabbreviated count is worth an ellipsis.
    }

    /// What sits at the trailing edge of the line: the further windows on the
    /// headline line, this window's own figure on a secondary one.
    ///
    /// The empty rail the headline line used to hold is kept only where there is
    /// nothing else at the trailing edge. It exists so a countdown stops at the
    /// same x as the figures on the secondary lines under it; with chips on the
    /// line, holding it as well would park them a rail's width in from the row's
    /// own edge, which is the misalignment it was there to prevent.
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
                    .font(.system(size: size,
                                  weight: Tokens.Ramp.titleWeight,
                                  design: Tokens.Ramp.figureDesign))
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
                )
            )

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
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(reading.digits)
                    // A figure, so it takes the figures' rule and not the meter's:
                    // neutral below caution, the ramp from there up. It was reading
                    // `tint`, which is the one thing on the row entitled to carry a
                    // colour at rest — a bar — so four resting chips arrived
                    // coloured on a line of context.
                    .foregroundColor(appearance.figureTint(for: metric.percent,
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
                .font(.system(size: size,
                              weight: Tokens.Ramp.titleWeight,
                              design: Tokens.Ramp.figureDesign))
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
                // And a ceiling above it, at the nine cells `RowGeometry` reserves:
                // a capped count with both halves formatted — Cursor's `1.0k/1.0k`
                // — is the widest reading the formatter can put here in practice
                // and it takes exactly those nine. The floor is clamped under the
                // ceiling rather than stated flat, because a line too narrow to
                // hold a whole chip hands this run less than four cells and a
                // `minWidth` above its own `maxWidth` is not a frame.
                .frame(
                    minWidth: min(runs.reading, Tokens.figureWidth(size, digits: 4)),
                    maxWidth: runs.reading,
                    alignment: .trailing
                )
                // The reading is why the chip is here, so it is the part that
                // must not be abbreviated away.
                //
                // The one SF Mono run in the panel with no rail around it, and
                // the reason is that a chip is not a column: it is sized to what
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
            .font(.system(size: appearance.metrics.detailSize,
                          weight: .regular,
                          design: Tokens.Ramp.figureDesign))
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
                } else {
                    HoverIconButton(
                        systemName: "arrow.clockwise",
                        help: refreshHelp,
                        size: Tokens.Control.rowIconButton,
                        action: onRefresh
                    )
                }
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

    func makeBody(configuration: Configuration) -> some View {
        let resting = Tokens.rowBackground(style, isHovered: isHovered)
        return configuration.label
            .background(
                Tokens.surface(radius)
                    .fill(Tokens.quiet(Tokens.rowBackground(
                        style,
                        isHovered: isHovered,
                        isPressed: configuration.isPressed
                    )))
                    // Down at once and up over 0.12s. A press is the user's own
                    // action and has already happened by the time it is drawn;
                    // fading into it feels like latency, and fading out of it is
                    // what makes the release read as a release.
                    .animation(Tokens.Motion.press(configuration.isPressed),
                               value: configuration.isPressed)
                    // And the hover step on the same duration, short enough to
                    // read as the card lighting up rather than as a fade.
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
