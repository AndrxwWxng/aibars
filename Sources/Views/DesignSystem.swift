import SwiftUI

/// The measurements that are not settings.
///
/// `AppearanceSettings.Metrics` owns everything density and text scale move:
/// row padding, the panel's three type sizes, bar and ring geometry. This owns
/// what they don't — the gutters both windows share, the corner radii, the
/// settings window's own type sizes, hit-target sizes, and the quiet fills that
/// are currently written as `Color.primary.opacity(0.07)` at seven slightly
/// different values across four files.
///
/// The rule for where a number goes: if the user can change it, it belongs in
/// `Metrics`; if they cannot, it belongs here. Nothing in here is persisted and
/// nothing has a control in the Appearance pane. `Metrics` is the caller of
/// this type, never the reverse — `rowHorizontalPadding` should return
/// `Tokens.Space.gutter` rather than repeat the literal 12.
public enum Tokens {

    // MARK: - Spacing

    /// Gaps between things, on a 2/4/6/8/12/16/24 scale. Three neighbouring
    /// gaps of 5, 6 and 7pt read as a mistake rather than as a rhythm, which is
    /// what the panel currently has: `titleLine` at 6, its chips at 5, its
    /// captions at 4 and its leading column at 7.
    public enum Space {
        /// The 1pt that is not a gap: the nudge that drops the leading column
        /// onto a cap-height title, the pill's own vertical padding, and the
        /// space between a title and the caption directly under it — which is
        /// one block of text set in two sizes, not two things beside each other.
        public static let hairline: CGFloat = 1
        public static let tight: CGFloat = 2
        public static let snug: CGFloat = 4
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 12
        public static let xlarge: CGFloat = 16
        public static let huge: CGFloat = 24

        /// Content inset for the panel and for each settings pane's own columns.
        /// `AppearanceSettings.Metrics.rowHorizontalPadding` is this value, and
        /// so are the three hardcoded 12s that indent the panel's section
        /// headers — those exist to line up with it and currently only do so by
        /// coincidence.
        public static let gutter: CGFloat = 12
        /// How far a row's background is held inside the gutter, so a hovered
        /// card floats instead of touching the window edge.
        public static let cardInset: CGFloat = 6
        /// Logo-and-dial column to the text beside it. Deliberately off the
        /// scale: `ProviderRow.textGap` and `SampleRow.textGap` are 11 today,
        /// and `AppearanceSettings.ringBudget` subtracts `leadingItems + 0` from
        /// the panel width to decide how wide a dial may be. Moving either
        /// changes what the dial is allowed to be at a 300pt panel, so they
        /// are named at their current values rather than rounded onto the scale.
        public static let leadingColumn: CGFloat = 11
        /// Logo to dial inside that column. `ProviderRow.leadingSpacing`, and
        /// the `+ 7` inside `ringBudget`.
        public static let leadingItems: CGFloat = 7
        /// Panel header: above the title line, and below it to the divider.
        /// Asymmetric because the divider reads as part of the bottom edge.
        public static let headerTop: CGFloat = 11
        public static let headerBottom: CGFloat = 9
        /// Vertical breathing room around the panel's list inside the window.
        public static let listMargin: CGFloat = 6
        /// A settings pane's own inset, for the panes that aren't a `Form`.
        public static let paneMargin: CGFloat = 14
        /// A dialog's inset: the connect window and any sheet.
        public static let dialogMargin: CGFloat = 16
    }

    // MARK: - Corner radii

    /// Named by the kind of surface rather than by size, because each one is a
    /// different thing: there are four kinds of rounded rectangle in the app and
    /// five radii (5, 6, 7, 8, 10) drawing them.
    public enum Radius {
        /// A borderless icon button's hover plate.
        public static let control: CGFloat = 5
        /// A selectable pill: sidebar row, preset chip, section disclosure.
        public static let chip: CGFloat = 6
        /// A row card in the panel.
        public static let row: CGFloat = 8
        /// A floating surface: the appearance sample, a banner, a callout.
        public static let panel: CGFloat = 10
        /// Every corner in the app is continuous. Named so a caller cannot
        /// forget to say so — the two places that do stand out badly next to a
        /// neighbour that didn't.
        public static let style: RoundedCornerStyle = .continuous
    }

    /// `RoundedRectangle` at a radius from `Radius`, continuous like the rest.
    public static func surface(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: Radius.style)
    }

    // MARK: - Type

    /// The type ramp for everything `Metrics` does not scale.
    ///
    /// The panel's own title/detail/caption sizes stay in `Metrics` — they move
    /// with density and text scale and are not repeated here. This is the
    /// settings window, the connect dialog and the panel's group headers, none
    /// of which follow the panel's text scale (a settings window that resized
    /// itself from an appearance slider would be its own bug).
    public enum Ramp {
        /// A row's subject in the settings window: a service name, a heading.
        public static let title: CGFloat = 13
        /// Body text in a settings row or a dialog step.
        public static let body: CGFloat = 12
        /// The line under a title, and the menu bar sample's own label.
        public static let label: CGFloat = 11
        /// Numeric readouts, footers, the value beside a slider.
        public static let caption: CGFloat = 10
        /// The panel's group headers: a divider with a word on it, not content.
        public static let section: CGFloat = 9

        /// A name, a heading, a figure that is the row's answer.
        public static let titleWeight: Font.Weight = .semibold
        /// A label that has to hold its own beside a figure.
        public static let emphasisWeight: Font.Weight = .medium
        /// Percentages and any figure the eye scans down a column.
        public static let figureDesign: Font.Design = .rounded
    }

    /// Group-header size: `Ramp.section`, following the panel's text scale
    /// upward only. The smallest scale would take 9pt to 7.6, and an uppercased
    /// letter-spaced label at that size is a grey smear. Currently computed
    /// inline in `MenuBarContentView.sectionFontSize` and defaulted again on
    /// both `DisclosureHeader.fontSize` and `SectionLabel.fontSize`.
    public static func sectionSize(textScale: Double) -> CGFloat {
        max(Ramp.section, Ramp.section * CGFloat(textScale))
    }

    /// Letter spacing for an uppercased group header.
    public static let sectionTracking: CGFloat = 0.5

    /// The height a single-line detail row is held at.
    ///
    /// A `ProgressView`, a status dot and a percentage are each taller than the
    /// text beside them, so a row that sizes itself to whichever one is in it
    /// changes height when a load finishes or a quota arrives. One box, one
    /// height, whatever fills it. This is the `+ 3` that was written twice in
    /// `ProviderRow` — on the loading row and inside `StatusLine` — and left off
    /// the `MetricCaption` that replaces them, so the row lost those 3pt the
    /// moment a quota arrived and the panel resized around it.
    public static func lineBox(_ size: CGFloat) -> CGFloat {
        size + lineBoxPad
    }

    /// Deliberately off the spacing scale, and kept at the value the panel was
    /// tuned at: it is not a gap between two things but the slack a mini
    /// `ProgressView` and a 6pt status dot need over the line of text they share
    /// a row with. Rounding it to 2 or 4 moves every row in the panel.
    private static let lineBoxPad: CGFloat = 3

    // MARK: - Controls

    /// Hit targets and fixed control geometry.
    public enum Control {
        /// A borderless icon button standing alone in a header. The smallest
        /// square that still reads as a target in a menu bar panel.
        public static let iconButton: CGFloat = 24
        /// The same button inside a row's title line, where it shares the line
        /// with type instead of standing alone. This is the *whole* button — the
        /// hover plate included — not a frame wrapped around a 24pt one.
        public static let rowIconButton: CGFloat = 20
        /// The glyph inside either.
        public static let iconGlyph: CGFloat = 12
        /// The status-item mark as drawn in the panel header and the appearance
        /// sample. Not `menuBarGlyphHeight`: that setting sizes the mark in the
        /// menu bar, where the row height is the system's, and a header is not
        /// a menu bar. Named so the two stop being the same literal 16 in two
        /// files with no relationship written down.
        public static let headerGlyph: CGFloat = 16
        /// The mark on the About pane, which is a logo rather than a control.
        public static let aboutGlyph: CGFloat = 44
        /// A provider logo in the settings window, which has no density setting
        /// to size it from.
        public static let settingsLogo: CGFloat = 26
        /// A provider logo in a connect dialog's headline.
        public static let dialogLogo: CGFloat = 34
        /// The dot in front of a status line.
        public static let dot: CGFloat = 6
        /// The dot on a chip, which sits beside caption type rather than body.
        public static let chipDot: CGFloat = 5
        /// Width the connect/disconnect column holds in Settings, so it doesn't
        /// step in and out as services connect. Sized for the longest label the
        /// column carries — "Configure…" — at `.small`, with room for the
        /// ellipsis rather than exactly none.
        public static let actionColumn: CGFloat = 96
        /// The settings sidebar, and the inset that clears the transparent
        /// titlebar it runs underneath.
        public static let sidebarWidth: CGFloat = 176
        public static let titlebarInset: CGFloat = 38
        /// The narrowest a settings pane's form may be before its labels wrap.
        public static let formMinWidth: CGFloat = 460
        /// The Appearance pane's preview column, which tracks the panel width
        /// being previewed and is held between these. The ceiling is here
        /// rather than inside the pane because the window's own minimum is
        /// derived from it.
        public static let previewColumnMin: CGFloat = 340
        public static let previewColumnMax: CGFloat = 420
        /// The narrowest the settings window can be with all three of its
        /// columns whole, and the shortest it can be with a form and a preview
        /// strip in it.
        ///
        /// Derived rather than written down: as a literal 980 it disagreed with
        /// the columns inside it by 50-80pt, and the column that gave way was
        /// the form — the only one of the three without a fixed frame.
        public static let settingsMinWidth: CGFloat =
            sidebarWidth + formMinWidth + previewColumnMax + hairline
        public static let settingsMinHeight: CGFloat = 560
        /// A slider and its readout in the Appearance pane.
        public static let sliderWidth: CGFloat = 168
        public static let readoutWidth: CGFloat = 42
        /// A hairline rule drawn as a `Rectangle` rather than a `Divider`.
        public static let hairline: CGFloat = 1
        /// A connect dialog's width. One number, so the two dialogs stop being
        /// 440 and 460.
        public static let dialogWidth: CGFloat = 460
    }

    // MARK: - Fills

    /// `Color.primary` opacities, named by what the fill *means* rather than by
    /// its number. Seven slightly different values were spread across four files
    /// for this handful of meanings, and no call site said which of them it was
    /// reaching for — so a card and a hover plate could be told apart in one file
    /// and not in the next.
    public enum Fill {
        /// A card at rest, under `RowBackground.always`.
        public static let card: Double = 0.05
        /// Any surface under the pointer that was transparent at rest.
        public static let hover: Double = 0.06
        /// A card under the pointer that was already filled — it still has to
        /// lift, or the row stops answering "is this the one I'm about to click".
        public static let cardHover: Double = 0.09
        /// A control's hover plate: icon button, sidebar row, disclosure header,
        /// preset chip. One value, not 0.05/0.07/0.09/0.10.
        public static let controlHover: Double = 0.08
        /// A pill carrying a value: plan name, section count, secondary chip.
        public static let pill: Double = 0.07
        /// An empty meter track — bar and ring both.
        public static let track: Double = 0.12
        /// A hairline rule, and the border on a floating surface.
        public static let rule: Double = 0.07
        public static let border: Double = 0.09
        /// The low stop of a gradient meter fill, as a fraction of the tint.
        public static let gradientFloor: Double = 0.75
        /// The opacity a `Divider` is drawn at. The panel uses 0.5 and the
        /// connect dialog 0.6 for the same hairline.
        public static let divider: Double = 0.5
    }

    /// `Color.primary` at one of `Fill`'s opacities — the longhand every one of
    /// those literals is currently written in.
    public static func quiet(_ opacity: Double) -> Color {
        Color.primary.opacity(opacity)
    }

    /// The row background opacity for a background setting and a hover state.
    /// The same three-case switch exists in `ProviderRow.backgroundOpacity` and
    /// again in `AppearancePane`'s `SampleRow.backgroundOpacity`, which is how
    /// the preview and the panel drift.
    public static func rowBackground(
        _ style: AppearanceSettings.RowBackground,
        isHovered: Bool
    ) -> Double {
        switch style {
        case .plain:  return 0
        case .hover:  return isHovered ? Fill.hover : 0
        case .always: return isHovered ? Fill.cardHover : Fill.card
        }
    }

    // MARK: - Dimming

    /// Opacity applied to a mark to say something about its subject rather than
    /// about the surface under it.
    public enum Dim {
        /// A service switched off in Settings.
        public static let disabled: Double = 0.4
        /// A service that is not connected.
        public static let disconnected: Double = 0.55
        /// A reserved control that is not currently offered. Named because the
        /// value matters: the space stays, only this changes.
        public static let reserved: Double = 0
    }

    // MARK: - Semantic colour

    /// Colours that mean a state.
    ///
    /// Usage colour is not here and must not come here: every meter, dot and
    /// percentage goes through `AppearanceSettings.tint(for:providerAccent:)`,
    /// which the user configures. This is the small set of states that are not
    /// usage — a connection working, a connection that needs the user, a request
    /// that failed — currently spelled `.green`, `.orange` and `.red` in
    /// `SettingsView.statusColor`, `ProviderRow.detailContent`,
    /// `BrowserLoginView.statusRow` and `limitationBanner` with no agreement
    /// between them.
    public enum Ink {
        /// Working. Reserved for exactly that: a connected service that is not
        /// answering is not green.
        public static let ok: Color = .green
        /// Needs the user: locked, expired, connected but not responding.
        public static let attention: Color = .orange
        /// The request failed outright.
        public static let failure: Color = .red
        /// Neither: disabled, nothing reported yet, a count of things elsewhere.
        public static let idle: Color = Color.secondary
        /// Text and glyphs on an accent-filled chip.
        public static let onAccent: Color = .white
        /// The wash behind a warning banner, at the weight a banner wants.
        public static let attentionWash: Color = Color.orange.opacity(0.10)
    }
}

/// A pill that is either selected or not: a settings sidebar row, a preset chip.
///
/// One view for both, because they were meant to be the same control and were
/// not — `PresetChip`'s doc comment claimed it was "styled like the settings
/// sidebar rows" while resting at a 0.06 fill the sidebar row didn't have, so
/// two controls in one window disagreed about what "not selected" looks like.
///
/// Resting transparent is the sidebar's behaviour and the right one: a grid of
/// chips that all carry a fill has five things competing with the one that is
/// actually chosen.
public struct SelectableChip: View {
    public let title: String
    /// SF Symbol in front of the title, in a fixed column so a list of these
    /// lines its titles up. Nil centres the title instead, which is what a chip
    /// in a grid wants and a sidebar row does not.
    public let symbol: String?
    public let isSelected: Bool
    public let help: String?
    public let action: () -> Void

    @State private var isHovered = false

    public init(
        title: String,
        symbol: String? = nil,
        isSelected: Bool,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.medium) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.Control.iconGlyph))
                        // A fixed box, so the titles beside four different
                        // symbols start at one x rather than at four.
                        .frame(width: Tokens.Space.xlarge)
                }
                Text(title)
                    .font(.system(
                        size: Tokens.Ramp.title,
                        weight: isSelected ? Tokens.Ramp.emphasisWeight : .regular
                    ))
                    .lineLimit(1)
                    // The title takes the rest of the width and places itself in
                    // it, so a centred chip and a leading row are one view with
                    // one alignment argument rather than two layouts.
                    .frame(maxWidth: .infinity, alignment: symbol == nil ? .center : .leading)
            }
            .foregroundStyle(isSelected ? Tokens.Ink.onAccent : Color.primary)
            .padding(.horizontal, Tokens.Space.medium)
            .padding(.vertical, Tokens.Space.small)
            .contentShape(Rectangle())
            .background(Tokens.surface(Tokens.Radius.chip).fill(background))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help ?? "")
        // Which pane you are on is carried by a fill and a weight, neither of
        // which VoiceOver reads. Without this a sidebar of four buttons sounds
        // identical whichever one is open.
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Selected wins over hovered: a chip the pointer is resting on is still the
    /// chosen one, and lightening the accent under the pointer reads as the
    /// selection being dragged off it.
    private var background: Color {
        if isSelected { return .accentColor }
        return Tokens.quiet(isHovered ? Tokens.Fill.controlHover : 0)
    }
}

// ---------------------------------------------------------------------------
// What this replaces, so the migration is mechanical rather than a judgement
// call per call site:
//
//   AppearanceSettings.Metrics.rowHorizontalPadding -> Tokens.Space.gutter
//     (the literal 12 in `metrics`, plus the three hardcoded 12s indenting
//      section headers in MenuBarContentView, plus SectionLabel's trailing 12)
//   ringBudget's `+ 7`                             -> Tokens.Space.leadingItems
//   ProviderRow.textGap / leadingSpacing           -> Space.leadingColumn / leadingItems
//     (and the private copies of both in AppearancePane.SampleRow)
//   HoverIconButton's 24 / 12 / radius 5           -> Control.iconButton /
//                                                     Control.iconGlyph / Radius.control
//     plus a `size` parameter defaulting to Control.iconButton, so a row can
//     ask for Control.rowIconButton instead of wrapping a 24pt button in a
//     20x18 frame it overflows.
//   ProviderRow's two `+ 3` height floors            -> Tokens.lineBox(_:)
//   AppearancePane.PresetChip                        -> SelectableChip
//     (SettingsView's own SidebarRow is already gone)
//   AppearancePane's 460 / 340 / 420 / 168 / 42      -> Control.formMinWidth /
//     previewColumnMin / previewColumnMax / sliderWidth / readoutWidth
//   every RoundedRectangle(cornerRadius: 5|6|7|8|10) -> Tokens.surface(Radius.…)
//   every Color.primary.opacity(0.05…0.12)           -> Tokens.quiet(Fill.…)
//   Divider().opacity(0.5|0.6)                       -> .opacity(Fill.divider)
//   MenuBarContentView.sectionFontSize               -> Tokens.sectionSize(textScale:)
//   SettingsWindowController's minSize of 980        -> Control.settingsMinWidth
//     — it is currently 77pt under what SettingsView can lay out, so the window
//     can be dragged narrower than its own contents.
// ---------------------------------------------------------------------------
