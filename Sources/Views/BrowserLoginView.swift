import SwiftUI
import AppKit

/// The one window that connects a service, whichever way that service connects.
///
/// There used to be two. `BrowserLoginView` handled anything with a login page,
/// `AuthSheet` handled MiniMax — the same anatomy at a different width, padding,
/// logo size, headline weight and section spacing, with a "Try browser cookies"
/// button that only the one provider with no cookie flow could ever reach, and
/// instructions chosen by `provider.id == "minimax"`, which quietly gave the
/// generic text to a second account called "minimax#2".
///
/// Everything the dialog shows comes from `ConnectionFlow`: one headline, one
/// detail line, one set of buttons per stage. Nothing here decides what a state
/// means, so the window cannot disagree with the row that opened it.
public struct ConnectDialog: View {
    @StateObject private var flow: ConnectionFlow
    private let onFinish: (Bool) -> Void
    private let onContentResize: () -> Void

    /// Every edge in this window steps up under increased contrast — the rules
    /// between its blocks and the border round each account row. At 0.07 and 0.09
    /// they are the first things a low-contrast display gives up, and they are
    /// the only thing separating the blocks and the only thing bounding a row.
    @Environment(\.colorSchemeContrast) private var contrast

    /// A rule is one device pixel, not one point. `Control.hairline` is the
    /// system's separator thickness and stays that; drawn at 1pt on a 2× display
    /// this window's rules are two pixels of grey, which reads as a soft band
    /// rather than an edge beside the panel header's own rule. So the rules opt
    /// into the display's own hairline, and land on the pixel grid.
    @Environment(\.displayScale) private var displayScale

    /// Every swappable glyph in this window sits in this square — see
    /// `stateBlock`. One value, because two glyph slots of different sizes is two
    /// left edges for the text beside them.
    private static let glyphSlot = Tokens.lineBox(Tokens.Ramp.title)

    /// `onContentResize` is called when the content's height changes — revealing
    /// the token field, or a stage growing a second line. An `NSWindow` does not
    /// follow its content, so without this the field opened underneath the
    /// window's bottom edge and the only way to reach it was to drag the corner.
    ///
    /// Isolated because building the dialog builds its `ConnectionFlow`, which is
    /// main-actor bound. `View` carries that isolation already; saying so here
    /// stops the `StateObject` thunk depending on an inference rule to get it.
    @MainActor
    public init(
        provider: AnyUsageProvider,
        method: ConnectionFlow.Method? = nil,
        onFinish: @escaping (Bool) -> Void,
        onContentResize: @escaping () -> Void = {}
    ) {
        self.onFinish = onFinish
        self.onContentResize = onContentResize
        self._flow = StateObject(wrappedValue: ConnectionFlow(provider: provider, method: method))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            rule
            if !steps.isEmpty {
                stepList
                rule
            }
            statusArea
        }
        .frame(width: Tokens.Control.dialogWidth)
        // The same near-black ground the settings window and the panel stand on,
        // rather than the system's window colour. Not a house preference: the
        // account rows below are `Surface.raised`, whose step above the ground is
        // measured against this base, and over `windowBackgroundColor` in the
        // dark appearance that step inverts — a raised row would read as a well.
        // A window in this app has one of the three planes under it, not a
        // fourth.
        .background(Tokens.Surface.base)
        .onAppear { flow.begin() }
        .onDisappear { flow.cancel() }
        .onChange(of: flow.stage) { stage in
            onContentResize()
            if case .connected = stage {
                // Let the checkmark land before the window disappears.
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    onFinish(true)
                }
            }
        }
        .onChange(of: flow.showsTokenField) { _ in onContentResize() }
    }

    /// The line between the dialog's blocks — headline, steps, status.
    ///
    /// A 1pt `Rectangle` rather than a `Divider`, which is retired from the app:
    /// a `Divider` carries its own material and its own weight, so a window with
    /// two of them had a second rule weight in it that no token named. It was
    /// also the one rule here that did not step up under increased contrast,
    /// because dimming a system control is not the same as reading an opacity.
    /// One weight, one colour, one accessor, the same as the panel header's —
    /// including its thickness, which is one device pixel rather than one point.
    ///
    /// Through `Control.hair(scale:)` rather than the `1 / displayScale` that
    /// used to be written here. Same value at every real scale, so this is a
    /// refactor and not a change; what it buys is that the zero guard has one
    /// home. There were three spellings of "one device pixel" in the app and a
    /// token that had none of them as a call site.
    private var rule: some View {
        Rectangle()
            .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
            .frame(height: Tokens.Control.hair(scale: displayScale))
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(spacing: Tokens.Space.leadingColumn) {
            ProviderLogo(
                providerID: flow.provider.serviceID,
                fallbackName: flow.provider.displayName,
                size: Tokens.Control.dialogLogo,
                // False, always, and not a state to look up: this window is open
                // *because* this service is not reporting. It used to draw the
                // reporting ink at 34pt — the largest mark in the app, at the full
                // weight of a healthy service, on the one surface that exists to
                // say the service is not one. Routed through the resolver rather
                // than writing `Ink.muted` here so the dialog and the panel row
                // behind it stay one decision: 7.34:1 light and 6.75:1 dark on the
                // `Surface.raised` this window draws on.
                ink: AppearanceSettings.shared.markInk(for: flow.provider.serviceID, isLive: false)
            )
            VStack(alignment: .leading, spacing: Tokens.Space.tight) {
                // `Ink.body` rather than the inherited `Color.primary`, which on
                // this window's ground is pure white at 19:1. Every line of type
                // in this file names its ink for that reason, and the captions
                // take `Ink.muted` rather than `.secondary` — a hierarchical
                // style resolves off the system's ramp, not off ours.
                Text(title)
                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                    .foregroundColor(Tokens.Ink.body)
                if let host = flow.provider.webLogin?.startURL.host {
                    // `.regular` said out loud rather than inherited, here and on
                    // every caption in this window: the window has two weights,
                    // and which one a line takes is a decision, not a default.
                    Text(host)
                        .font(.system(size: Tokens.Ramp.detail, weight: .regular))
                        .foregroundColor(Tokens.Ink.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.dialogMargin)
    }

    /// "Sign in" where there is a login to do, "Connect" where the user is
    /// pasting a key they already have.
    private var title: String {
        flow.provider.webLogin == nil
            ? "Connect \(flow.provider.displayName)"
            : "Sign in to \(flow.provider.displayName)"
    }

    // MARK: - Steps

    /// What the user is expected to do, in order. Empty for a pasted key: there
    /// is no browser trip to narrate, and three numbered circles around "paste
    /// your token" is ceremony.
    private var steps: [String] {
        switch flow.method {
        case .session:
            return [
                "aibars opened the login page in \(flow.browser.name).",
                "Log in there as you normally would.",
                "Come back here — aibars picks up the session on its own."
            ]
        case .tokenFromPage:
            return [
                "aibars opened the token page in \(flow.browser.name).",
                "Generate the token and copy it.",
                "Paste it below."
            ]
        case .pastedKey:
            return []
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                StepRow(number: index + 1, text: text)
            }
        }
        .padding(Tokens.Space.dialogMargin)
    }

    // MARK: - Status, picker, entry, controls

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.large) {
            if case .unreadable = flow.stage {
                limitationBanner
            } else {
                stateBlock()
            }

            if !flow.picks.isEmpty {
                picker
            }

            if flow.showsTokenField {
                tokenEntry
            }

            controls
        }
        .padding(Tokens.Space.dialogMargin)
    }

    /// What the stage is, in one block: a glyph, a headline, and at most one
    /// detail line.
    ///
    /// One view for both the ordinary status line and the unreadable-browser
    /// banner, which were two copies of the same anatomy and had already drifted
    /// apart — the banner set its headline a weight above the status line's, so
    /// the same sentence read differently depending on which stage produced it,
    /// and a window with two weights cannot afford a third by accident.
    private func stateBlock(fallbackSymbol: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.medium) {
            // A fixed square, because what sits in it is swapped as the flow
            // moves: a mini `ProgressView`, a tick, a triangle and a shield all
            // measure differently, so sized to its content this slot changed
            // width at every stage change and took the headline sideways with
            // it. Centred in the title's own line box, which puts the glyph on
            // the headline's optical centre rather than on its bounding box.
            ZStack {
                if flow.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else if let symbol = flow.symbol ?? fallbackSymbol {
                    Image(systemName: symbol)
                        // Named rather than inherited, so the glyph is the same
                        // size in the banner as it is on the status line.
                        .font(.system(size: Tokens.Ramp.title))
                        .foregroundStyle(flow.tone.ink)
                }
            }
            .frame(width: Self.glyphSlot, height: Self.glyphSlot)
            VStack(alignment: .leading, spacing: Tokens.Space.tight) {
                Text(flow.headline)
                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                    .foregroundColor(Tokens.Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = flow.detail {
                    Text(detail)
                        .font(.system(size: Tokens.Ramp.detail, weight: .regular))
                        .foregroundColor(Tokens.Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Rows shown before the list starts scrolling, and the height that many
    /// occupy. Six Chrome profiles is an ordinary number, and this window sizes
    /// itself to its content — an unbounded list grows it past the bottom of the
    /// screen and takes its own buttons with it.
    private static let visiblePicks = 5
    private static let pickRowHeight: CGFloat = 36
    private static var pickerHeight: CGFloat {
        CGFloat(visiblePicks) * pickRowHeight + CGFloat(visiblePicks - 1) * Tokens.Space.small
    }

    /// The accounts found, one row each. This is the whole point of the rework:
    /// two Chrome profiles signed into one service is two accounts, and which of
    /// them aibars watches is not a decision the app gets to make quietly.
    @ViewBuilder
    private var picker: some View {
        if flow.picks.count > Self.visiblePicks {
            // An explicit height, because a `ScrollView` has no intrinsic one
            // and the window is measured from its content.
            ScrollView { pickRows }
                .frame(height: Self.pickerHeight)
        } else {
            pickRows
        }
    }

    private var pickRows: some View {
        VStack(spacing: Tokens.Space.small) {
            ForEach(flow.picks) { candidate in
                HStack(spacing: Tokens.Space.medium) {
                    // The same square, and the same named size, as the status
                    // block's glyph: a system glyph's width is a property of the
                    // glyph, and two glyphs measuring themselves put the two
                    // stacks of text in this window on two different rhythms.
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: Tokens.Ramp.title))
                        .foregroundStyle(Tokens.Ink.muted)
                        .frame(width: Self.glyphSlot, height: Self.glyphSlot)
                    Text(candidate.label)
                        .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                        .foregroundColor(Tokens.Ink.body)
                        // A Chromium profile is named by its owner, so this is a
                        // sentence as often as it is a word. Unconstrained it
                        // wraps, and a wrapped row pushes its own Connect button
                        // out of the column the rows above it kept.
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Tokens.Space.medium)
                    // `.bordered` in `Ink.body`, never `.borderedProminent`, and
                    // the same recipe the stage's own button takes — see
                    // `actionButton`. Five accounts found is five buttons, and
                    // five filled ones stacked down a window is a wall; the row's
                    // edge already says this is a thing to pick, so the button
                    // only has to say which way.
                    Button(ConnectionFlow.Action.connectTo(candidate).label) {
                        flow.perform(.connectTo(candidate))
                    }
                    .buttonStyle(.bordered)
                    .tint(Tokens.Ink.body)
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.horizontal, Tokens.Space.large)
                .frame(height: Self.pickRowHeight)
                // A raised surface, not a card: this row is a thing to pick, and
                // the whole point of the picker is that choosing between two
                // Chrome profiles is a decision the app does not get to make
                // quietly. A ground plus one stroke, at the radius a floating
                // surface takes — the app has no shadows and no inner
                // highlights, so an edge is the only elevation there is.
                //
                // `Fill.card` was the wrong plane for it. That is a
                // `Color.primary` opacity over whatever is behind it, which on
                // this window's ground is a 5% lift and a row you have to look
                // for; and a card is what a row at rest in the panel is drawn
                // at, which is the opposite of what this row is.
                .background(Tokens.surface(Tokens.Radius.panel).fill(Tokens.Surface.raised))
                .overlay(
                    Tokens.surface(Tokens.Radius.panel).strokeBorder(
                        Tokens.quiet(Tokens.borderOpacity(increased: contrast == .increased)),
                        lineWidth: Tokens.Control.hairline
                    )
                )
            }
        }
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.small) {
            if flow.needsEndpoint {
                // The caption is the visible label and the field's title is the
                // spoken one, so they say the same thing and only the caption is
                // drawn. Hidden from VoiceOver, which would otherwise read the
                // name twice on the way through the stack.
                Text("Usage endpoint")
                    .font(.system(size: Tokens.Ramp.detail, weight: .regular))
                    .foregroundColor(Tokens.Ink.muted)
                    .accessibilityHidden(true)
                TextField("Usage endpoint", text: $flow.endpoint, prompt: Text("https://api.example.com/usage"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            Text(tokenFieldLabel)
                .font(.system(size: Tokens.Ramp.detail, weight: .regular))
                .foregroundColor(Tokens.Ink.muted)
                .accessibilityHidden(true)
            HStack(spacing: Tokens.Space.medium) {
                SecureField(tokenFieldLabel, text: $flow.pastedToken, prompt: Text("Token…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("Save") { submit() }
                    .buttonStyle(.bordered)
                    .tint(Tokens.Ink.body)
                    // Also off while a save is in flight: Return and a click on
                    // Save are two submissions of the same field, and the second
                    // one saves and verifies a token the first already cleared.
                    .disabled(isSubmitting
                              || flow.pastedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Whether a save is already in flight. Narrower than `flow.isBusy`, which
    /// is "a spinner belongs here" and so covers `.watching` too — and greying
    /// the field out for the whole ten-minute watch would kill the one escape
    /// hatch that stage offers.
    private var isSubmitting: Bool {
        switch flow.stage {
        case .captured, .verifying: return true
        default: return false
        }
    }

    private var tokenFieldLabel: String {
        guard flow.method.isDiscoverable else { return "Paste the token" }
        // Naming the cookie is the difference between a field a user can fill and
        // one they guess at, for the case where automatic capture failed.
        return flow.provider.webLogin?.expectedCookieName
            .map { "Or paste “\($0)” manually" } ?? "Paste the token"
    }

    /// Two rows, not one.
    ///
    /// At its widest — Safari's banner, which carries Full Disk Access, Check
    /// now, Open page again and the manual-entry toggle — a single row of these
    /// wants about 500pt inside a 428pt dialog, and an overflowing `HStack`
    /// squeezes its buttons to ellipses rather than wrapping. The escape-hatch
    /// links sit above the buttons instead, and only when there are any.
    private var controls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            linkRow
            HStack(spacing: Tokens.Space.medium) {
                Spacer(minLength: 0)
                Button(flow.dismissLabel) {
                    flow.cancel()
                    onFinish(flow.didConnect)
                }
                .keyboardShortcut(.cancelAction)
                ForEach(Array(prominentActions.enumerated()), id: \.element.id) { index, action in
                    // Two buttons rather than one with a computed style:
                    // buttonStyle takes a type, so it cannot be picked at runtime
                    // without erasing it, and erasing a button style is a lot of
                    // machinery for one emphasis change.
                    actionButton(action, isPrimary: index == 0)
                }
            }
        }
    }

    private var prominentActions: [ConnectionFlow.Action] {
        flow.actions.filter(\.isProminent)
    }

    private var linkActions: [ConnectionFlow.Action] {
        flow.actions.filter { !$0.isProminent }
    }

    @ViewBuilder
    private var linkRow: some View {
        if !linkActions.isEmpty || flow.offersTokenField {
            HStack(spacing: Tokens.Space.large) {
                // Not the system's link blue: left alone these are a saturated
                // colour in a window whose palette has none to spend, and blue
                // means nothing in this app. They used to take `Ink.arc`, which
                // is deleted with the rest of the third hue, so what marks them
                // as links now is the underline — the channel a link had before
                // it had a colour, and the only one that works for a reader who
                // cannot separate two hues at the same lightness. `.tint` still
                // has to be set, because `.link` colours itself from it.
                ForEach(linkActions) { action in
                    Button(action.label) { flow.perform(action) }
                        .buttonStyle(.link)
                        .tint(Tokens.Ink.body)
                        .underline()
                }
                if flow.offersTokenField {
                    Button(flow.showsTokenField ? "Hide manual entry" : "Paste a token instead") {
                        flow.toggleTokenField()
                    }
                    .buttonStyle(.link)
                    .tint(Tokens.Ink.body)
                    .underline()
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The stage's own button, and the window's one emphasis recipe: `.bordered`
    /// tinted `Ink.body`, never `.borderedProminent`.
    ///
    /// `.borderedProminent` fills with the *user's* accent, and that colour has a
    /// short list of jobs — selected chips, focus rings, the accent ramp — none
    /// of which is chrome. So the dialog spends emphasis once, on whatever the
    /// stage is actually asking for, and the button beside it — Done, Cancel —
    /// stays the plain system bezel, which is the difference between them.
    ///
    /// The tint was `Ink.arc` and the token is deleted. What is being said here
    /// is "this one", not "this is aibars", and the ladder already has a rung for
    /// that: `body` is the loudest neutral, so a bordered button in it reads
    /// heavier than the system bezel beside it without adding a hue the app spends
    /// only on alarm.
    @ViewBuilder
    private func actionButton(_ action: ConnectionFlow.Action, isPrimary: Bool) -> some View {
        if isPrimary {
            Button(action.label) { flow.perform(action) }
                .buttonStyle(.bordered)
                .tint(Tokens.Ink.body)
        } else {
            Button(action.label) { flow.perform(action) }
        }
    }

    /// The same headline and detail as the status line, on a wash, because a browser
    /// whose cookies cannot be read is the one state the user has to deal with
    /// before anything else on screen will work.
    ///
    /// It is `stateBlock` on a wash, and nothing else: same glyph slot, same
    /// headline weight, same detail ink. Written out a second time it drifted
    /// from the status line it is a variant of, and a state that reads heavier
    /// because of which stage produced it is the window disagreeing with itself.
    /// `lock.shield` is only the fallback for the one stage that has no symbol of
    /// its own — the glyph and its colour still come off the flow.
    ///
    /// The wash stays a wash, and stays translucent: `Ink.attentionWash` is the
    /// one named exception to "nothing in this app is drawn on something you can
    /// see through", because it is a tint *over* a surface rather than a material
    /// with a wallpaper behind it — it has to let the ground through or it is a
    /// flat amber panel with black text on it. So this block is not
    /// `Surface.raised` and takes no border: the wash is doing the work an edge
    /// would, and a raised plane under a tint would be two answers to the same
    /// question.
    private var limitationBanner: some View {
        stateBlock(fallbackSymbol: "lock.shield")
            .padding(Tokens.Space.large)
            .background(Tokens.surface(Tokens.Radius.panel).fill(Tokens.Ink.attentionWash))
    }

    private func submit() {
        // Return bypasses the Save button's disabled state, so the guard has to
        // be here too.
        guard !isSubmitting else { return }
        Task { await flow.submitToken() }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.medium) {
            // `titleWeight`, not `.bold`: the window has two weights, and a step
            // number is the least important digit in it — it says what order to
            // read the line in, not what the line says.
            //
            // The badge is the title's own line box rather than the 17pt it was
            // written at: one point off the box the line beside it occupies is a
            // circle that sits a hair low against three lines of type, and 17 is
            // on no scale this app keeps.
            Text("\(number)")
                .font(Tokens.Ramp.figureFont(Tokens.Ramp.caption, weight: Tokens.Ramp.titleWeight))
                .foregroundColor(Tokens.Ink.muted)
                .frame(width: Tokens.lineBox(Tokens.Ramp.title), height: Tokens.lineBox(Tokens.Ramp.title))
                .background(Circle().fill(Tokens.quiet(Tokens.Fill.controlHover)))
            Text(text)
                .font(.system(size: Tokens.Ramp.title, weight: .regular))
                .foregroundColor(Tokens.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Presents `ConnectDialog` in its own small window — the menu bar dropdown has
/// no window of its own to hang a sheet from.
///
/// One window per provider id, so a second account gets its own flow rather than
/// re-entering the first one's.
@MainActor
public enum LoginWindowController {
    private static var windows: [String: NSWindow] = [:]
    /// Where the next window goes. `center()` puts every one of these at the
    /// same point, so a user connecting three services at once gets three
    /// windows that look like one.
    private static var cascade: NSPoint = .zero

    /// Opens the connect flow for any provider, including the ones with no login
    /// page: the pasted-key case is the same window with the field already open,
    /// which is why the settings sheet that used to own it is gone.
    public static func show(provider: AnyUsageProvider, onFinish: @escaping (Bool) -> Void = { _ in }) {
        if let existing = windows[provider.id], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // The title bar's close button does not route through `close(_:)`, so the
        // table can hold a window that is already gone. Reopening that one hands
        // the user the last attempt's finished flow, poll already cancelled, and
        // nothing on screen ever changes again.
        windows[provider.id]?.close()
        windows[provider.id] = nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Tokens.Control.dialogWidth, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = provider.webLogin == nil
            ? "Connect \(provider.displayName)"
            : "Sign in to \(provider.displayName)"
        window.isReleasedWhenClosed = false

        // The Done button and the auto-dismiss that follows a successful connect
        // report the same outcome, and whoever asked for this window answers a
        // report by refreshing every provider. Once is enough.
        var reported = false
        let view = ConnectDialog(
            provider: provider,
            onFinish: { success in
                guard !reported else { return }
                reported = true
                close(provider.id)
                onFinish(success)
            },
            // Reached through the window rather than by capturing the hosting
            // view: the view owns the closure, so capturing it here would be a
            // cycle that outlives the window.
            onContentResize: { [weak window] in
                guard let window, let hosting = window.contentView else { return }
                // The fitting size only settles once SwiftUI has laid the new
                // content out, which has not happened yet inside the change
                // handler that reported it. A `Task` on the main actor rather
                // than `DispatchQueue.main.async`, whose closure is `@Sendable`
                // and so inherits no isolation — `fit` is main-actor work.
                Task { @MainActor in
                    hosting.layoutSubtreeIfNeeded()
                    fit(window, to: hosting.fittingSize)
                }
            }
        )
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        // The banner, the account picker and the manual entry field all change
        // the content's height, so let it size itself — and stay resizable, since
        // a clipped sign-in window would be unrecoverable.
        var initial = hosting.fittingSize
        initial.height = min(initial.height, ceiling(for: nil))
        window.setContentSize(initial)
        window.center()
        cascade = window.cascadeTopLeft(from: cascade)
        windows[provider.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func close(_ providerID: String) {
        windows[providerID]?.close()
        windows[providerID] = nil
        // Back to the middle of the screen once none of them are up, or the
        // cascade walks off the corner over a session's worth of sign-ins.
        if windows.isEmpty { cascade = .zero }
    }

    /// Resizes downward from the title bar rather than up from the bottom edge,
    /// so the headline stays where the user's eye already is.
    private static func fit(_ window: NSWindow, to size: NSSize) {
        var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        target.size.height = min(target.height, ceiling(for: window))
        guard abs(target.height - window.frame.height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size.height = target.height
        window.setFrame(frame, display: true, animate: false)
    }

    /// The tallest this window may become. A self-sizing window has no reason of
    /// its own to stop, and one taller than the screen puts its own buttons below
    /// the bottom edge, where a resizable frame cannot get them back.
    ///
    /// The picker is the only part with no bound of its own, and it scrolls past
    /// five rows — so this is a backstop rather than the mechanism.
    private static func ceiling(for window: NSWindow?) -> CGFloat {
        (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
    }
}
