import SwiftUI
import AppKit

/// How the dropdown, its rows, and the menu bar mark are drawn.
///
/// Split out of AppState because appearance is the part of the app the user is
/// expected to keep fiddling with, and every change to it would otherwise
/// republish the object the refresh loop writes to sixty times a minute.
///
/// Persisted under "aibars.appearance.*". Every value is read once at launch
/// into a stored property and written back on change, so a redraw costs no
/// UserDefaults traffic. Values that could make the panel unreadable are
/// clamped on write rather than trusted, because a bad number in UserDefaults
/// outlives the session that produced it.
///
/// Each value being in range is not enough on its own: density multiplies text
/// scale, and a wide logo competes with the title line for a panel that can be
/// 300pt across. `metrics` resolves those against each other and holds the
/// result off its floors, so no pair of in-range settings produces a row that
/// can't be read.
@MainActor
public final class AppearanceSettings: ObservableObject {
    /// The app's single instance. Shared because AppState and the status item
    /// are built by the app delegate at launch, while the views come later and
    /// have to observe the same object.
    public static let shared = AppearanceSettings()

    // MARK: - Vocabulary

    /// Drives row padding, gaps, type sizes and ring size together, so nine
    /// services can be made to fit without nine separate sliders.
    public enum Density: String, CaseIterable, Identifiable {
        case compact, cozy, comfortable
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .compact:     return "Compact"
            case .cozy:        return "Cozy"
            case .comfortable: return "Comfortable"
            }
        }
    }

    public enum LogoStyle: String, CaseIterable, Identifiable {
        case tile, plain, hidden
        public var id: String { rawValue }
        public var label: String {
            switch self {
            // No longer "tinted tile": the plate is a neutral 7% container in
            // every appearance and for every brand, so a label promising a tint
            // would be describing a drawing the app stopped making.
            case .tile:   return "In a tile"
            case .plain:  return "Plain mark"
            case .hidden: return "None"
            }
        }
        /// Maps onto ProviderLogo's own parameter. Meaningless for `.hidden`,
        /// where there is no logo to put a tile behind.
        public var showsTile: Bool { self == .tile }
    }

    public enum RowBackground: String, CaseIterable, Identifiable {
        case plain, hover, always
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .plain:  return "None"
            case .hover:  return "On hover"
            case .always: return "Always"
            }
        }
    }

    public enum MeterStyle: String, CaseIterable, Identifiable {
        case bar, ring, numberOnly
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .bar:        return "Bar"
            case .ring:       return "Ring"
            case .numberOnly: return "Number only"
            }
        }
    }

    public enum ColorRamp: String, CaseIterable, Identifiable {
        case usage, accent, provider, mono
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .usage:    return "By usage"
            case .accent:   return "Accent colour"
            case .provider: return "Brand colour"
            case .mono:     return "Monochrome"
            }
        }
    }

    public enum SecondaryWindowStyle: String, CaseIterable, Identifiable {
        case expanded, chips, hidden
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .expanded: return "Full bars"
            case .chips:    return "One line of chips"
            case .hidden:   return "Hidden"
            }
        }
    }

    public enum RowActionVisibility: String, CaseIterable, Identifiable {
        case onHover, always, never
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .onHover: return "On hover"
            case .always:  return "Always"
            case .never:   return "Never"
            }
        }
    }

    public enum SortOrder: String, CaseIterable, Identifiable {
        case urgency, alphabetical, manual
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .urgency:      return "Closest to its cap first"
            case .alphabetical: return "Alphabetical"
            case .manual:       return "Custom"
            }
        }
    }

    public enum Grouping: String, CaseIterable, Identifiable {
        case flat, status, usageBand
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .flat:      return "None"
            case .status:    return "Connected first"
            case .usageBand: return "How close to the cap"
            }
        }
    }

    public enum DisconnectedDisplay: String, CaseIterable, Identifiable {
        case collapsed, shown, hidden
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .collapsed: return "Folded away"
            case .shown:     return "Listed"
            case .hidden:    return "Hidden"
            }
        }
    }

    public enum MenuBarValue: String, CaseIterable, Identifiable {
        case highest, average
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .highest: return "Highest service"
            case .average: return "Average of all"
            }
        }
    }

    /// The raw values are unchanged so a stored preference survives; `perBar` now
    /// means one colour per service rather than one per abstract bar, which is
    /// the same promise made about a mark the user can identify.
    public enum MenuBarColour: String, CaseIterable, Identifiable {
        case monochrome, alertOnly, perBar
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .monochrome: return "Monochrome"
            case .alertOnly:  return "Colour above the warning"
            case .perBar:     return "Colour every figure"
            }
        }
    }

    /// What each service contributes to the menu bar strip: its mark, its
    /// figure, or both.
    ///
    /// The raw values are unchanged so a stored preference survives, but they no
    /// longer mean what they used to. The strip draws one mark and one figure per
    /// service rather than one number for the whole app, so `.iconAndPercent` is
    /// "mark plus figure, per service" and not "icon plus the highest percentage".
    ///
    /// `.iconAndName` — icon plus rotating service names — is retired. Rotating a
    /// name through a single slot was the old strip's way of saying which service
    /// the number belonged to; a per-service brand mark says it continuously and
    /// without waiting. A stored "name" is migrated to `.iconAndPercent` in
    /// `migrateLegacyKeys`.
    public enum MenuBarLabelStyle: String, CaseIterable, Identifiable {
        case iconOnly = "icon"
        case iconAndPercent = "percent"
        case percentOnly = "percentOnly"
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .iconOnly:       return "Marks only"
            case .iconAndPercent: return "Mark + figure"
            case .percentOnly:    return "Figures only"
            }
        }
        /// `.percentOnly` is the one style that drops the marks entirely.
        public var showsGlyph: Bool { self != .percentOnly }
        /// `.iconOnly` is the one style that drops the figures entirely. Named
        /// beside `showsGlyph` rather than derived at each call site, so the
        /// renderer and the Appearance pane's preview cannot disagree about what
        /// a style means.
        public var showsFigure: Bool { self != .iconOnly }
    }

    // MARK: - Density and size

    @Published public var density: Density { didSet { write(density.rawValue, .density) } }
    @Published public var textScale: Double { didSet { clampAndWrite(\.textScale, 0.85...1.30, .textScale) } }
    @Published public var logoStyle: LogoStyle { didSet { write(logoStyle.rawValue, .logoStyle) } }
    /// The floor is 16 rather than 18 because two presets ask for a 16pt mark:
    /// with a mark sitting on the ground instead of on a plate, the size that
    /// reads well beside a 12pt name in Compact is below what a plate needed.
    @Published public var logoSize: Double { didSet { clampAndWrite(\.logoSize, 16...40, .logoSize) } }
    @Published public var panelWidth: Double { didSet { clampAndWrite(\.panelWidth, 300...520, .panelWidth) } }
    @Published public var rowBackground: RowBackground { didSet { write(rowBackground.rawValue, .rowBackground) } }

    // MARK: - What a row shows

    @Published public var showsPercentage: Bool { didSet { write(showsPercentage, .showsPercentage) } }
    @Published public var showsAmounts: Bool { didSet { write(showsAmounts, .showsAmounts) } }
    @Published public var showsCountdowns: Bool { didSet { write(showsCountdowns, .showsCountdowns) } }
    @Published public var showsPlanNames: Bool { didSet { write(showsPlanNames, .showsPlanNames) } }
    @Published public var showsAccountLabels: Bool { didSet { write(showsAccountLabels, .showsAccountLabels) } }
    @Published public var secondaryWindows: SecondaryWindowStyle { didSet { write(secondaryWindows.rawValue, .secondaryWindows) } }
    @Published public var secondaryWindowLimit: Int { didSet { clampAndWrite(\.secondaryWindowLimit, 1...6, .secondaryWindowLimit) } }
    @Published public var rowActions: RowActionVisibility { didSet { write(rowActions.rawValue, .rowActions) } }

    // MARK: - How usage is drawn

    @Published public var meterStyle: MeterStyle { didSet { write(meterStyle.rawValue, .meterStyle) } }
    @Published public var meterThickness: Double { didSet { clampAndWrite(\.meterThickness, 3...12, .meterThickness) } }
    @Published public var colorRamp: ColorRamp { didSet { write(colorRamp.rawValue, .colorRamp) } }
    /// sRGB 0xRRGGBB. Nil follows the system accent, which is what a user who
    /// never opens the picker should keep getting when they change it in
    /// System Settings.
    @Published public var accentColorHex: Int? { didSet { write(accentColorHex, .accentColorHex) } }
    /// Amber above this. Held at least 0.05 below `warningThreshold` so the two
    /// bands cannot cross and invert the ramp.
    @Published public var cautionThreshold: Double { didSet { clampAndWrite(\.cautionThreshold, cautionRange, .cautionThreshold) } }
    /// Red above this — and the point at which every non-usage ramp gives up
    /// and shows the warning colour anyway.
    @Published public var warningThreshold: Double { didSet { clampAndWrite(\.warningThreshold, warningRange, .warningThreshold) } }

    // MARK: - The panel

    @Published public var sortOrder: SortOrder { didSet { write(sortOrder.rawValue, .sortOrder) } }
    /// Provider ids — "claude#2", not just "claude" — in the order the user
    /// dragged them. Ids missing from this list sort to the end in declared
    /// order, so a newly supported service appears rather than vanishing.
    @Published public var customOrder: [String] { didSet { write(customOrder, .customOrder) } }
    @Published public var grouping: Grouping { didSet { write(grouping.rawValue, .grouping) } }
    @Published public var disconnectedServices: DisconnectedDisplay { didSet { write(disconnectedServices.rawValue, .disconnectedServices) } }
    @Published public var showsAllAccounts: Bool { didSet { write(showsAllAccounts, .showsAllAccounts) } }
    @Published public var hidesQuotalessServices: Bool { didSet { write(hidesQuotalessServices, .hidesQuotalessServices) } }
    @Published public var showsHeaderSummary: Bool { didSet { write(showsHeaderSummary, .showsHeaderSummary) } }

    // MARK: - The menu bar

    @Published public var menuBarLabel: MenuBarLabelStyle { didSet { write(menuBarLabel.rawValue, .menuBarLabel) } }
    /// Which single figure the header summary reads out, and which one the alert
    /// tint is measured against.
    ///
    /// It no longer reaches the strip. The strip now names the services it draws,
    /// and an average taken across two named services is a number belonging to
    /// neither of them — "Claude 78" would be a lie about Claude. `menuBarPercent`
    /// is the one caller left.
    @Published public var menuBarValue: MenuBarValue { didSet { write(menuBarValue.rawValue, .menuBarValue) } }
    /// How many services the strip carries. Clamped to `MenuBarStripContent`'s
    /// own range rather than to a local literal, so the setting and the thing it
    /// limits cannot drift apart.
    @Published public var menuBarServiceCount: Int {
        didSet { clampAndWrite(\.menuBarServiceCount, MenuBarStripContent.range, .menuBarServiceCount) }
    }
    @Published public var menuBarColour: MenuBarColour { didSet { write(menuBarColour.rawValue, .menuBarColour) } }
    @Published public var menuBarGlyphHeight: Double { didSet { clampAndWrite(\.menuBarGlyphHeight, 10...16, .menuBarGlyphHeight) } }

    // MARK: - Lifecycle

    /// `store` is injectable so tests and previews get a scratch domain instead
    /// of the user's real settings.
    public init(store: UserDefaults = .standard) {
        self.store = store
        // Before anything is read, because everything below reads through it.
        Self.adoptSecondGenerationLook(in: store)
        // Every fallback comes from Snapshot's own defaults, so "the default of
        // this setting" is written down exactly once.
        let defaults = Snapshot()

        self.density = Self.readCase(store, .density) ?? defaults.density
        self.textScale = Self.readDouble(store, .textScale) ?? defaults.textScale
        self.logoStyle = Self.readCase(store, .logoStyle) ?? defaults.logoStyle
        self.logoSize = Self.readDouble(store, .logoSize) ?? defaults.logoSize
        self.panelWidth = Self.readDouble(store, .panelWidth) ?? defaults.panelWidth
        self.rowBackground = Self.readCase(store, .rowBackground) ?? defaults.rowBackground

        self.showsPercentage = Self.readBool(store, .showsPercentage) ?? defaults.showsPercentage
        self.showsAmounts = Self.readBool(store, .showsAmounts) ?? defaults.showsAmounts
        self.showsCountdowns = Self.readBool(store, .showsCountdowns) ?? defaults.showsCountdowns
        self.showsPlanNames = Self.readBool(store, .showsPlanNames) ?? defaults.showsPlanNames
        self.showsAccountLabels = Self.readBool(store, .showsAccountLabels) ?? defaults.showsAccountLabels
        self.secondaryWindows = Self.readCase(store, .secondaryWindows) ?? defaults.secondaryWindows
        self.secondaryWindowLimit = Self.readInt(store, .secondaryWindowLimit) ?? defaults.secondaryWindowLimit
        self.rowActions = Self.readCase(store, .rowActions) ?? defaults.rowActions

        self.meterStyle = Self.readCase(store, .meterStyle) ?? defaults.meterStyle
        self.meterThickness = Self.readDouble(store, .meterThickness) ?? defaults.meterThickness
        self.colorRamp = Self.readCase(store, .colorRamp) ?? defaults.colorRamp
        self.accentColorHex = Self.readInt(store, .accentColorHex)
        self.cautionThreshold = Self.readDouble(store, .cautionThreshold) ?? defaults.cautionThreshold
        self.warningThreshold = Self.readDouble(store, .warningThreshold) ?? defaults.warningThreshold

        self.sortOrder = Self.readCase(store, .sortOrder) ?? defaults.sortOrder
        self.customOrder = store.stringArray(forKey: Key.customOrder.rawValue) ?? []
        self.grouping = Self.readCase(store, .grouping) ?? defaults.grouping
        self.disconnectedServices = Self.readCase(store, .disconnectedServices) ?? defaults.disconnectedServices
        self.showsAllAccounts = Self.readBool(store, .showsAllAccounts) ?? defaults.showsAllAccounts
        self.hidesQuotalessServices = Self.readBool(store, .hidesQuotalessServices) ?? defaults.hidesQuotalessServices
        self.showsHeaderSummary = Self.readBool(store, .showsHeaderSummary) ?? defaults.showsHeaderSummary

        // A stored "name" no longer parses, so the fallback already lands this on
        // `.iconAndPercent`; `migrateLegacyKeys` rewrites the dead string.
        self.menuBarLabel = Self.readCase(store, .menuBarLabel) ?? defaults.menuBarLabel
        self.menuBarValue = Self.readCase(store, .menuBarValue) ?? defaults.menuBarValue
        // A stored bar count is a count of the same kind of thing — how many
        // services the item speaks for — so it carries over rather than being
        // discarded. `normalize` is what pulls a stored 4 or 6 into range.
        self.menuBarServiceCount = Self.readInt(store, .menuBarServiceCount)
            ?? Self.readInt(store, .legacyMenuBarBarCount)
            ?? defaults.menuBarServiceCount
        self.menuBarColour = Self.readCase(store, .menuBarColour) ?? defaults.menuBarColour
        self.menuBarGlyphHeight = Self.readDouble(store, .menuBarGlyphHeight) ?? defaults.menuBarGlyphHeight

        // Whatever came out of the store is now in range, and nothing has been
        // written back — `isBulkUpdating` starts true precisely so a launch that
        // only reads doesn't rewrite the whole domain.
        normalize()
        isBulkUpdating = false
        migrateLegacyKeys()
    }

    // MARK: - Derived metrics

    /// Everything the row and panel measure themselves against, resolved once
    /// from `density`, `textScale`, and the three settings that can starve a
    /// row of width or a list of separation. Handing views a struct rather than
    /// a dozen computed properties keeps one row from scaling its type off
    /// density while its neighbour scales off the raw font size.
    public struct Metrics: Equatable {
        public let rowVerticalPadding: CGFloat
        public let rowHorizontalPadding: CGFloat
        /// The VStack spacing between rows in the list.
        public let rowGap: CGFloat
        /// Title line to the detail beneath it.
        public let contentSpacing: CGFloat
        public let titleSize: CGFloat
        public let detailSize: CGFloat
        public let captionSize: CGFloat
        public let barHeight: CGFloat
        public let secondaryBarHeight: CGFloat
        public let ringDiameter: CGFloat

        public init(
            rowVerticalPadding: CGFloat,
            rowHorizontalPadding: CGFloat,
            rowGap: CGFloat,
            contentSpacing: CGFloat,
            titleSize: CGFloat,
            detailSize: CGFloat,
            captionSize: CGFloat,
            barHeight: CGFloat,
            secondaryBarHeight: CGFloat,
            ringDiameter: CGFloat
        ) {
            self.rowVerticalPadding = rowVerticalPadding
            self.rowHorizontalPadding = rowHorizontalPadding
            self.rowGap = rowGap
            self.contentSpacing = contentSpacing
            self.titleSize = titleSize
            self.detailSize = detailSize
            self.captionSize = captionSize
            self.barHeight = barHeight
            self.secondaryBarHeight = secondaryBarHeight
            self.ringDiameter = ringDiameter
        }

        // The five sizes above are the ones density and text scale set directly.
        // Everything below is derived from them and is therefore computed rather
        // than stored: a caller — including a test — that builds a `Metrics` by
        // hand cannot then hand it a figure size that disagrees with its title
        // size, and the memberwise init stays at the ten parameters it had.

        /// The row's answer, set in SF Mono.
        ///
        /// The same size as the name it sits opposite, and no longer a bump on
        /// it. A 15pt number beside a 13pt name is where "the panel shouts"
        /// came from, and it was buying prominence the figure already has for
        /// free: it is the only mono run on the line, it sits alone in a
        /// reserved trailing rail, and it is the one thing on a resting row
        /// that colour is allowed to arrive on.
        public var figureSize: CGFloat { max(11, titleSize) }

        /// The unit tick beside that figure: the `%`, the currency mark.
        ///
        /// The same size as the figure, which is the end of the superscript
        /// percent: `92%` is one mono run on one baseline, with the digits
        /// carrying the tint and the unit staying muted. A raised 8pt tick
        /// beside a 13pt number reads as a typesetting flourish, and the
        /// distinction it was drawing — the unit is not the reading — is
        /// already carried by colour.
        public var unitSize: CGFloat { figureSize }

        /// Title line to the caption directly beneath it — the countdown, the
        /// forecast sentence. Half the gap between two separate things, because
        /// this is one block of text set in two sizes.
        public var captionGap: CGFloat { max(2, (contentSpacing / 2).rounded()) }

        /// The width reserved for the headline figure and its unit: three digits,
        /// a hairline, and one unit character.
        ///
        /// Reserved rather than measured, because tabular digits fix the width of
        /// a digit and not the length of a string: `9%` still reflows to `92%`
        /// when a row ticks over. The rail's own width differs line by line — the
        /// secondary rail is narrower — but every rail on a row ends at the same
        /// trailing edge, and that shared edge is the column the eye scans down.
        public var headlineRail: CGFloat {
            Tokens.figureWidth(figureSize, digits: 3)
                + Tokens.Space.hairline
                + Tokens.figureWidth(unitSize, digits: 1)
        }

        /// The same rail for a secondary window's line, built off `detailSize`.
        /// Its unit follows the headline's rule and takes the figure's own size,
        /// so the two rails are the same shape at two scales rather than two
        /// different treatments of a number.
        public var secondaryRail: CGFloat {
            Tokens.figureWidth(detailSize, digits: 3)
                + Tokens.Space.hairline
                + Tokens.figureWidth(detailSize, digits: 1)
        }
    }

    public var metrics: Metrics {
        // `cozy` at 100% is the shipped panel, so the middle setting is a no-op
        // for anyone who never opens this pane.
        let step: (padding: CGFloat, gap: CGFloat, spacing: CGFloat, title: CGFloat, detail: CGFloat, caption: CGFloat, ring: CGFloat)
        switch density {
        // The three type sizes are the same as they were: density buys
        // line-height, not letter size. What moved is the air — a point more
        // padding and a point more between the title and what it labels — which
        // is where a quiet panel gets its calm from, and it costs nothing at the
        // scan because the row lost a whole second meter.
        case .compact:     step = (6, 0, 4, 12, 10, 9, 18)
        case .cozy:        step = (10, 2, 6, 13, 11, 10, 22)
        case .comfortable: step = (13, 4, 8, 14, 12, 11, 26)
        }
        let scale = CGFloat(textScale)
        let thickness = CGFloat(meterThickness)
        return Metrics(
            rowVerticalPadding: step.padding,
            rowHorizontalPadding: Tokens.Space.gutter,
            // Compact's zero gap was written for a list of bare rows. With a
            // background on every row it stacks nine cards edge to edge, which
            // reads as one card with nine services in it — and the hover state
            // has nothing to lift away from. Cards need a seam; bare rows
            // don't, which is why this follows the background and not density
            // alone. The shipped Compact preset is exactly this combination.
            rowGap: rowBackground == .always ? max(4, step.gap) : step.gap,
            contentSpacing: step.spacing,
            // Density and text scale multiply: compact at 85% asked for a
            // 7.6pt caption, which is smaller than anything macOS draws text
            // at. The floors are staggered so the three sizes stay distinct as
            // well as legible — a row whose title, detail and caption have all
            // bottomed out at the same size has lost its hierarchy, not just
            // its size.
            titleSize: max(11, step.title * scale),
            detailSize: max(10, step.detail * scale),
            captionSize: max(9, step.caption * scale),
            barHeight: thickness,
            // A secondary bar thinner than 2pt disappears once its fill takes
            // rounded caps.
            secondaryBarHeight: max(2, thickness * 0.6),
            ringDiameter: min(step.ring * scale, ringBudget)
        )
    }

    /// The widest the dial may be drawn.
    ///
    /// The leading column is the logo, a 7pt gap and the dial, all subtracted
    /// from a panel that can be as narrow as 300pt. At a 40pt logo and 130%
    /// type that column reached 81pt of those 300, and what was left could not
    /// hold a service name and its percentage on the same line — the number ran
    /// out of room and truncated. The dial is the part that gives way, because
    /// the number beside it already says the same thing.
    ///
    /// The floor holds at a diameter that still reads as a dial rather than a
    /// dot; the subtraction above is only in credit while `logoSize` and
    /// `panelWidth` stay inside their own ranges.
    private var ringBudget: CGFloat {
        let leadingLogo = logoStyle == .hidden ? 0 : CGFloat(logoSize) + Tokens.Space.leadingItems
        return max(16, CGFloat(panelWidth) * 0.25 - leadingLogo)
    }

    // MARK: - Colour

    /// The colour a meter at `percent` should be drawn in.
    ///
    /// `providerAccent` is AnyUsageProvider.accentColor, used only by
    /// `.provider`. Every ramp returns the warning colour at or above
    /// `warningThreshold`: a monochrome panel is a preference, a panel that
    /// hides an imminent cutoff is a bug.
    public func tint(for percent: Double, providerAccent: Color) -> Color {
        guard percent < warningThreshold else { return warningColor }
        switch colorRamp {
        case .usage:    return percent >= cautionThreshold ? cautionColor : okColor
        case .accent:   return accentColor
        case .provider: return providerAccent
        // `Ink.muted` and not `Color.primary`. On a near-black ground primary
        // resolves to pure white, which made the bar the loudest thing on a
        // panel whose entire premise is that it has no colour on it.
        case .mono:     return Tokens.Ink.muted
        }
    }

    /// The colour a figure at `percent` is set in.
    ///
    /// Below caution under `.usage` the figure is neutral, and the bar beside
    /// it now agrees: the ramp's resting stop is grey, so a healthy row carries
    /// no hue at all and colour arriving anywhere in the panel means something
    /// wants the user. This used to be the one place that rule held — the
    /// figure went neutral while nine resting bars painted teal across the
    /// panel — and the disagreement is what made colour stop meaning anything.
    ///
    /// Under `.accent`, `.provider` and `.mono` this defers unconditionally.
    /// The user asked for a coloured column — or for no colour at all — and
    /// gets one at every level; second-guessing that here would be this
    /// function overruling the setting it is standing next to.
    ///
    /// The unit tick beside the figure is not this colour. It is `Ink.idle` in
    /// every band and under every ramp, because it annotates the number rather
    /// than being part of the reading, and a neutral unit is what keeps the
    /// digits the only coloured column.
    public func figureTint(for percent: Double, providerAccent: Color) -> Color {
        guard colorRamp == .usage, percent < cautionThreshold else {
            return tint(for: percent, providerAccent: providerAccent)
        }
        return Tokens.Ink.body
    }

    /// Menu bar tint, nil below `warningThreshold` so the glyph stays quiet —
    /// and nil always under `.monochrome`, which is the whole point of that
    /// setting: a tint makes AppKit stop treating the image as a template.
    ///
    /// The threshold is the configured one, and `.monochrome` is read off the
    /// setting: this is the survivor of a pair of near-identical functions, the
    /// other of which hardcoded 0.85 and so quietly ignored a user who had
    /// moved the line. `.perBar` is not answered here — a strip that colours
    /// every figure needs a colour per figure and a brand colour for each mark
    /// beside it, which is more than one optional can carry — so the renderer
    /// is handed `menuBarColour` itself and resolves that case per segment.
    public func menuBarTint(for percent: Double) -> Color? {
        guard menuBarColour != .monochrome, percent >= warningThreshold else { return nil }
        return warningColor
    }

    /// Whether every figure in the menu bar takes its own level's colour: the
    /// yes/no form of the setting, for a caller that draws one thing and only
    /// needs to know whether to tint it.
    ///
    /// The strip renderer is not that caller and is handed `menuBarColour`
    /// itself, because it has a third case to honour — `.alertOnly` colours the
    /// one figure that crossed the warning and nothing else — and a Bool cannot
    /// carry three states. The two parameters this used to name,
    /// `UsageMeterGlyph.perBarColour` and `MenuBarIcon.colourPerBar`, went with
    /// the four abstract bars; naming them here would be this comment
    /// describing an app that no longer exists.
    public var coloursEveryMenuBarBar: Bool { menuBarColour == .perBar }

    /// Resolved accent: the stored hex, or the live system accent when unset.
    public var accentColor: Color {
        guard let accentColorHex else { return Color(nsColor: .controlAccentColor) }
        return Color(hex: UInt32(truncatingIfNeeded: accentColorHex))
    }

    /// ColorPicker needs a two-way Color, and resolving the system accent on
    /// read is what makes the picker open on the colour actually on screen.
    public var accentColorBinding: Binding<Color> {
        Binding(
            get: { self.accentColor },
            // A colour that won't convert leaves the stored one alone. Writing
            // the nil through would hand the user back to the system accent,
            // which is not what dragging a colour picker asks for.
            set: { if let hex = Self.hex(from: $0) { self.accentColorHex = hex } }
        )
    }

    /// Whether the meter graphic is drawn at all, for callers that would
    /// otherwise repeat `meterStyle != .numberOnly` in four places.
    public var drawsMeter: Bool { meterStyle != .numberOnly }

    // The ramp's three colours still come from UsageTint, sampled inside each
    // of its own fixed bands. Only the boundaries became settings; the palette
    // is still defined in one place.
    // The sample points are the shipped defaults of the two thresholds, which is
    // what UsageTint asks a caller wanting "the caution colour" to pass. They
    // move with those defaults: sampling 0.60 now lands in the resting band and
    // would hand a row at 90% a grey bar.
    private var okColor: Color { UsageTint.color(for: 0) }
    private var cautionColor: Color { UsageTint.color(for: 0.80) }
    private var warningColor: Color { UsageTint.color(for: 0.95) }

    private static func hex(from color: Color) -> Int? {
        // Extended-range components are legal and would overflow a byte, so the
        // conversion clamps rather than trusting the picker.
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return channel(srgb.redComponent) << 16
             | channel(srgb.greenComponent) << 8
             | channel(srgb.blueComponent)
    }

    // MARK: - Arranging the panel

    /// One block of rows in the dropdown, with the header it sits under.
    public struct PanelSection: Identifiable {
        public let id: String
        /// Nil for the unlabelled first block and for `grouping == .flat`.
        public let title: String?
        public let providers: [AnyUsageProvider]
        /// True only for the not-connected block under
        /// `disconnectedServices == .collapsed`; the panel owns the
        /// expanded/collapsed @State.
        public let isCollapsible: Bool

        public init(id: String, title: String?, providers: [AnyUsageProvider], isCollapsible: Bool = false) {
            self.id = id
            self.title = title
            self.providers = providers
            self.isCollapsible = isCollapsible
        }
    }

    /// Applies account collapsing, ordering, quotaless filtering, the
    /// disconnected policy and grouping in one pass.
    ///
    /// Pass `state.rankedProviders` — already urgency-ordered, which is what
    /// `.urgency` preserves. This supersedes AppState.visibleProviders, whose
    /// account collapsing is the only part of the old behaviour it reproduces.
    public func sections(
        from providers: [AnyUsageProvider],
        snapshots: [String: Result<UsageData, ProviderError>]
    ) -> [PanelSection] {
        var visible = providers
        if !showsAllAccounts {
            // The input is urgency-ordered, so the account kept is the busiest
            // one — the one worth knowing about.
            var seen: Set<String> = []
            visible = visible.filter { seen.insert($0.serviceID).inserted }
        }
        if hidesQuotalessServices {
            visible = visible.filter { !reportsNoQuota($0, in: snapshots) }
        }
        if disconnectedServices == .hidden {
            visible = visible.filter(\.isAuthenticated)
        }
        visible = ordered(visible)

        let connected = visible.filter(\.isAuthenticated)
        let missing = visible.filter { !$0.isAuthenticated }

        guard disconnectedServices == .collapsed, !missing.isEmpty else {
            // `.shown` folds the not-connected rows into whatever the grouping
            // says; only `.status` keeps them apart, because that is the split
            // it exists to draw.
            guard grouping == .status else {
                return grouped(visible, snapshots: snapshots)
            }
            return grouped(connected, snapshots: snapshots)
                + disconnectedSection(missing, isCollapsible: false, hasConnectedRows: !connected.isEmpty)
        }

        return grouped(connected, snapshots: snapshots)
            // With nothing connected there is nothing to fold these behind, and
            // a panel whose entire contents are one click away is a dead end.
            + disconnectedSection(missing, isCollapsible: !connected.isEmpty, hasConnectedRows: !connected.isEmpty)
    }

    /// The one figure the panel header summarises the app with, and the one the
    /// alert tint is measured against, per `menuBarValue`.
    ///
    /// Despite the name it no longer reaches the menu bar strip: the strip draws
    /// several services by name, and an average across named services is a number
    /// belonging to nobody. The name is kept because the setting it reads is
    /// stored under `aibars.appearance.menuBarValue` and renaming a persisted
    /// setting to tidy a call site is how a user's preference gets dropped.
    public func menuBarPercent(in state: AppState) -> Double {
        switch menuBarValue {
        case .highest: return state.topUsagePercent
        case .average: return state.averageUsagePercent
        }
    }

    /// What the menu bar strip draws, closest to its cap first.
    ///
    /// The single place that decision is made. The status item and the Appearance
    /// pane's live preview both come through here, for the reason
    /// `Tokens.rowBackground` exists: the preview and the panel disagreed once
    /// because each had its own copy of the rule, and a preview that lies about
    /// the setting it is previewing is worse than no preview.
    ///
    /// Providers that have not answered yet are absent from `serviceReadings`
    /// rather than present with a nil percent, so an empty result means "nothing
    /// has reported" and never "everything reports no quota".
    public func menuBarEntries(in state: AppState) -> [MenuBarEntry] {
        MenuBarStripContent.entries(
            from: state.serviceReadings.map {
                MenuBarEntry(serviceID: $0.serviceID, displayName: $0.displayName, percent: $0.percent)
            },
            limit: menuBarServiceCount
        )
    }

    private func disconnectedSection(
        _ providers: [AnyUsageProvider],
        isCollapsible: Bool,
        hasConnectedRows: Bool
    ) -> [PanelSection] {
        guard !providers.isEmpty else { return [] }
        return [PanelSection(
            id: "disconnected",
            title: hasConnectedRows ? "Not connected" : "Available",
            providers: providers,
            isCollapsible: isCollapsible
        )]
    }

    private func grouped(
        _ providers: [AnyUsageProvider],
        snapshots: [String: Result<UsageData, ProviderError>]
    ) -> [PanelSection] {
        guard !providers.isEmpty else { return [] }
        switch grouping {
        case .flat, .status:
            // The leading block carries no header in either case: under
            // `.status` the not-connected block is the only labelled one.
            return [PanelSection(id: "main", title: nil, providers: providers)]
        case .usageBand:
            var near: [AnyUsageProvider] = []
            var active: [AnyUsageProvider] = []
            var idle: [AnyUsageProvider] = []
            for provider in providers {
                let percent = headlinePercent(provider, in: snapshots) ?? 0
                if percent >= warningThreshold {
                    near.append(provider)
                } else if percent > 0 {
                    active.append(provider)
                } else {
                    // Nothing reported, no quota, or a genuine zero — all three
                    // are "you are not spending this one".
                    idle.append(provider)
                }
            }
            return [
                PanelSection(id: "band.near", title: "Near limit", providers: near),
                PanelSection(id: "band.active", title: "In use", providers: active),
                PanelSection(id: "band.idle", title: "Idle", providers: idle)
            ].filter { !$0.providers.isEmpty }
        }
    }

    private func ordered(_ providers: [AnyUsageProvider]) -> [AnyUsageProvider] {
        // The incoming order is the tiebreak everywhere, because `sorted` is not
        // stable and rows that swap between refreshes are the thing `.manual`
        // and `.alphabetical` exist to prevent.
        switch sortOrder {
        case .urgency:
            return providers
        case .alphabetical:
            return providers.enumerated().sorted { lhs, rhs in
                let comparison = lhs.element.displayName.localizedCaseInsensitiveCompare(rhs.element.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.offset < rhs.offset
            }.map(\.element)
        case .manual:
            return providers.enumerated().sorted { lhs, rhs in
                let a = manualRank(lhs.element), b = manualRank(rhs.element)
                if a != b { return a < b }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    /// Where a provider sits under `.manual`. A service the user never dragged —
    /// newly supported, or a second account that appeared afterwards — sorts
    /// after everything they did place, in the order AppState declares its
    /// services, so it turns up at the end rather than vanishing.
    private func manualRank(_ provider: AnyUsageProvider) -> Int {
        if let index = customOrder.firstIndex(of: provider.id) { return index }
        let declared = AppState.services.firstIndex { $0.id == provider.serviceID } ?? AppState.services.count
        return customOrder.count + declared
    }

    private func headlinePercent(
        _ provider: AnyUsageProvider,
        in snapshots: [String: Result<UsageData, ProviderError>]
    ) -> Double? {
        guard case .success(let data)? = snapshots[provider.id], data.primary.limit > 0 else { return nil }
        return data.primary.percent
    }

    /// A service that answered with a state rather than a quota — Copilot's
    /// "Active". A service that hasn't answered yet is not one of these: it may
    /// still report a number, and hiding it mid-load would make rows flicker.
    private func reportsNoQuota(
        _ provider: AnyUsageProvider,
        in snapshots: [String: Result<UsageData, ProviderError>]
    ) -> Bool {
        guard case .success(let data)? = snapshots[provider.id] else { return false }
        return data.primary.limit <= 0
    }

    // MARK: - Presets

    public enum Preset: String, CaseIterable, Identifiable {
        case comfortable, compact, minimal, dashboard, monochrome
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .comfortable: return "Comfortable"
            case .compact:     return "Compact"
            case .minimal:     return "Minimal"
            case .dashboard:   return "Dashboard"
            case .monochrome:  return "Monochrome"
            }
        }

        public var summary: String {
            switch self {
            case .comfortable:
                // No longer "everything on": the plan pill is off by default,
                // and a summary that overstates its preset is how a user comes
                // to distrust the other four.
                return "The shipped look. Amounts and countdowns on, urgency order, connected services first with the rest folded away."
            case .compact:
                return "Every service on screen at once. Keeps the bars and the numbers, drops the prose."
            case .minimal:
                return "A name and a number per service, in a stable alphabetical order."
            case .dashboard:
                return "Every window, every account, every service, grouped by how close to the cap they are."
            case .monochrome:
                return "Greyscale rings and no brand tiles. Colour returns only above the warning threshold."
            }
        }

        /// The values this preset stands for. A table, so applying a preset and
        /// recognising one can never drift apart.
        public var snapshot: Snapshot {
            switch self {
            case .comfortable:
                // The defaults themselves, spelled `Snapshot()` so a fresh
                // install recognises the preset it is already on and "reset"
                // lands on it exactly. Named for how it reads beside Compact
                // and Minimal, not after `Density.comfortable`: the panel
                // ships at cozy with a 4pt bar, and an upgrade that loosened
                // every row on its own would be this refactor changing the app
                // rather than reorganising it.
                return Snapshot()
            case .compact:
                return Snapshot(
                    density: .compact, textScale: 1.0,
                    // It already folded its windows onto one line; only the
                    // plate and the thresholds were off-message.
                    logoStyle: .plain, logoSize: 16, panelWidth: 340, rowBackground: .always,
                    showsPercentage: true, showsAmounts: false, showsCountdowns: true,
                    showsPlanNames: false, showsAccountLabels: false,
                    secondaryWindows: .chips, secondaryWindowLimit: 3, rowActions: .onHover,
                    meterStyle: .bar, meterThickness: 4, colorRamp: .usage,
                    cautionThreshold: 0.80, warningThreshold: 0.95,
                    sortOrder: .urgency, grouping: .flat, disconnectedServices: .collapsed,
                    showsAllAccounts: false, hidesQuotalessServices: false, showsHeaderSummary: true,
                    menuBarLabel: .iconAndPercent, menuBarValue: .highest,
                    menuBarServiceCount: 3, menuBarColour: .alertOnly, menuBarGlyphHeight: 13
                )
            case .minimal:
                return Snapshot(
                    density: .compact, textScale: 1.0,
                    // The preset the whole direction was always closest to: a
                    // plain mark, no windows, no meter. Only the mark was big.
                    logoStyle: .plain, logoSize: 16, panelWidth: 300, rowBackground: .plain,
                    showsPercentage: true, showsAmounts: false, showsCountdowns: false,
                    showsPlanNames: false, showsAccountLabels: false,
                    secondaryWindows: .hidden, secondaryWindowLimit: 1, rowActions: .never,
                    meterStyle: .numberOnly, meterThickness: 4, colorRamp: .usage,
                    cautionThreshold: 0.80, warningThreshold: 0.95,
                    sortOrder: .alphabetical, grouping: .flat, disconnectedServices: .hidden,
                    showsAllAccounts: false, hidesQuotalessServices: true, showsHeaderSummary: false,
                    // One service, because this is the preset that drops the
                    // marks: three bare figures in a row have nothing to say
                    // which service each belongs to, which is the fault the
                    // per-service marks were added to fix.
                    menuBarLabel: .percentOnly, menuBarValue: .highest,
                    menuBarServiceCount: 1, menuBarColour: .alertOnly, menuBarGlyphHeight: 12
                )
            case .dashboard:
                return Snapshot(
                    density: .comfortable, textScale: 1.05,
                    // The one preset allowed to be loud and dense on purpose, so
                    // it keeps its full windows, its early thresholds and its
                    // coloured strip — but a 32pt mark on a plate was dated
                    // rather than dense, and an expanded window now costs a line
                    // rather than a second bar, so the density is still honest.
                    logoStyle: .plain, logoSize: 22, panelWidth: 460, rowBackground: .always,
                    showsPercentage: true, showsAmounts: true, showsCountdowns: true,
                    showsPlanNames: true, showsAccountLabels: true,
                    secondaryWindows: .expanded, secondaryWindowLimit: 6, rowActions: .always,
                    meterStyle: .bar, meterThickness: 5, colorRamp: .usage,
                    cautionThreshold: 0.75, warningThreshold: 0.92,
                    sortOrder: .urgency, grouping: .usageBand, disconnectedServices: .shown,
                    showsAllAccounts: true, hidesQuotalessServices: false, showsHeaderSummary: true,
                    menuBarLabel: .iconAndPercent, menuBarValue: .average,
                    menuBarServiceCount: 3, menuBarColour: .perBar, menuBarGlyphHeight: 14
                )
            case .monochrome:
                return Snapshot(
                    density: .cozy, textScale: 1.0,
                    logoStyle: .plain, logoSize: 18, panelWidth: 356, rowBackground: .plain,
                    showsPercentage: true, showsAmounts: true, showsCountdowns: true,
                    showsPlanNames: false, showsAccountLabels: true,
                    secondaryWindows: .chips, secondaryWindowLimit: 3, rowActions: .onHover,
                    meterStyle: .ring, meterThickness: 4, colorRamp: .mono,
                    // The warning is the one moment this preset spends a colour,
                    // so it spends it where every other preset does.
                    cautionThreshold: 0.60, warningThreshold: 0.95,
                    sortOrder: .manual, grouping: .status, disconnectedServices: .collapsed,
                    showsAllAccounts: false, hidesQuotalessServices: false, showsHeaderSummary: true,
                    // Two, because this preset draws marks and no figures: a
                    // third undifferentiated mark adds width without adding a
                    // reading.
                    menuBarLabel: .iconOnly, menuBarValue: .highest,
                    menuBarServiceCount: 2, menuBarColour: .monochrome, menuBarGlyphHeight: 13
                )
            }
        }
    }

    /// Every preset-controlled property as plain data. Deliberately excludes
    /// `customOrder` and `accentColorHex`: those are the user's own choices,
    /// not a look, and a preset that erased them would be a trap.
    ///
    /// The default of each property is the default of the setting, so
    /// `Snapshot()` is the shipped configuration.
    public struct Snapshot: Equatable {
        public var density: Density
        public var textScale: Double
        public var logoStyle: LogoStyle
        public var logoSize: Double
        public var panelWidth: Double
        public var rowBackground: RowBackground
        public var showsPercentage: Bool
        public var showsAmounts: Bool
        public var showsCountdowns: Bool
        public var showsPlanNames: Bool
        public var showsAccountLabels: Bool
        public var secondaryWindows: SecondaryWindowStyle
        public var secondaryWindowLimit: Int
        public var rowActions: RowActionVisibility
        public var meterStyle: MeterStyle
        public var meterThickness: Double
        public var colorRamp: ColorRamp
        public var cautionThreshold: Double
        public var warningThreshold: Double
        public var sortOrder: SortOrder
        public var grouping: Grouping
        public var disconnectedServices: DisconnectedDisplay
        public var showsAllAccounts: Bool
        public var hidesQuotalessServices: Bool
        public var showsHeaderSummary: Bool
        public var menuBarLabel: MenuBarLabelStyle
        public var menuBarValue: MenuBarValue
        public var menuBarServiceCount: Int
        public var menuBarColour: MenuBarColour
        public var menuBarGlyphHeight: Double

        public init(
            density: Density = .cozy,
            textScale: Double = 1.0,
            // A brand mark on the ground at the size of two lines of text, not
            // a 30pt mark on a plate beside a 13pt name. The plate is the single
            // most dated thing the panel drew, and the size was set by it.
            logoStyle: LogoStyle = .plain,
            logoSize: Double = 18,
            panelWidth: Double = 356,
            rowBackground: RowBackground = .hover,
            showsPercentage: Bool = true,
            showsAmounts: Bool = true,
            showsCountdowns: Bool = true,
            // A filled capsule on every row is chrome, and the plan is the one
            // thing on the line that never changes. Still one click away.
            showsPlanNames: Bool = true,
            showsAccountLabels: Bool = true,
            // The windows fold onto the trailing half of the caption line. A
            // second full-width bar per row cost 24pt each and was what turned
            // one service crossing a threshold into a panel washed in amber.
            secondaryWindows: SecondaryWindowStyle = .chips,
            secondaryWindowLimit: Int = 4,
            rowActions: RowActionVisibility = .onHover,
            meterStyle: MeterStyle = .bar,
            meterThickness: Double = 4,
            colorRamp: ColorRamp = .usage,
            // The industry breakpoints, and the reason the panel stops being
            // amber: at 0.60 a perfectly healthy weekly window at 61% read as a
            // warning, nine rows at a time.
            cautionThreshold: Double = 0.80,
            warningThreshold: Double = 0.95,
            sortOrder: SortOrder = .urgency,
            grouping: Grouping = .status,
            disconnectedServices: DisconnectedDisplay = .collapsed,
            showsAllAccounts: Bool = false,
            hidesQuotalessServices: Bool = false,
            showsHeaderSummary: Bool = true,
            menuBarLabel: MenuBarLabelStyle = .iconAndPercent,
            menuBarValue: MenuBarValue = .highest,
            menuBarServiceCount: Int = 3,
            // The strip obeys the panel's rule: hue means something is wrong.
            menuBarColour: MenuBarColour = .alertOnly,
            menuBarGlyphHeight: Double = 13
        ) {
            self.density = density
            self.textScale = textScale
            self.logoStyle = logoStyle
            self.logoSize = logoSize
            self.panelWidth = panelWidth
            self.rowBackground = rowBackground
            self.showsPercentage = showsPercentage
            self.showsAmounts = showsAmounts
            self.showsCountdowns = showsCountdowns
            self.showsPlanNames = showsPlanNames
            self.showsAccountLabels = showsAccountLabels
            self.secondaryWindows = secondaryWindows
            self.secondaryWindowLimit = secondaryWindowLimit
            self.rowActions = rowActions
            self.meterStyle = meterStyle
            self.meterThickness = meterThickness
            self.colorRamp = colorRamp
            self.cautionThreshold = cautionThreshold
            self.warningThreshold = warningThreshold
            self.sortOrder = sortOrder
            self.grouping = grouping
            self.disconnectedServices = disconnectedServices
            self.showsAllAccounts = showsAllAccounts
            self.hidesQuotalessServices = hidesQuotalessServices
            self.showsHeaderSummary = showsHeaderSummary
            self.menuBarLabel = menuBarLabel
            self.menuBarValue = menuBarValue
            self.menuBarServiceCount = menuBarServiceCount
            self.menuBarColour = menuBarColour
            self.menuBarGlyphHeight = menuBarGlyphHeight
        }
    }

    public var snapshot: Snapshot {
        Snapshot(
            density: density, textScale: textScale,
            logoStyle: logoStyle, logoSize: logoSize, panelWidth: panelWidth, rowBackground: rowBackground,
            showsPercentage: showsPercentage, showsAmounts: showsAmounts, showsCountdowns: showsCountdowns,
            showsPlanNames: showsPlanNames, showsAccountLabels: showsAccountLabels,
            secondaryWindows: secondaryWindows, secondaryWindowLimit: secondaryWindowLimit, rowActions: rowActions,
            meterStyle: meterStyle, meterThickness: meterThickness, colorRamp: colorRamp,
            cautionThreshold: cautionThreshold, warningThreshold: warningThreshold,
            sortOrder: sortOrder, grouping: grouping, disconnectedServices: disconnectedServices,
            showsAllAccounts: showsAllAccounts, hidesQuotalessServices: hidesQuotalessServices,
            showsHeaderSummary: showsHeaderSummary,
            menuBarLabel: menuBarLabel, menuBarValue: menuBarValue,
            menuBarServiceCount: menuBarServiceCount, menuBarColour: menuBarColour,
            menuBarGlyphHeight: menuBarGlyphHeight
        )
    }

    /// Writes both thresholds before clamping either, so a preset that widens
    /// the bands isn't fought by the previous preset's ceiling.
    public func apply(_ snapshot: Snapshot) {
        isBulkUpdating = true
        density = snapshot.density
        textScale = snapshot.textScale
        logoStyle = snapshot.logoStyle
        logoSize = snapshot.logoSize
        panelWidth = snapshot.panelWidth
        rowBackground = snapshot.rowBackground
        showsPercentage = snapshot.showsPercentage
        showsAmounts = snapshot.showsAmounts
        showsCountdowns = snapshot.showsCountdowns
        showsPlanNames = snapshot.showsPlanNames
        showsAccountLabels = snapshot.showsAccountLabels
        secondaryWindows = snapshot.secondaryWindows
        secondaryWindowLimit = snapshot.secondaryWindowLimit
        rowActions = snapshot.rowActions
        meterStyle = snapshot.meterStyle
        meterThickness = snapshot.meterThickness
        colorRamp = snapshot.colorRamp
        cautionThreshold = snapshot.cautionThreshold
        warningThreshold = snapshot.warningThreshold
        sortOrder = snapshot.sortOrder
        grouping = snapshot.grouping
        disconnectedServices = snapshot.disconnectedServices
        showsAllAccounts = snapshot.showsAllAccounts
        hidesQuotalessServices = snapshot.hidesQuotalessServices
        showsHeaderSummary = snapshot.showsHeaderSummary
        menuBarLabel = snapshot.menuBarLabel
        menuBarValue = snapshot.menuBarValue
        menuBarServiceCount = snapshot.menuBarServiceCount
        menuBarColour = snapshot.menuBarColour
        menuBarGlyphHeight = snapshot.menuBarGlyphHeight
        normalize()
        isBulkUpdating = false
        persistAll()
    }

    public func apply(_ preset: Preset) { apply(preset.snapshot) }

    /// Which preset the current configuration is, for the settings pane to
    /// show as selected. Nil once the user has touched anything.
    public var matchingPreset: Preset? {
        let current = snapshot
        return Preset.allCases.first { $0.snapshot == current }
    }

    /// Comfortable, plus clearing the two things presets deliberately leave
    /// alone. Comfortable *is* `Snapshot()`, so this lands on the shipped
    /// configuration exactly rather than somewhere near it.
    public func resetToDefaults() {
        customOrder = []
        accentColorHex = nil
        apply(.comfortable)
    }

    // MARK: - Storage

    private enum Key: String, CaseIterable {
        case density = "aibars.appearance.density"
        case textScale = "aibars.appearance.textScale"
        case logoStyle = "aibars.appearance.logoStyle"
        case logoSize = "aibars.appearance.logoSize"
        case panelWidth = "aibars.appearance.panelWidth"
        case rowBackground = "aibars.appearance.rowBackground"
        case showsPercentage = "aibars.appearance.showsPercentage"
        case showsAmounts = "aibars.appearance.showsAmounts"
        case showsCountdowns = "aibars.appearance.showsCountdowns"
        case showsPlanNames = "aibars.appearance.showsPlanNames"
        case showsAccountLabels = "aibars.appearance.showsAccountLabels"
        case secondaryWindows = "aibars.appearance.secondaryWindows"
        case secondaryWindowLimit = "aibars.appearance.secondaryWindowLimit"
        case rowActions = "aibars.appearance.rowActions"
        case meterStyle = "aibars.appearance.meterStyle"
        case meterThickness = "aibars.appearance.meterThickness"
        case colorRamp = "aibars.appearance.colorRamp"
        case accentColorHex = "aibars.appearance.accentColorHex"
        case cautionThreshold = "aibars.appearance.cautionThreshold"
        case warningThreshold = "aibars.appearance.warningThreshold"
        case sortOrder = "aibars.appearance.sortOrder"
        case customOrder = "aibars.appearance.customOrder"
        case grouping = "aibars.appearance.grouping"
        case disconnectedServices = "aibars.appearance.disconnectedServices"
        case showsAllAccounts = "aibars.appearance.showsAllAccounts"
        case hidesQuotalessServices = "aibars.appearance.hidesQuotalessServices"
        case showsHeaderSummary = "aibars.appearance.showsHeaderSummary"
        case menuBarLabel = "aibars.appearance.menuBarLabel"
        case menuBarValue = "aibars.appearance.menuBarValue"
        case menuBarServiceCount = "aibars.appearance.menuBarServiceCount"
        case menuBarColour = "aibars.appearance.menuBarColour"
        case menuBarGlyphHeight = "aibars.appearance.menuBarGlyphHeight"
        case didMigrate = "aibars.appearance.didMigrateFromAppState"
        case didAdoptSecondGeneration = "aibars.appearance.didAdoptSecondGeneration"

        /// Retired with the four abstract bars. Read once in `init` so a user who
        /// set a bar count keeps a service count near it, and never written.
        case legacyMenuBarBarCount = "aibars.appearance.menuBarBarCount"
        /// Retired outright: a gradient makes two bars of equal length look
        /// unequal at the tip, which is exactly the down-column comparison the
        /// figure rail and the pace notch are both built on. Named only so
        /// `migrateLegacyKeys` can delete it.
        case legacyGradientFill = "aibars.appearance.usesGradientFill"
    }

    /// Takes an existing install to the new look, once.
    ///
    /// This exists because a redesign that only changes DEFAULTS changes nothing
    /// for anybody who has already run the app. Every setting is written to the
    /// store on `didSet`, and the first launch writes the lot, so by the second
    /// launch there are no unset values left for a new default to reach. The
    /// author saw the reskin land on tokens — surfaces, ink, type — while the
    /// structural half of it did not move at all: logos still in their old
    /// coloured tiles, a second full-width meter still on every row, the amber
    /// band still starting at 0.60. It looked like nothing had happened, because
    /// for the settings that were pinned, nothing had.
    ///
    /// So the appearance domain is cleared once and allowed to fall back to the
    /// new defaults. Deliberately blunt: there is no way to tell a value the user
    /// chose from a value the first launch happened to write, so preserving
    /// "customisations" would mean preserving the old design under a new name.
    /// Scoped tightly in return — only `aibars.appearance.*`, so sessions,
    /// budgets, alert rules, per-provider switches and account names are all
    /// untouched.
    private static func adoptSecondGenerationLook(in store: UserDefaults) {
        // Only the real domain. A scratch domain is one a test or a preview
        // authored deliberately — several tests seed malformed values precisely
        // to prove a bad store cannot break the layout — and clearing those would
        // be this migration deciding it knows better than the fixture.
        guard store === UserDefaults.standard else { return }
        guard !store.bool(forKey: Key.didAdoptSecondGeneration.rawValue) else { return }
        for key in Key.allCases where key != .didAdoptSecondGeneration {
            store.removeObject(forKey: key.rawValue)
        }
        store.set(true, forKey: Key.didAdoptSecondGeneration.rawValue)
    }

    private let store: UserDefaults
    /// Suppresses the per-property writes while a whole configuration is being
    /// loaded or applied, so the store is touched once at the end instead of
    /// thirty times — and so the clamps can see every value in place.
    private var isBulkUpdating = true

    private var cautionRange: ClosedRange<Double> {
        // `max` keeps the range from inverting if a warning threshold ever
        // arrives below 0.35; ClosedRange traps on that rather than clamping.
        0.30...max(0.30, min(0.85, warningThreshold - 0.05))
    }

    private var warningRange: ClosedRange<Double> {
        min(0.98, max(0.50, cautionThreshold + 0.05))...0.98
    }

    private func write(_ value: Any?, _ key: Key) {
        guard !isBulkUpdating else { return }
        if let value {
            store.set(value, forKey: key.rawValue)
        } else {
            store.removeObject(forKey: key.rawValue)
        }
    }

    /// Reassigns through the keypath when the value was out of range, which
    /// re-enters `didSet` exactly once and then stops on the equality check.
    ///
    /// Stands down entirely during a bulk update. Otherwise the caution
    /// threshold would be squeezed against a warning threshold that is still
    /// the *previous* configuration's, which is the exact ordering `normalize`
    /// exists to avoid.
    private func clampAndWrite<V: Comparable>(
        _ path: ReferenceWritableKeyPath<AppearanceSettings, V>,
        _ range: ClosedRange<V>,
        _ key: Key
    ) {
        guard !isBulkUpdating else { return }
        let value = self[keyPath: path]
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard clamped == value else {
            self[keyPath: path] = clamped
            return
        }
        write(value, key)
    }

    /// Pulls every bounded value into range without going through the property
    /// observers, so both thresholds are settled before either is measured
    /// against the other.
    private func normalize() {
        textScale = min(max(textScale, 0.85), 1.30)
        logoSize = min(max(logoSize, 16), 40)
        panelWidth = min(max(panelWidth, 300), 520)
        secondaryWindowLimit = min(max(secondaryWindowLimit, 1), 6)
        meterThickness = min(max(meterThickness, 3), 12)
        menuBarServiceCount = min(
            max(menuBarServiceCount, MenuBarStripContent.range.lowerBound),
            MenuBarStripContent.range.upperBound
        )
        menuBarGlyphHeight = min(max(menuBarGlyphHeight, 10), 16)
        warningThreshold = min(max(warningThreshold, 0.50), 0.98)
        cautionThreshold = min(max(cautionThreshold, cautionRange.lowerBound), cautionRange.upperBound)
    }

    private func persistAll() {
        write(density.rawValue, .density)
        write(textScale, .textScale)
        write(logoStyle.rawValue, .logoStyle)
        write(logoSize, .logoSize)
        write(panelWidth, .panelWidth)
        write(rowBackground.rawValue, .rowBackground)
        write(showsPercentage, .showsPercentage)
        write(showsAmounts, .showsAmounts)
        write(showsCountdowns, .showsCountdowns)
        write(showsPlanNames, .showsPlanNames)
        write(showsAccountLabels, .showsAccountLabels)
        write(secondaryWindows.rawValue, .secondaryWindows)
        write(secondaryWindowLimit, .secondaryWindowLimit)
        write(rowActions.rawValue, .rowActions)
        write(meterStyle.rawValue, .meterStyle)
        write(meterThickness, .meterThickness)
        write(colorRamp.rawValue, .colorRamp)
        write(cautionThreshold, .cautionThreshold)
        write(warningThreshold, .warningThreshold)
        write(sortOrder.rawValue, .sortOrder)
        write(grouping.rawValue, .grouping)
        write(disconnectedServices.rawValue, .disconnectedServices)
        write(showsAllAccounts, .showsAllAccounts)
        write(hidesQuotalessServices, .hidesQuotalessServices)
        write(showsHeaderSummary, .showsHeaderSummary)
        write(menuBarLabel.rawValue, .menuBarLabel)
        write(menuBarValue.rawValue, .menuBarValue)
        write(menuBarServiceCount, .menuBarServiceCount)
        write(menuBarColour.rawValue, .menuBarColour)
        write(menuBarGlyphHeight, .menuBarGlyphHeight)
    }

    /// One-time import of the four settings AppState used to own, plus the
    /// retirements this version makes.
    ///
    /// The AppState keys are left in place. They cost nothing, and deleting them
    /// means a user who downgrades loses settings they never changed. The three
    /// retirements below are different: their keys are this class's own, they can
    /// never be read again, and leaving a value in the domain that nothing honours
    /// is how a settings file starts lying about the app.
    private func migrateLegacyKeys() {
        // Ahead of the one-time guard, because all three are retirements made in
        // this version and the guard was already tripped for everyone who has
        // launched a previous one.
        store.removeObject(forKey: Key.legacyGradientFill.rawValue)
        // The read in `init` has already clamped whatever was here into
        // `menuBarServiceCount`; this writes the clamped value under the new key
        // and drops the old one, so the next launch reads it directly.
        if store.object(forKey: Key.legacyMenuBarBarCount.rawValue) != nil {
            store.set(menuBarServiceCount, forKey: Key.menuBarServiceCount.rawValue)
            store.removeObject(forKey: Key.legacyMenuBarBarCount.rawValue)
        }
        // "name" was icon plus rotating service names, which the per-service
        // marks replace. The read in `init` has already fallen back to the
        // default, so this only rewrites the dead string.
        if store.string(forKey: Key.menuBarLabel.rawValue) == "name" {
            store.set(menuBarLabel.rawValue, forKey: Key.menuBarLabel.rawValue)
        }

        guard !store.bool(forKey: Key.didMigrate.rawValue) else { return }

        // A raw value that no longer parses — "name" is the only one — leaves the
        // default in place, which is where the retirement above sends it anyway.
        if let raw = store.string(forKey: "aibars.menuBarDisplay"),
           let style = MenuBarLabelStyle(rawValue: raw) {
            menuBarLabel = style
        }
        if let allWindows = store.object(forKey: "aibars.showsAllWindows") as? Bool {
            // Off used to mean "fold them into chips", not "drop them".
            secondaryWindows = allWindows ? .expanded : .chips
        }
        if let planNames = store.object(forKey: "aibars.showsPlanNames") as? Bool {
            showsPlanNames = planNames
        }
        if let allAccounts = store.object(forKey: "aibars.showsAllAccounts") as? Bool {
            showsAllAccounts = allAccounts
        }
        store.set(true, forKey: Key.didMigrate.rawValue)
    }

    // Reads are static so `init` can use them before `self` exists, and named
    // by type rather than overloaded so thirty call sites in a row don't
    // each cost the type checker an overload search.
    private static func readCase<T: RawRepresentable>(_ store: UserDefaults, _ key: Key) -> T? where T.RawValue == String {
        store.string(forKey: key.rawValue).flatMap(T.init(rawValue:))
    }

    /// `object(forKey:)` rather than `bool(forKey:)`: the latter answers false
    /// for a key that was never written, which would silently turn every
    /// default-on setting off.
    private static func readBool(_ store: UserDefaults, _ key: Key) -> Bool? {
        store.object(forKey: key.rawValue) as? Bool
    }

    private static func readInt(_ store: UserDefaults, _ key: Key) -> Int? {
        store.object(forKey: key.rawValue) as? Int
    }

    private static func readDouble(_ store: UserDefaults, _ key: Key) -> Double? {
        store.object(forKey: key.rawValue) as? Double
    }
}
