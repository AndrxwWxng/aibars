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
            case .tile:   return "Tinted tile"
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

    public enum MenuBarColour: String, CaseIterable, Identifiable {
        case monochrome, alertOnly, perBar
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .monochrome: return "Monochrome"
            case .alertOnly:  return "Colour above the warning"
            case .perBar:     return "Colour every bar"
            }
        }
    }

    /// Raw values match AppState.MenuBarDisplay so the stored setting carries
    /// over without a translation table.
    public enum MenuBarLabelStyle: String, CaseIterable, Identifiable {
        case iconOnly = "icon"
        case iconAndPercent = "percent"
        case iconAndName = "name"
        case percentOnly = "percentOnly"
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .iconOnly:       return "Icon only"
            case .iconAndPercent: return "Icon + highest %"
            case .iconAndName:    return "Icon + rotating names"
            case .percentOnly:    return "Percentage only"
            }
        }
        /// `.percentOnly` is the one style that drops the mark entirely.
        public var showsGlyph: Bool { self != .percentOnly }
    }

    // MARK: - Density and size

    @Published public var density: Density { didSet { write(density.rawValue, .density) } }
    @Published public var textScale: Double { didSet { clampAndWrite(\.textScale, 0.85...1.30, .textScale) } }
    @Published public var logoStyle: LogoStyle { didSet { write(logoStyle.rawValue, .logoStyle) } }
    @Published public var logoSize: Double { didSet { clampAndWrite(\.logoSize, 18...40, .logoSize) } }
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
    @Published public var usesGradientFill: Bool { didSet { write(usesGradientFill, .usesGradientFill) } }
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
    @Published public var menuBarValue: MenuBarValue { didSet { write(menuBarValue.rawValue, .menuBarValue) } }
    @Published public var menuBarBarCount: Int { didSet { clampAndWrite(\.menuBarBarCount, 1...6, .menuBarBarCount) } }
    @Published public var menuBarColour: MenuBarColour { didSet { write(menuBarColour.rawValue, .menuBarColour) } }
    @Published public var menuBarGlyphHeight: Double { didSet { clampAndWrite(\.menuBarGlyphHeight, 10...16, .menuBarGlyphHeight) } }

    // MARK: - Lifecycle

    /// `store` is injectable so tests and previews get a scratch domain instead
    /// of the user's real settings.
    public init(store: UserDefaults = .standard) {
        self.store = store
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
        self.usesGradientFill = Self.readBool(store, .usesGradientFill) ?? defaults.usesGradientFill
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

        self.menuBarLabel = Self.readCase(store, .menuBarLabel) ?? defaults.menuBarLabel
        self.menuBarValue = Self.readCase(store, .menuBarValue) ?? defaults.menuBarValue
        self.menuBarBarCount = Self.readInt(store, .menuBarBarCount) ?? defaults.menuBarBarCount
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
    }

    public var metrics: Metrics {
        // `cozy` at 100% reproduces the metrics the panel shipped with, so the
        // middle setting is a no-op for anyone who never opens this pane.
        let step: (padding: CGFloat, gap: CGFloat, spacing: CGFloat, title: CGFloat, detail: CGFloat, caption: CGFloat, ring: CGFloat)
        switch density {
        case .compact:     step = (5, 0, 3, 12, 10, 9, 18)
        case .cozy:        step = (9, 2, 5, 13, 11, 10, 22)
        case .comfortable: step = (12, 5, 7, 14, 12, 11, 26)
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
        case .mono:     return .primary
        }
    }

    /// Menu bar tint, nil below `warningThreshold` so the glyph stays quiet —
    /// and nil always under `.monochrome`, which is the whole point of that
    /// setting: a tint makes AppKit stop treating the image as a template.
    public func menuBarTint(for percent: Double) -> Color? {
        guard menuBarColour != .monochrome, percent >= warningThreshold else { return nil }
        return warningColor
    }

    /// Whether the glyph colours every bar by its own level, for
    /// UsageMeterGlyph's `perBarColour` and MenuBarIcon's `colourPerBar`.
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
    private var okColor: Color { UsageTint.color(for: 0) }
    private var cautionColor: Color { UsageTint.color(for: 0.60) }
    private var warningColor: Color { UsageTint.color(for: 0.85) }

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

    /// The percent the menu bar shows and tints from, per `menuBarValue`.
    public func menuBarPercent(in state: AppState) -> Double {
        switch menuBarValue {
        case .highest: return state.topUsagePercent
        case .average: return state.averageUsagePercent
        }
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
                return "The shipped look. Everything on, urgency order, connected services first with the rest folded away."
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
                // shipped at cozy with a 5pt bar, and an upgrade that loosened
                // every row on its own would be this refactor changing the app
                // rather than reorganising it.
                return Snapshot()
            case .compact:
                return Snapshot(
                    density: .compact, textScale: 1.0,
                    logoStyle: .tile, logoSize: 22, panelWidth: 340, rowBackground: .always,
                    showsPercentage: true, showsAmounts: false, showsCountdowns: true,
                    showsPlanNames: false, showsAccountLabels: false,
                    secondaryWindows: .chips, secondaryWindowLimit: 3, rowActions: .onHover,
                    meterStyle: .bar, meterThickness: 4, colorRamp: .usage, usesGradientFill: false,
                    cautionThreshold: 0.60, warningThreshold: 0.85,
                    sortOrder: .urgency, grouping: .flat, disconnectedServices: .collapsed,
                    showsAllAccounts: false, hidesQuotalessServices: false, showsHeaderSummary: true,
                    menuBarLabel: .iconAndPercent, menuBarValue: .highest,
                    menuBarBarCount: 4, menuBarColour: .perBar, menuBarGlyphHeight: 13
                )
            case .minimal:
                return Snapshot(
                    density: .compact, textScale: 1.0,
                    logoStyle: .plain, logoSize: 20, panelWidth: 300, rowBackground: .plain,
                    showsPercentage: true, showsAmounts: false, showsCountdowns: false,
                    showsPlanNames: false, showsAccountLabels: false,
                    secondaryWindows: .hidden, secondaryWindowLimit: 1, rowActions: .never,
                    meterStyle: .numberOnly, meterThickness: 4, colorRamp: .usage, usesGradientFill: false,
                    cautionThreshold: 0.60, warningThreshold: 0.85,
                    sortOrder: .alphabetical, grouping: .flat, disconnectedServices: .hidden,
                    showsAllAccounts: false, hidesQuotalessServices: true, showsHeaderSummary: false,
                    menuBarLabel: .percentOnly, menuBarValue: .highest,
                    menuBarBarCount: 3, menuBarColour: .alertOnly, menuBarGlyphHeight: 12
                )
            case .dashboard:
                return Snapshot(
                    density: .comfortable, textScale: 1.05,
                    logoStyle: .tile, logoSize: 32, panelWidth: 460, rowBackground: .always,
                    showsPercentage: true, showsAmounts: true, showsCountdowns: true,
                    showsPlanNames: true, showsAccountLabels: true,
                    secondaryWindows: .expanded, secondaryWindowLimit: 6, rowActions: .always,
                    meterStyle: .bar, meterThickness: 7, colorRamp: .usage, usesGradientFill: true,
                    cautionThreshold: 0.55, warningThreshold: 0.80,
                    sortOrder: .urgency, grouping: .usageBand, disconnectedServices: .shown,
                    showsAllAccounts: true, hidesQuotalessServices: false, showsHeaderSummary: true,
                    menuBarLabel: .iconAndName, menuBarValue: .average,
                    menuBarBarCount: 6, menuBarColour: .perBar, menuBarGlyphHeight: 14
                )
            case .monochrome:
                return Snapshot(
                    density: .cozy, textScale: 1.0,
                    logoStyle: .plain, logoSize: 26, panelWidth: 356, rowBackground: .plain,
                    showsPercentage: true, showsAmounts: true, showsCountdowns: true,
                    showsPlanNames: false, showsAccountLabels: true,
                    secondaryWindows: .chips, secondaryWindowLimit: 3, rowActions: .onHover,
                    meterStyle: .ring, meterThickness: 4, colorRamp: .mono, usesGradientFill: false,
                    cautionThreshold: 0.60, warningThreshold: 0.90,
                    sortOrder: .manual, grouping: .status, disconnectedServices: .collapsed,
                    showsAllAccounts: false, hidesQuotalessServices: false, showsHeaderSummary: true,
                    menuBarLabel: .iconOnly, menuBarValue: .highest,
                    menuBarBarCount: 4, menuBarColour: .monochrome, menuBarGlyphHeight: 13
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
        public var usesGradientFill: Bool
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
        public var menuBarBarCount: Int
        public var menuBarColour: MenuBarColour
        public var menuBarGlyphHeight: Double

        public init(
            density: Density = .cozy,
            textScale: Double = 1.0,
            logoStyle: LogoStyle = .tile,
            logoSize: Double = 30,
            panelWidth: Double = 356,
            rowBackground: RowBackground = .hover,
            showsPercentage: Bool = true,
            showsAmounts: Bool = true,
            showsCountdowns: Bool = true,
            showsPlanNames: Bool = true,
            showsAccountLabels: Bool = true,
            secondaryWindows: SecondaryWindowStyle = .expanded,
            secondaryWindowLimit: Int = 4,
            rowActions: RowActionVisibility = .onHover,
            meterStyle: MeterStyle = .bar,
            meterThickness: Double = 5,
            colorRamp: ColorRamp = .usage,
            usesGradientFill: Bool = true,
            cautionThreshold: Double = 0.60,
            warningThreshold: Double = 0.85,
            sortOrder: SortOrder = .urgency,
            grouping: Grouping = .status,
            disconnectedServices: DisconnectedDisplay = .collapsed,
            showsAllAccounts: Bool = false,
            hidesQuotalessServices: Bool = false,
            showsHeaderSummary: Bool = true,
            menuBarLabel: MenuBarLabelStyle = .iconAndPercent,
            menuBarValue: MenuBarValue = .highest,
            menuBarBarCount: Int = 4,
            menuBarColour: MenuBarColour = .perBar,
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
            self.usesGradientFill = usesGradientFill
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
            self.menuBarBarCount = menuBarBarCount
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
            usesGradientFill: usesGradientFill,
            cautionThreshold: cautionThreshold, warningThreshold: warningThreshold,
            sortOrder: sortOrder, grouping: grouping, disconnectedServices: disconnectedServices,
            showsAllAccounts: showsAllAccounts, hidesQuotalessServices: hidesQuotalessServices,
            showsHeaderSummary: showsHeaderSummary,
            menuBarLabel: menuBarLabel, menuBarValue: menuBarValue,
            menuBarBarCount: menuBarBarCount, menuBarColour: menuBarColour,
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
        usesGradientFill = snapshot.usesGradientFill
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
        menuBarBarCount = snapshot.menuBarBarCount
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

    private enum Key: String {
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
        case usesGradientFill = "aibars.appearance.usesGradientFill"
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
        case menuBarBarCount = "aibars.appearance.menuBarBarCount"
        case menuBarColour = "aibars.appearance.menuBarColour"
        case menuBarGlyphHeight = "aibars.appearance.menuBarGlyphHeight"
        case didMigrate = "aibars.appearance.didMigrateFromAppState"
    }

    private let store: UserDefaults
    /// Suppresses the per-property writes while a whole configuration is being
    /// loaded or applied, so the store is touched once at the end instead of
    /// thirty-one times — and so the clamps can see every value in place.
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
        logoSize = min(max(logoSize, 18), 40)
        panelWidth = min(max(panelWidth, 300), 520)
        secondaryWindowLimit = min(max(secondaryWindowLimit, 1), 6)
        meterThickness = min(max(meterThickness, 3), 12)
        menuBarBarCount = min(max(menuBarBarCount, 1), 6)
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
        write(usesGradientFill, .usesGradientFill)
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
        write(menuBarBarCount, .menuBarBarCount)
        write(menuBarColour.rawValue, .menuBarColour)
        write(menuBarGlyphHeight, .menuBarGlyphHeight)
    }

    /// One-time import of the four settings AppState used to own.
    ///
    /// The old keys are left in place. They cost nothing, and deleting them
    /// means a user who downgrades loses settings they never changed.
    private func migrateLegacyKeys() {
        guard !store.bool(forKey: Key.didMigrate.rawValue) else { return }

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
    // by type rather than overloaded so thirty-one call sites in a row don't
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
