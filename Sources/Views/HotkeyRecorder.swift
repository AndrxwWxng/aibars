import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A field that records one key combination.
///
/// A local `NSEvent` monitor rather than a first-responder `NSView`, and the
/// difference matters: a local monitor sees the event before it is dispatched to
/// the window, so returning nil swallows it — which is what stops Space and
/// Return from re-triggering the button the user just clicked to start
/// recording, and what stops ⌘W closing the settings window mid-record.
///
/// It is process-wide while it is installed, which is why it is installed for as
/// short a time as possible: it goes in when recording starts, comes out when a
/// combination lands, when Escape is pressed, when the view goes away, and when
/// the settings window stops being key. A monitor left behind is an app that has
/// stopped responding to its own keyboard.
public struct HotkeyRecorder: View {
    /// The combination currently bound, or nil.
    public let combo: KeyCombo?
    /// Called with the new combination, or nil to clear it.
    public let onRecord: (KeyCombo?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: KeyComboRejection?
    /// Read once when recording starts rather than at each keystroke: the parse
    /// walks a plist of a hundred-odd entries, and the user is not going to
    /// change their Spotlight shortcut in the two seconds this is open.
    @State private var systemShortcuts: Set<KeyCombo> = []
    @State private var isHovered = false

    public init(combo: KeyCombo?, onRecord: @escaping (KeyCombo?) -> Void) {
        self.combo = combo
        self.onRecord = onRecord
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: Tokens.Space.tight) {
            HStack(spacing: Tokens.Space.small) {
                field
                // Only when there is something to clear. A permanently visible
                // Clear beside an empty field is a control that does nothing.
                if combo != nil && !isRecording {
                    Button("Clear") { onRecord(nil) }
                        .controlSize(.small)
                        .help("Removes the shortcut. aibars keeps opening from the menu bar.")
                }
            }
            if let rejection {
                Text(rejection.note)
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                    .foregroundStyle(Tokens.Ink.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A monitor is process-wide, so it cannot be allowed to outlive the view
        // that owns it — a settings window closed mid-record would otherwise
        // leave the app swallowing every keystroke it receives.
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stop()
        }
    }

    private var field: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(label)
                // SF Pro, not `Ramp.figureDesign`, and this follows the rule
                // written on that token rather than departing from it: a run
                // containing a word is SF Pro, and this run says `Space`, `F12`
                // and `Record…`. The column discipline mono would buy is bought
                // here by the fixed frame instead.
                .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                .foregroundStyle(isRecording ? Tokens.Ink.muted : Tokens.Ink.body)
                .lineLimit(1)
                .frame(
                    width: Tokens.Control.recorderWidth,
                    height: Tokens.Control.recorderHeight
                )
                .background(Tokens.surface(Tokens.Radius.control).fill(
                    Tokens.quiet(isHovered && !isRecording ? Tokens.Fill.controlHover : Tokens.Fill.card)
                ))
                .overlay(
                    Tokens.surface(Tokens.Radius.control).strokeBorder(
                        Tokens.quiet(isRecording
                                     ? Tokens.Control.recorderListeningBorder
                                     : Tokens.borderOpacity(increased: false)),
                        lineWidth: Tokens.Control.hairline
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isRecording
              ? "Press the combination. Escape cancels, Delete clears."
              : "Click, then press the combination that should open aibars.")
        // The field's whole content is a glyph run VoiceOver reads as
        // punctuation, so the combination is spelled out here instead.
        .accessibilityLabel("Shortcut to open aibars")
        .accessibilityValue(combo.map(Self.spoken) ?? "none")
    }

    /// `Record…` and not an empty box: a bordered rectangle with nothing in it is
    /// a field waiting to be typed into, and this one cannot be typed into.
    private var label: String {
        if isRecording { return "Press keys…" }
        return combo?.glyphs ?? "Record…"
    }

    @MainActor
    private func start() {
        rejection = nil
        systemShortcuts = SystemShortcuts.enabled()
        // The bound combination has to reach this recorder rather than the panel,
        // or re-recording the shortcut you already have opens the panel on top of
        // the window you are recording in.
        GlobalHotkey.shared.suspend()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            // Always swallowed. Anything that reaches the responder chain from
            // here is a keystroke acting on the settings window while the user
            // believed they were recording it.
            return nil
        }
    }

    /// Guarded rather than unconditional because three separate things call it —
    /// the button, `onDisappear` and the resign-key notification — and only the
    /// first suspend has a resume owed to it.
    @MainActor
    private func stop() {
        guard isRecording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        GlobalHotkey.shared.resume()
    }

    @MainActor
    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(KeyCombo.recordedFlags)
        let keyCode = event.keyCode

        // Escape cancels and keeps whatever was bound, which is why it can never
        // be recorded — a recorder with no way out traps the user in a field.
        if keyCode == UInt16(kVK_Escape), flags.isEmpty {
            rejection = nil
            return stop()
        }
        // Delete clears. Naked, so ⌥⌫ is still recordable as a shortcut.
        if keyCode == UInt16(kVK_Delete), flags.isEmpty {
            rejection = nil
            onRecord(nil)
            return stop()
        }

        let candidate = KeyCombo(keyCode: keyCode, modifiers: flags)
        if let reason = KeyComboPolicy.rejection(for: candidate, systemShortcuts: systemShortcuts) {
            // Stays open on a rejection. Closing would make the user click the
            // field again between every attempt, and the note under it is only
            // useful while they can act on it.
            rejection = reason
            return
        }
        rejection = nil
        onRecord(candidate)
        stop()
    }

    /// The combination in words, for VoiceOver. "⌃⌥⌘A" is read as three unnamed
    /// symbols and a letter.
    private static func spoken(_ combo: KeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.control) { parts.append("Control") }
        if combo.modifiers.contains(.option)  { parts.append("Option") }
        if combo.modifiers.contains(.shift)   { parts.append("Shift") }
        if combo.modifiers.contains(.command) { parts.append("Command") }
        parts.append(KeyGlyphs.label(for: combo.keyCode) ?? "unknown key")
        return parts.joined(separator: " ")
    }
}

/// The panel's global shortcut, as a `Section` the General tab drops into its
/// own `Form`.
///
/// Under Launch at Login and above Refresh, which is the order of the questions
/// rather than of the code: both of those rows are about *getting to* the app —
/// is it running, and how do I open it — while the interval below is about the
/// data once you are looking at it.
public struct KeyboardShortcutSection: View {
    @ObservedObject private var hotkey: GlobalHotkey

    /// Resolved in the init body rather than as a default argument, for the same
    /// reason `LaunchAtLoginSection` does it: `shared` is main-actor isolated and
    /// a default argument is evaluated at the call site.
    public init(hotkey: GlobalHotkey? = nil) {
        self._hotkey = ObservedObject(wrappedValue: hotkey ?? GlobalHotkey.shared)
    }

    public var body: some View {
        Section {
            LabeledContent("Open aibars") {
                HotkeyRecorder(combo: hotkey.state.combo) { combo in
                    hotkey.setCombo(combo)
                }
            }

            // Only once there is something to switch off. A disabled toggle over
            // an empty field is a control explaining another control.
            if hotkey.state.combo != nil {
                Toggle("Use the shortcut", isOn: Binding(
                    get: { hotkey.state.isOn },
                    set: { hotkey.setEnabled($0) }
                ))
            }

            // The note and the button travel together, the same shape and the
            // same ink as `LaunchAtLoginSection`'s, because it is the same
            // situation: a control reporting what happened rather than what was
            // asked for. `GlobalHotkeyState` writes a note for exactly the state
            // the user can act on, so there is no second rule in here deciding
            // which states earn the button.
            if let note = hotkey.state.note {
                HStack(spacing: Tokens.Space.gutter) {
                    Text(note)
                        .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                        .foregroundStyle(Tokens.Ink.attention)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: Tokens.Space.gutter)

                    Button("Open Keyboard Settings…") {
                        // The pane that lists every shortcut macOS itself holds,
                        // which is the one place the user can free one up.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        } header: {
            Text("Keyboard")
        } footer: {
            // No "test this shortcut" button, and the footer is why. macOS gives
            // a combination to whichever app asked first and answers no question
            // about who that was, so a test button could only ever report "I
            // didn't hear anything" — which is what pressing the key already
            // told them.
            SectionFooter("No shortcut is set until you record one — aibars won't take a key combination off you uninvited. macOS gives a shortcut to whichever app asked for it first and there's no way for aibars to find out who that is, so if nothing happens when you press it, record a different one. Combinations macOS uses itself are refused as you record them.")
        }
    }
}
