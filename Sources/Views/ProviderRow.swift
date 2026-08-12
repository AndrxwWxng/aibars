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

    @State private var isHovered = false

    public init(
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?,
        onSignIn: @escaping () -> Void,
        onOpenDashboard: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        showsAllWindows: Bool? = nil,
        showsPlanName: Bool? = nil,
        appearance: AppearanceSettings? = nil,
        budgets: BudgetStore? = nil,
        trend: UsageTrendStore? = nil
    ) {
        self.provider = provider
        self.result = result
        self.onSignIn = onSignIn
        self.onOpenDashboard = onOpenDashboard
        self.onRefresh = onRefresh
        self.showsAllWindows = showsAllWindows
        self.showsPlanName = showsPlanName
        // Resolved here rather than as default arguments: a default argument is
        // evaluated at the call site, and all three shared objects are
        // main-actor isolated, so that would constrain who is allowed to build
        // a row.
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
        self.budgets = budgets ?? BudgetStore.shared
        self.trend = trend ?? UsageTrendStore.shared
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
    private var geometry: RowGeometry { rowGeometry(lines: lines) }

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
    private var lines: RowGeometry.Lines {
        // Still loading: nothing under the title at all. The name drawn muted is
        // the whole of the pending cue and it costs no pixels, where a spinner
        // and the word "Loading…" cost a reserved line — eleven of them on a
        // fresh launch, which is a very tall panel of almost nothing.
        if isLoading { return [] }
        // Not connected, or an error: one line under the title, and no meter over
        // it to report a window nobody has read yet.
        guard provider.isAuthenticated, case .success(let data) = result else { return .window }
        var lines: RowGeometry.Lines = .meter
        // A quotaless service says everything it has to say on its status line,
        // so that one is never absent; a metered window's caption can be
        // switched off down to nothing — unless a chip is riding on it.
        if data.primary.limit > 0 {
            if primaryCaption(data).hasContent { lines.insert(.window) }
        } else {
            lines.insert(.window)
        }
        return lines
    }

    /// Connected, asked, and nothing back yet.
    private var isLoading: Bool { provider.isAuthenticated && result == nil }

    /// Connected and answering: the one state whose brand mark is drawn at full
    /// strength. Loading, an error and a locked session all dim it, which is the
    /// leading column's share of "this row is not reporting right now".
    private var isLive: Bool {
        guard provider.isAuthenticated, case .success = result else { return false }
        return true
    }

    /// A credential the user has to go and fix, as opposed to a request that
    /// simply failed. The two ask for different things and the row says so
    /// differently: this one carries a lock in the figure rail and no glyph on
    /// its message, the other a warning triangle in front of the message.
    private var needsUser: Bool { failure?.isAuth == true }

    public var body: some View {
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
        .background(card)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            provider.isAuthenticated ? onOpenDashboard() : onSignIn()
        }
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

    // MARK: - The card

    /// The row's own plane, and the only thing drawn behind the content.
    ///
    /// Drawn at `RowGeometry.cardRadius` rather than at `Radius.row`: 8pt is
    /// right for a 65pt cozy row and eats the corners of a 39pt loading one.
    ///
    /// The coloured spine that used to sit on this card is gone. It was the only
    /// vertical coloured element in the panel and its meaning could not be read
    /// without documentation; near-cap keeps three channels without it, and a row
    /// that wants the user now says so on its own line, with a lock in the figure
    /// rail.
    private var card: some View {
        Tokens.surface(geometry.cardRadius)
            .fill(Tokens.quiet(Tokens.rowBackground(appearance.rowBackground, isHovered: isHovered)))
            // The one thing in the row that animates on the pointer. Short enough
            // to read as the card lighting up rather than as a fade.
            .animation(.easeOut(duration: 0.12), value: isHovered)
            // Held inside the gutter so a hovered card floats rather than touching
            // the window edge.
            .padding(.horizontal, Tokens.Space.cardInset)
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
    private var rowHelp: String {
        guard provider.isAuthenticated else { return "Sign in to \(provider.displayName)" }
        let action = provider.dashboardURL != nil
            ? "Open \(provider.displayName) usage page"
            : "\(provider.displayName) has no usage page"
        guard let reading = preciseReading else { return action }
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
                    ProviderLogo(
                        providerID: provider.serviceID,
                        fallbackName: provider.displayName,
                        fallbackColor: provider.accentColor,
                        size: appearance.logoSize,
                        showsTile: appearance.logoStyle == .tile
                    )
                    // Full colour only while the row is actually reporting. A
                    // loading, failed, locked or disconnected service is dimmed
                    // the same amount, because from the reader's side those are
                    // one state: this row is not telling me anything yet.
                    .opacity(isLive ? 1 : Tokens.Dim.disconnected)
                }

                if appearance.meterStyle == .ring {
                    // Drawn even with nothing to report, so the text column
                    // starts at the same x on every row of the panel. Under the
                    // ring this dial is also the row's occupied meter slot: it
                    // is the one element every row draws whatever it has to say.
                    UsageRing(
                        percent: primaryPercent ?? 0,
                        diameter: metrics.ringDiameter,
                        thickness: metrics.barHeight,
                        tint: tint(for: primaryPercent ?? 0),
                        isNearCap: Self.isNearCap(
                            percent: primaryPercent ?? 0,
                            warning: appearance.warningThreshold
                        )
                    )
                    // Held to the same geometry, but dimmed to the logo's own
                    // disconnected weight when it is only a placeholder. A dial
                    // is the one element at the same x on every row, which is
                    // what makes the panel scannable — drawn at full strength
                    // with an empty track it reports "nothing is being used" for
                    // a row that is disconnected, loading, failed or has no
                    // quota at all. Opacity rather than a shorter column: the
                    // text beside it must not shift as a reading arrives.
                    .opacity(primaryPercent == nil ? Tokens.Dim.disconnected : 1)
                    // A dial is a shape and says nothing on its own, so it is
                    // made an element and given its reading — but only where
                    // there is one. The placeholder above would otherwise
                    // announce "0% used" on every disconnected row.
                    .accessibilityElement()
                    .accessibilityLabel("Usage")
                    .accessibilityValue(ringValue)
                    .accessibilityHidden(primaryPercent == nil)
                }
            }
            .padding(.top, Tokens.Space.hairline)
        }
    }

    // MARK: - Title

    /// The name, the account, the plan, the buttons and the figure, on one
    /// baseline.
    ///
    /// `.firstTextBaseline` rather than `.center`: the name is SF Pro and the
    /// figure is SF Mono, and the two faces put their cap heights in different
    /// places inside the same line box — centring lands them on two baselines a
    /// point apart, which is exactly the kind of thing that reads as sloppy
    /// without being nameable. The leading column keeps its own 1pt nudge onto
    /// the cap-height band.
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
                .foregroundStyle(nameTint)
                .lineLimit(1)
                // The name is the one thing the row cannot be read without, so
                // it takes its width before the account label and the pill.
                .layoutPriority(1)

            // With several accounts of one service, the name alone is the same
            // word repeated — say which account it is.
            if appearance.showsAccountLabels, let account = accountLabel {
                Text(account)
                    .font(.system(size: metrics.detailSize))
                    .foregroundStyle(Tokens.Ink.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }

            if showsPlan, let plan = planName {
                Text(plan)
                    .font(.system(size: metrics.detailSize))
                    // A pill that wraps to a second line stops being a pill.
                    .lineLimit(1)
                    .padding(.horizontal, Tokens.Space.small)
                    .padding(.vertical, Tokens.Space.hairline)
                    // The one pill left in the panel, and a rounded rectangle
                    // rather than a capsule: nothing in the chrome is above 10pt
                    // of radius, and a capsule on a 16pt box is 8 by accident
                    // rather than by choice.
                    .background(Tokens.surface(Tokens.Radius.chip).fill(Tokens.quiet(Tokens.Fill.pill)))
                    .foregroundStyle(Tokens.Ink.muted)
            }

            Spacer(minLength: Tokens.Space.medium)

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
                .alignmentGuide(.firstTextBaseline, computeValue: controlBaseline)
            }

            trailingValue
        }
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
    /// and full body ink the moment it does. A failed or locked row keeps the
    /// body ink: it has something to say and is saying it on the line below.
    private var nameTint: Color {
        isLoading || !provider.isAuthenticated ? Tokens.Ink.muted : Tokens.Ink.body
    }

    /// The figure rail, present in every state the row can be in: connected,
    /// loading, failed, status-only and not connected at all.
    ///
    /// This is the invariant the whole panel is squared against — tabular digits
    /// fix the width of a digit, not the length of a string, so "9%" still
    /// reflows to "92%" unless the column is reserved. Nothing shifts as
    /// readings arrive and drop out, and every reading in the panel ends at one
    /// x.
    @ViewBuilder
    private var trailingValue: some View {
        if !provider.isAuthenticated {
            Button(action: onSignIn) {
                Text("Sign in")
                    .font(.system(size: metrics.detailSize, weight: Tokens.Ramp.emphasisWeight))
                    // The app's own colour, which is where a link or an
                    // invitation is allowed to carry hue. The chrome around it
                    // stays monochrome.
                    .foregroundStyle(Tokens.Ink.arc)
                    // The one control on a disconnected row, so it is the last
                    // thing that should give: a crowded title line otherwise
                    // squeezes it to "Si…".
                    .fixedSize()
            }
            // Plain, not bordered. First launch is eleven disconnected rows, and
            // eleven bordered buttons is a wall rather than a call to action; one
            // accent-coloured word per row is an invitation. The whole row is
            // already a sign-in target with a tooltip saying so, and this is the
            // second way to reach it, not the only one.
            .buttonStyle(.plain)
            // The rail is a floor here rather than a width: a word is wider than
            // three digits, and this row has no reading to line up with anyway.
            .frame(minWidth: geometry.headlineRail, alignment: .trailing)
        } else if needsUser {
            // The channel that makes "this one needs you" survive greyscale now
            // that the spine is gone, and it names the row's own state on the
            // row's own line rather than in a margin nobody can decode.
            Image(systemName: "lock.fill")
                .font(.system(size: metrics.detailSize))
                .foregroundStyle(Tokens.Ink.attention)
                .frame(width: geometry.headlineRail, alignment: .trailing)
                .accessibilityLabel("Session expired")
        } else if appearance.showsUsageNumber, let percent = primaryPercent {
            UsageFigure(
                percent: percent,
                size: metrics.figureSize,
                unitSize: metrics.unitSize,
                // The weight channel of the near-cap contract. The only place in
                // the panel that goes heavier than `emphasisWeight`, so the
                // change is unambiguous — and it survives greyscale, which the
                // tint below does not.
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
        } else {
            // Loading, failed, status-only, or the number switched off. The rail
            // stands empty rather than closing up.
            Color.clear
                .frame(width: geometry.headlineRail, height: 0)
                .accessibilityHidden(true)
        }
    }

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
    private var drawsDetail: Bool {
        // A loading row is a name and an empty rail beside a mark, which is
        // exactly the one-line case centring is here for.
        if isLoading { return false }
        // "Not connected" and an error are each a line of their own.
        guard provider.isAuthenticated, case .success(let data) = result else { return true }
        // Every style but the ring draws its meter in the text column, and that
        // slot is now occupied on every row — a quota, a reading of zero and a
        // service that reports no quota at all each fill it with something.
        guard appearance.meterStyle == .ring else { return true }
        // Under the ring the dial is the meter, so the text column can still be
        // empty. A quotaless provider gets its status line either way.
        guard data.primary.limit > 0 else { return true }
        if primaryCaption(data).hasContent { return true }
        if budgetLine(for: data) != nil { return true }
        return !data.secondary.isEmpty
            && appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .expanded
    }

    @ViewBuilder
    private var detailContent: some View {
        if !provider.isAuthenticated {
            // One prompt for both kinds of service. The branch for a provider
            // with no web login used to read "Not connected — add a token in
            // Settings", which was the longest line in the panel, wrapped to two
            // and so made one row taller than its neighbours — to say something
            // that stopped being true when the connect window learned to take a
            // pasted key. Every disconnected row is reached the same way now, by
            // the button beside this line.
            Text("Not connected")
                .font(.system(size: metrics.detailSize))
                .foregroundStyle(Tokens.Ink.muted)
                .lineLimit(1)
                .frame(minHeight: Tokens.lineBox(metrics.detailSize), alignment: .leading)
        } else if let result {
            switch result {
            case .success(let data):
                primaryMetric(data)
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
                HStack(alignment: .top, spacing: Tokens.Space.small) {
                    // Only the request that failed outright gets a glyph. A
                    // credential the user has to go and fix already carries its
                    // mark in the figure rail, and two marks for one state is a
                    // row shouting the same thing twice.
                    if !error.isAuth {
                        Image(systemName: "exclamationmark.triangle.fill")
                            // Drawn at the size of the sentence it introduces
                            // rather than at the caption scale under it. A glyph
                            // smaller than its own text reads as a bullet.
                            .font(.system(size: metrics.detailSize))
                            .foregroundStyle(Tokens.Ink.failure)
                    }
                    Text(error.errorDescription ?? "Error")
                        .font(.system(size: metrics.detailSize))
                        .foregroundStyle(Tokens.Ink.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: Tokens.lineBox(metrics.detailSize), alignment: .leading)
            }
        }
        // Loading draws nothing at all. The word "Loading…" is not lost — the
        // header summary already says what the panel is doing, which is where a
        // quiet UI puts an indeterminate state, and the app's one spinner lives
        // there too. What is lost is a reserved line and a reserved spinner box
        // on every row of a fresh launch.
    }

    @ViewBuilder
    private func primaryMetric(_ data: UsageData) -> some View {
        let metric = data.primary
        let run = chipRun(data.secondary)
        if metric.limit > 0 {
            switch appearance.meterStyle {
            case .bar, .numberOnly:
                // One view for both, because the difference between them is what
                // fills the meter slot rather than whether there is one: a bar
                // draws a track, a bare number draws the hairline that stands in
                // for it. Row height stops being a function of the setting.
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
                    overflow: run.overflow
                )
            case .ring:
                // The dial in the leading column and the trailing percentage
                // are the meter here; only the context line is left to draw,
                // and with both its halves switched off the row is one line.
                let line = primaryCaption(data)
                if line.hasContent { line }
            }
        } else {
            // A service that reports a state rather than a quota. The slot is
            // still occupied, by a hairline with no track behind it: "reports no
            // quota" and "is at 0%" are different statements and the panel has
            // to be able to tell them apart at a glance.
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
    private func chipRun(_ windows: [UsageMetric]) -> (chips: [UsageMetric], overflow: Int) {
        guard !windows.isEmpty,
              appearance.secondaryWindowStyle(overriddenBy: showsAllWindows) == .chips
        else { return ([], 0) }
        let split = chipSplit(windows.count)
        return (Array(windows.prefix(split.shown)), split.hidden)
    }

    private func numbered(_ windows: [UsageMetric], limit: Int) -> [NumberedMetric] {
        windows.prefix(limit).enumerated().map { NumberedMetric(id: $0.offset, metric: $0.element) }
    }

    /// How many chips the line holds, and the user's own ceiling on top of it.
    ///
    /// The width half of that is `RowGeometry`'s, which owns the chip's furniture
    /// and its two reserved runs. `RowGeometry.chipLimit` deliberately does not
    /// clamp upward, because the ceiling is not a measurement: a stepper set to
    /// six windows says how many the user wants to see, not how many fit. This is
    /// the only place the two ends meet.
    private var chipLimit: Int {
        min(
            appearance.secondaryWindowLimit,
            RowGeometry.chipLimit(
                // Off `rowGeometry(lines:)` rather than `geometry`, for the reason
                // written there: this is asked while the row is still working out
                // which lines it has, and the width does not depend on them.
                textColumnWidth: rowGeometry(lines: []).textColumnWidth,
                captionSize: metrics.captionSize
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
    private func chipSplit(_ count: Int) -> (shown: Int, hidden: Int) {
        let limit = chipLimit
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
        let run = chipRun(data.secondary)
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
            : Tokens.Ramp.emphasisWeight
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
    /// says so with a lock in its own figure rail. The pace riser, and with it
    /// "the fill has crossed the boundary", was one drawing standing in for a
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
        weight: Font.Weight = Tokens.Ramp.emphasisWeight,
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
                .foregroundStyle(Tokens.Ink.muted)
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
            .foregroundStyle(tint)
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
/// The amount holds a rail of its own, which is the one rail money is allowed:
/// eight cells, `$1234.56`. It leads the caption line, so without it `$3.40` and
/// `$32.84` on two rows would start the counts beside them at two different x —
/// and money is the one figure in the panel that keeps its decimals, which is
/// exactly the digit that ticks.
struct SpendFigure: View {
    let spend: SpendReport
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.snug) {
            Text(spend.display)
                .font(.system(size: size,
                              weight: Tokens.Ramp.emphasisWeight,
                              design: Tokens.Ramp.figureDesign))
                .foregroundStyle(Tokens.Ink.muted)
                .lineLimit(1)
                // Trailing, like every other rail, so the decimals line up down
                // the panel. A floor rather than a width, as the sign-in button
                // takes the headline rail as a floor: eight cells hold every
                // amount a subscription panel realistically reports, and a bill
                // that needs a ninth gets it. Fixing the width instead would put
                // an ellipsis in the middle of a figure, and "$1,23…" is not a
                // smaller number, it is no number at all.
                .frame(minWidth: Tokens.moneyWidth(size), alignment: .trailing)
            if spend.confidence == .estimated {
                // The same ink as the amount it qualifies. A third grey below the
                // caption grey was a rank the panel does not have, and `.tertiary`
                // is off the ladder entirely now.
                Text("est.")
                    .font(.system(size: size))
                    .foregroundStyle(Tokens.Ink.muted)
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
                    .frame(width: fillWidth(in: geo.size.width))
            }
        }
        .frame(height: height)
        // The fill's width is the reading changing and is worth watching; its ink
        // is a threshold being crossed and is not. A bar that cross-faded grey to
        // amber over a third of a second would turn the one event the panel exists
        // to report into a mood.
        .animation(.easeOut(duration: 0.30), value: percent)
        .animation(nil, value: tint)
    }

    /// A nonzero value never rounds away to nothing, but the floor is the bar's
    /// own height rather than a fixed 3pt — at 12pt thickness a 3pt fill is a
    /// squashed sliver. Clamped to the track above, because a budget's fraction
    /// can exceed 1 and a fill wider than its track is not a reading.
    private func fillWidth(in width: CGFloat) -> CGFloat {
        guard percent > 0, percent.isFinite, width > 0 else { return 0 }
        return min(width, max(height, width * min(percent, 1)))
    }
}

/// The row's meter slot, which is always occupied.
///
/// Row height stops being a function of a setting and of whether a reading
/// arrived: a quota draws its track, a reading of zero draws a full empty track,
/// a bare-number panel draws the rule that stands in for a meter, and a service
/// that publishes no quota at all draws the same rule with no track behind it.
///
/// That last distinction is the whole point. A hairline says this service
/// reports no quota; an empty track says it reports 0%. They are different
/// statements and the panel has to be able to make both.
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
    /// leading column is — a caller drawing one of those should not place a slot
    /// here at all, and if it does, it gets the rule rather than a second meter.
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
                // Centred in the slot rather than filling it, so a status-only
                // row's caption sits on the same baseline as a metered row's.
                Rectangle()
                    .fill(Tokens.Meter.hairline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Tokens.Control.hairline)
            }
        }
        // The slot, whatever is in it. Both cases are the same height, which is
        // what the row is squared against.
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
            if caption.hasContent { caption }
        }
        // The meter says nothing out loud — the fill fraction is the whole
        // reading, so it is spoken as the meter's value. Clamped, because an
        // overage would otherwise announce "137% used".
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((min(max(metric.percent, 0), 1) * 100).rounded()))% used")

        // The caption's own text is the label whenever one is drawn, and naming
        // the bar here would throw the amounts and the countdown away. With both
        // halves of the caption switched off there is no text left, so then — and
        // only then — the window names itself.
        if caption.hasContent {
            bar
        } else {
            bar.accessibilityLabel(metric.label)
        }
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

    private var fill: Double { min(max(percent, 0), 1) }

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
        .animation(.easeOut(duration: 0.30), value: percent)
        .animation(nil, value: tint)
    }

    /// `strokeBorder` insets the track for us; a trimmed path has to be inset by
    /// hand or the arc overhangs it.
    private func arc(to end: Double, colour: Color, cap: CGLineCap) -> some View {
        Circle()
            .inset(by: stroke / 2)
            .trim(from: 0, to: end)
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
        HStack(spacing: Tokens.Space.snug) {
            if isSecondary {
                Text(metric.label)
                    .font(.system(size: size))
                    .foregroundStyle(Tokens.Ink.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // Money leads the line when there is any. It is the one figure
                // on the row nothing else says, and the counts behind it are
                // what should truncate if the line runs out.
                if let spend = shownSpend {
                    SpendFigure(spend: spend, size: size)
                        .layoutPriority(1)
                }
                if appearance.showsAmounts, !amountText.isEmpty {
                    amount(amountText)
                }

                if appearance.showsCountdowns, let reset = resetText {
                    // Two facts about one window, so they are separated the way
                    // the panel separates everything else — a middle dot, in the
                    // same ink. Without it "5h session resets in 1h 19m" reads as
                    // one sentence with a word missing, which is what four points
                    // of space says at 11pt.
                    if leadsCountdown { separator }
                    // A run with a word in it, so SF Pro with tabular digits
                    // rather than the figure face. Full mono on "resets in 1h 20m"
                    // is the terminal pastiche the direction rules out.
                    //
                    // The window line is one rank however many parts it has: the
                    // counts and the countdown are both the provider stating a
                    // fact about this window, and a third ink to separate two
                    // facts of equal standing is a hierarchy the row does not
                    // have.
                    Text(reset)
                        .font(.system(size: size))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Ink.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Tokens.Space.medium)

            trailing
        }
        .frame(minHeight: Tokens.lineBox(size))
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
                appearance: appearance
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
            .font(.system(size: size))
            .foregroundStyle(Tokens.Ink.muted)
            .accessibilityHidden(true)
    }

    /// A raw count is a run with a unit or a slash in it, and often a word, so
    /// it is SF Pro with tabular digits — the rule is the run, not the number.
    private func amount(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size))
            .monospacedDigit()
            .foregroundStyle(Tokens.Ink.muted)
            .lineLimit(1)
    }

    private var rail: CGFloat { appearance.metrics.secondaryRail }

    private var shownSpend: SpendReport? { isSecondary ? nil : spend }

    /// For percentage metrics the number is already in the trailing rail, so
    /// the line names the window instead of repeating "47 / 100".
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
///
/// Only ever placed inside a successful reading of a connected service, which is
/// what entitles the dot below to be green.
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
        HStack(spacing: Tokens.Space.small) {
            // The one green dot the panel is allowed, and it is doing real work:
            // a service with no quota has no meter to prove the connection is up,
            // so the dot is the proof. A row carrying a percentage has already
            // proved it, which is why there is no dot there — a green dot beside
            // 92% is redundant ink.
            //
            // Unconditional, because this line is only ever reached inside a
            // successful fetch for a connected service. Gating it on `used > 0`
            // read the dot as a usage reading and drew Copilot's "Active" grey on
            // a connection that is working perfectly.
            Circle()
                .fill(Tokens.Ink.ok)
                .frame(width: Tokens.Control.dot, height: Tokens.Control.dot)
            Text(text)
                .font(.system(size: size))
                .monospacedDigit()
                .foregroundStyle(Tokens.Ink.muted)
                .lineLimit(1)

            if let spend {
                SpendFigure(spend: spend, size: size)
                    .layoutPriority(1)
            }

            // Trailing, like every other countdown in the panel, so a quotaless
            // row's renewal date sits in the same column as the reset date on
            // the metered row above it.
            if appearance.showsCountdowns,
               let reset = metric.resetDate,
               let countdown = Countdown.short(until: reset) {
                Text("renews in \(countdown)")
                    .font(.system(size: size))
                    .monospacedDigit()
                    // One rank, like every other window line: it is the same
                    // statement the metered row above makes, about a window with
                    // no ceiling on it.
                    .foregroundStyle(Tokens.Ink.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: Tokens.Space.medium)

            if !chips.isEmpty || overflow > 0 {
                SecondaryChipRun(
                    chips: chips,
                    overflow: overflow,
                    accent: accent,
                    appearance: appearance
                )
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
                .font(.system(size: size))
                .foregroundStyle(Tokens.Ink.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Tokens.Space.medium)
            // Governed by showsAmounts like every other raw count, but the
            // label stays: a bare window name is still a window this service
            // reports, and dropping the line would hide that.
            if appearance.showsAmounts {
                Text(value)
                    .font(.system(size: size,
                                  weight: Tokens.Ramp.emphasisWeight,
                                  design: Tokens.Ramp.figureDesign))
                    .foregroundStyle(Tokens.Ink.muted)
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

    private var value: String {
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
                    .font(.system(size: size))
                    .foregroundStyle(Tokens.Ink.muted)
                    .lineLimit(1)
                    .layoutPriority(1)
                // A run with a word in it, so SF Pro with tabular digits.
                Text(remainingText)
                    .font(.system(size: size))
                    .monospacedDigit()
                    .foregroundStyle(status.isOver ? Tokens.Ink.attention : Tokens.Ink.muted)
                    .lineLimit(1)

                Spacer(minLength: Tokens.Space.medium)

                if status.includesEstimates {
                    // The figure beside this rests on arithmetic this app did,
                    // not on a bill. Saying so is the difference between a
                    // reading and a guess.
                    Text("est.")
                        .font(.system(size: size))
                        .foregroundStyle(Tokens.Ink.muted)
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
struct SecondaryChipRun: View {
    let chips: [UsageMetric]
    let overflow: Int
    let accent: Color
    let appearance: AppearanceSettings

    var body: some View {
        HStack(spacing: Tokens.Space.medium) {
            ForEach(numbered) { window in
                SecondaryChip(metric: window.metric, accent: accent, appearance: appearance)
            }
            if overflow > 0 {
                OverflowChip(count: overflow, appearance: appearance)
            }
        }
        .fixedSize()
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
        HStack(spacing: Tokens.Space.snug) {
            // Two runs, not one: the window's name is a word and the reading
            // beside it is digits and separators, and each takes its own face.
            Text(metric.label)
                .font(.system(size: size))
                .foregroundStyle(Tokens.Ink.muted)
                // Four chips of a long-named window overflow a 300pt panel;
                // truncating one label is better than pushing the last chip
                // off the edge.
                .lineLimit(1)
                .truncationMode(.tail)
            Text(figure)
                .font(.system(size: size,
                              weight: Tokens.Ramp.emphasisWeight,
                              design: Tokens.Ramp.figureDesign))
                .foregroundStyle(appearance.tint(for: metric.percent, providerAccent: accent))
                .lineLimit(1)
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

    private var figure: String {
        if metric.unit == "%" || metric.limit == 100 {
            return "\(Int(metric.used.rounded()))%"
        }
        return "\(metric.displayUsed)/\(metric.displayLimit)"
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
                          design: Tokens.Ramp.figureDesign))
            .foregroundStyle(Tokens.Ink.muted)
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
    public let refreshHelp: String
    public let onRefresh: () -> Void
    public let onOpenDashboard: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

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
