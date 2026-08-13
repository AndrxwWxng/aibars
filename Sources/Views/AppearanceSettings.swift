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
            // every appearance and for every brand, with no edge on it, so a
            // label promising a tint would be describing a drawing the app
            // stopped making.
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
            // Not "Full bars". It draws no bars at all and has not for two
            // passes — a second full-width track per window cost 24pt of row
            // height each and painted the panel one colour, so an expanded
            // window is a label and a figure on a line of its own. A setting
            // named for a drawing the app deleted is a setting that lies in the
            // one place a user goes to find out what it does.
            case .expanded: return "One line per window"
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

    /// What the strip draws per service.
    ///
    /// Six styles, and the case names are the drawings. The first three keep the
    /// raw values the retired `MenuBarLabelStyle` shipped — `"percent"`,
    /// `"percentOnly"`, `"icon"` — because those strings are already sitting in
    /// people's defaults, and a case renamed for readability that takes its raw
    /// value with it is a preference silently dropped on upgrade. The three new
    /// ones are spelled for what they draw.
    ///
    /// The setting was inert for the whole of the strip's first life: declared,
    /// persisted, written by three presets and compared by `matchingPreset`, and
    /// read by nothing that draws. Applying Minimal wrote "Figures only" into the
    /// store and the strip carried on drawing marks and figures. Each case is a
    /// type in `Sources/Views/StripStyles/` now, the Appearance pane draws a chip
    /// per case with the drawing itself inside it, and the presets point at what
    /// they always meant — Minimal at `.figureOnly`, Monochrome at `.markOnly`
    /// (see `Preset.snapshot`).
    ///
    /// `showsGlyph` and `showsFigure` went with the rename, and not as a tidy-up.
    /// Two booleans span four combinations and there are six styles: `microBars`
    /// shows neither a mark nor a figure, `markAndMeter` shows a mark and a
    /// magnitude that is not a figure, and `worstOnly` shows a *word* and a
    /// figure. Any predicate pair would have had to answer for drawings it
    /// cannot name, which is how the Appearance preview and the renderer come to
    /// disagree about what a style means. The renderer switches over the case.
    ///
    /// `.iconAndName` — icon plus rotating service names — stays retired.
    /// Rotating a name through a single slot was the old strip's way of saying
    /// which service the number belonged to; a per-service brand mark says it
    /// continuously and without waiting. A stored `"name"` no longer parses and
    /// `migrateLegacyKeys` rewrites the dead string.
    public enum MenuBarStyle: String, CaseIterable, Identifiable {
        case markAndFigure = "percent"
        case figureOnly    = "percentOnly"
        case markOnly      = "icon"
        case microBars     = "bars"
        case markAndMeter  = "markBar"
        case worstOnly     = "worst"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .markAndFigure: return "Mark + figure"
            case .figureOnly:    return "Figures only"
            case .markOnly:      return "Marks only"
            case .microBars:     return "Micro bars"
            case .markAndMeter:  return "Mark + meter"
            case .worstOnly:     return "Closest to its cap"
            }
        }

        /// The sentence under the chip in the Appearance pane.
        ///
        /// Each one names the style's cost as well as its shape, because the
        /// choice between them is a trade the user is making with a bar that is
        /// 148pt wide at most: width against identity against a reading. The
        /// widths quoted are the arithmetic at the shipped 13pt strip height.
        public var summary: String {
            switch self {
            case .markAndFigure:
                return "A brand mark and its own reading per service. 127pt at three services."
            case .figureOnly:
                return "One number, no mark. One service only — three bare figures say nothing about which service each belongs to."
            case .markOnly:
                return "Silhouettes, tinted by how close each service is to its cap. Nothing is tinted under Monochrome."
            case .microBars:
                return "One column per service on a shared baseline. The only style that still measures under Monochrome, and the only one that does not say which column is which."
            case .markAndMeter:
                return "A mark and a small column beside it. Identity and a magnitude in 21pt a service."
            case .worstOnly:
                return "One service — whichever is nearest its cap — spelled out with its reading."
            }
        }
    }

    // MARK: - Density and size

    @Published public var density: Density { didSet { write(density.rawValue, .density) } }
    @Published public var textScale: Double { didSet { clampAndWrite(\.textScale, 0.85...1.30, .textScale) } }
    @Published public var logoStyle: LogoStyle { didSet { write(logoStyle.rawValue, .logoStyle) } }
    /// The floor is 16 rather than 18 because two presets ask for a 16pt mark:
    /// with a mark sitting on the ground instead of on a plate, the size that
    /// reads well beside a 12pt name in Compact is below what a plate needed.
    @Published public var logoSize: Double { didSet { clampAndWrite(\.logoSize, 16...40, .logoSize) } }
    /// Whether a live row's brand mark carries the brand's own hue.
    ///
    /// The escape hatch, and the only one: everything else about a mark — its
    /// box, its optical scale, its two neutral inks — is fixed. Off, every mark
    /// in the application draws `Ink.mark` exactly as it did before this
    /// existed, and no contrast ratio anywhere moves, because the live band
    /// holds `Ink.mark`'s own lightness and differs from it by at most 0.35:1 on
    /// any ground in the app. That is what makes this a colour switch rather
    /// than a look: turning it off removes a hue and moves no measurement.
    @Published public var coloursBrandMarks: Bool { didSet { write(coloursBrandMarks, .coloursBrandMarks) } }
    @Published public var panelWidth: Double { didSet { clampAndWrite(\.panelWidth, 300...520, .panelWidth) } }
    @Published public var rowBackground: RowBackground { didSet { write(rowBackground.rawValue, .rowBackground) } }

    // MARK: - What a row shows

    @Published public var showsPercentage: Bool { didSet { write(showsPercentage, .showsPercentage) } }
    @Published public var showsAmounts: Bool { didSet { write(showsAmounts, .showsAmounts) } }
    @Published public var showsCountdowns: Bool { didSet { write(showsCountdowns, .showsCountdowns) } }
    @Published public var showsPlanNames: Bool { didSet { write(showsPlanNames, .showsPlanNames) } }
    @Published public var showsAccountLabels: Bool { didSet { write(showsAccountLabels, .showsAccountLabels) } }
    /// Whether every connected row reserves a slot for its twenty-four-hour trace.
    ///
    /// It lives here and not in the store that holds the samples, and the
    /// difference is geometry. A drawing that costs nothing when it says nothing
    /// can have its switch wherever its data lives; a trace that is absent still
    /// costs its slot, because reserving the slot whether or not there is a day
    /// of history behind it is the only way the row's height stays a function of
    /// the settings. So this is a measurement, and measurements are
    /// `AppearanceSettings`'.
    @Published public var showsRowSparkline: Bool { didSet { write(showsRowSparkline, .showsRowSparkline) } }
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

    @Published public var menuBarStyle: MenuBarStyle { didSet { write(menuBarStyle.rawValue, .menuBarStyle) } }
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
        Self.adoptCurrentLook(in: store)
        // Every fallback comes from Snapshot's own defaults, so "the default of
        // this setting" is written down exactly once.
        let defaults = Snapshot()

        self.density = Self.readCase(store, .density) ?? defaults.density
        self.textScale = Self.readDouble(store, .textScale) ?? defaults.textScale
        self.logoStyle = Self.readCase(store, .logoStyle) ?? defaults.logoStyle
        self.logoSize = Self.readDouble(store, .logoSize) ?? defaults.logoSize
        self.coloursBrandMarks = Self.readBool(store, .coloursBrandMarks) ?? defaults.coloursBrandMarks
        self.panelWidth = Self.readDouble(store, .panelWidth) ?? defaults.panelWidth
        self.rowBackground = Self.readCase(store, .rowBackground) ?? defaults.rowBackground

        self.showsPercentage = Self.readBool(store, .showsPercentage) ?? defaults.showsPercentage
        self.showsAmounts = Self.readBool(store, .showsAmounts) ?? defaults.showsAmounts
        self.showsCountdowns = Self.readBool(store, .showsCountdowns) ?? defaults.showsCountdowns
        self.showsPlanNames = Self.readBool(store, .showsPlanNames) ?? defaults.showsPlanNames
        self.showsAccountLabels = Self.readBool(store, .showsAccountLabels) ?? defaults.showsAccountLabels
        self.showsRowSparkline = Self.readBool(store, .showsRowSparkline) ?? defaults.showsRowSparkline
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
        // `.markAndFigure`; `migrateLegacyKeys` rewrites the dead string.
        self.menuBarStyle = Self.readCase(store, .menuBarStyle) ?? defaults.menuBarStyle
        self.menuBarValue = Self.readCase(store, .menuBarValue) ?? defaults.menuBarValue
        // A stored bar count is a count of the same kind of thing — how many
        // services the item speaks for — so it carries over rather than being
        // discarded. `normalize` is what pulls a stored 4 or 6 into range.
        //
        // This line only started doing anything in this pass. `adoptCurrentLook`
        // runs above and used to remove the legacy key before this read, so the
        // carry-over ran for scratch domains and never once for a real install;
        // see `Key.survivesLookAdoption` for the exemption that fixed it.
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

        /// The box a row's sparkline is drawn in, when the setting reserves one.
        ///
        /// Derived from `detailSize` rather than from `barHeight`, and the two
        /// are different questions: the meter's thickness is a taste the user
        /// sets, and this is a trace that has to be tall enough for a shape to be
        /// read off it. 1.6 lands it at 16 / 18 / 19pt across the three densities
        /// — 10 × 1.6 = 16, 11 × 1.6 = 17.6 → 18, 12 × 1.6 = 19.2 → 19 — three
        /// distinct heights, each shorter at the shipped text scale than the ring
        /// its own density draws beside it (16 < 18, 18 < 22, 19 < 26), so the
        /// sparkline never out-measures the meter it annotates. It moves with
        /// text scale for free, which is what stops a user at 130% getting a
        /// trace they cannot see the shape of.
        ///
        /// The floor is for a `Metrics` built by hand in a test; `detailSize`
        /// itself floors at 10, so 12 never binds in the app.
        public var sparklineHeight: CGFloat { max(12, (detailSize * 1.6).rounded()) }

        /// The width reserved for the headline figure and its unit: three digits,
        /// a hairline, and one unit character.
        ///
        /// Reserved rather than measured, because tabular digits fix the width of
        /// a digit and not the length of a string: `9%` still reflows to `92%`
        /// when a row ticks over. The rail's own width differs line by line — the
        /// secondary rail is narrower — but every rail on a row ends at the same
        /// trailing edge, and that shared edge is the column the eye scans down.
        ///
        /// The reservation is SF Mono's advance, and only SF Mono's: `"100%"` set
        /// in the mono design measures 32.14pt at 13pt inside a 33pt rail, and the
        /// same string in SF Pro measures 36.29pt and hangs out of it. Anyone
        /// tempted to "simplify" the figure's mono design away has to widen this
        /// first, or the one reading that matters most is the one drawn outside
        /// its own column.
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
            // rounded caps. Six tenths of the shipped 5pt bar is 3pt, which is
            // the budget bar the panel actually draws: thinner than the reading
            // above it, still a bar.
            secondaryBarHeight: max(2, thickness * 0.6),
            ringDiameter: min(step.ring * scale, ringBudget)
        )
    }

    /// The widest the dial may be drawn.
    ///
    /// The leading column is the logo, a 6pt gap and the dial, all subtracted
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
    /// The unit tick beside the figure is not this colour. It stays muted in
    /// every band and under every ramp, because it annotates the number rather
    /// than being part of the reading, and a neutral unit is what keeps the
    /// digits the only coloured column.
    public func figureTint(for percent: Double, providerAccent: Color) -> Color {
        guard colorRamp == .usage, percent < cautionThreshold else {
            return tint(for: percent, providerAccent: providerAccent)
        }
        return Tokens.Ink.body
    }

    /// The same rule for a reading that is not the row's headline — a further
    /// window's chip on the caption line.
    ///
    /// One rung quieter at rest, and the reason is a measured inversion rather
    /// than a preference. The Claude row's headline `92%` draws `Ink.attention`,
    /// which was L\* 65.73 when this was written and is 76.92 now; its two chips
    /// drew `Ink.body` at 95.82, so the two least important numbers on the row
    /// were **2.37:1 brighter than the most important one** — visible in colour,
    /// not merely in greyscale. The re-cut narrowed that to 1.68:1 and did not
    /// close it, which is the point: the inversion was never about how light the
    /// amber happened to be. A panel
    /// whose whole hierarchy is two inks and one weight step cannot afford a
    /// subordinate reading at the top of the ladder.
    ///
    /// `Ink.mark` and not a fourth grey: it is the rung between `body` and
    /// `muted` that the palette already holds, so the chip keeps its own
    /// label/reading step (muted → mark) and loses only its claim on the row.
    /// 1.52:1 under `body` dark and 1.55:1 light, which is the same step the
    /// panel uses everywhere to mean "one rank down".
    ///
    /// Above caution it defers to `figureTint` completely, which is the point of
    /// writing it as a delegation: a further window that is itself near its cap
    /// is a measurement wanting attention and gets the whole ramp. Only the
    /// resting rung moves.
    public func chipFigureTint(for percent: Double, providerAccent: Color) -> Color {
        let tint = figureTint(for: percent, providerAccent: providerAccent)
        guard colorRamp == .usage, percent < cautionThreshold else { return tint }
        return Tokens.Ink.mark
    }

    /// The ink a provider's mark is drawn in, on every surface that draws one.
    ///
    /// The single place that decision is made, and it has to live here rather
    /// than on `ProviderLogo` because two of its three inputs are settings. The
    /// previous arrangement put the rule in `ProviderLogo.markInk(isLive:)` and
    /// then gave the parameter beside it a `nil`-means-live default, so four of
    /// the five views that draw a mark never called it: the Settings list, the
    /// Budget pane, the connect dialog and the Appearance sample all drew every
    /// mark at the reporting ink. A signed-out Claude in Settings was inked
    /// identically to a healthy one, in the one list whose job is to say which
    /// services need you.
    ///
    /// Three answers, in this order:
    ///
    /// - **Not reporting** — loading, failed, expired, locked, not connected,
    ///   switched off — is `Ink.muted`, unchanged by this rule. It is the ink the
    ///   row's name and caption take in the same state, so "nothing here yet"
    ///   stays one statement in one ink rather than three treatments.
    /// - **Reporting, with the hue suppressed** is `Ink.mark`, also unchanged.
    ///   Two things suppress it: the user's own switch, and `ColorRamp.provider`.
    /// - **Reporting, otherwise** is the brand's hue at `Ink.mark`'s lightness.
    ///
    /// `.provider` is in the second branch and that is the whole of the double-up
    /// rule. Under that ramp the bar, the ring and the figure are already painted
    /// `AnyUsageProvider.accentColor`, which is the same brand through
    /// `BrandMark.brandInk`; colouring the mark too would leave a row whose mark,
    /// meter and number are three shades of one hue — a fully coloured row, which
    /// is exactly what "chroma means measurement or state" exists to prevent.
    /// Brand hue appears at most once per row, and the meter wins, because the
    /// meter is the thing the user switched the ramp to colour. `.usage`,
    /// `.accent` and `.mono` spend no brand hue on the meter, so under those
    /// three the mark is free to carry it.
    ///
    /// A service with no vector mark draws a lettermark, and a lettermark has no
    /// brand colour to lend — it falls to `Ink.mark`, not to the user's accent.
    public func markInk(for serviceID: String, isLive: Bool) -> Color {
        guard isLive else { return Tokens.Ink.muted }
        guard coloursBrandMarks, colorRamp != .provider else { return Tokens.Ink.mark }
        return BrandMark.mark(for: serviceID)?.liveInk ?? Tokens.Ink.mark
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
    /// `.urgency` preserves. This superseded `AppState.visibleProviders`, which is
    /// deleted; its account collapsing is the only part of that behaviour it kept.
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
                // Named for what it turns on rather than "everything on": the
                // pane has a dozen switches this preset leaves off, and a summary
                // that overstates its preset is how a user comes to distrust the
                // other four.
                return "The shipped look. Amounts and countdowns on, urgency order, connected services first with the rest folded away."
            case .compact:
                return "Every service on screen at once. Keeps the bars and the numbers, drops the prose."
            case .minimal:
                return "A name and a number per service, in a stable alphabetical order."
            case .dashboard:
                return "Every window, every account, every service, grouped by how close to the cap they are."
            case .monochrome:
                // The marks are back in the sentence, and they mean something
                // different from the tiles the old wording promised: the plates
                // are gone from every preset, so a mark's own hue is the last
                // brand colour left in the panel and this is the one preset that
                // turns it off. The ramp is the other half — every meter grey at
                // every level, right up to the warning — and the warning is the
                // one moment the whole preset spends a colour, in the panel and
                // in the bar alike.
                return "Greyscale rings and greyscale marks on a bare list. Colour returns only above the warning threshold."
            }
        }

        /// The values this preset stands for. A table, so applying a preset and
        /// recognising one can never drift apart.
        ///
        /// Three of these values were deliberately identical in all five presets
        /// until this pass — `coloursBrandMarks: true`, `showsRowSparkline: false`,
        /// `menuBarStyle: .markAndFigure` — and the rule that held them there is
        /// worth keeping written down, because it is the rule the next feature
        /// will be governed by. A preset is a promise about what the app will look
        /// like the instant it is applied, so a preset may only name a drawing
        /// that exists. Naming `.figureOnly` while the renderer drew one strip
        /// would have written a preference nothing read; reserving a trace before
        /// the row drew one would have changed nothing and then changed the
        /// panel's height a release later. So each flip waited for the pass that
        /// shipped its drawing, and this is that pass: the styles are six types in
        /// `Sources/Views/StripStyles/`, the trace is `RowSparkline`, and the
        /// three promises are kept in the same commit as the chooser that lets a
        /// user make them by hand.
        ///
        /// Two presets are untouched, and that is a decision rather than an
        /// omission. Comfortable *is* `Snapshot()` — moving it moves what a fresh
        /// install looks like — and Compact's entire claim is every service on
        /// screen at once, which is the first claim a reserved trace spends.
        public var snapshot: Snapshot {
            switch self {
            case .comfortable:
                // The defaults themselves, spelled `Snapshot()` so a fresh
                // install recognises the preset it is already on and "reset"
                // lands on it exactly. Named for how it reads beside Compact
                // and Minimal, not after `Density.comfortable`: the panel
                // ships at cozy with a 4pt bar, and an upgrade that loosened
                // every row on its own would be this refactor changing the app
                // rather than reorganising it. The three values the other four
                // presets spell out are the defaults as well, and this is the
                // preset that cannot flip any of them: it is the shipped look by
                // definition, so a flip here is not a preset changing, it is the
                // app changing under everyone who never picked one.
                return Snapshot()
            case .compact:
                return Snapshot(
                    density: .compact, textScale: 1.0,
                    // It already folded its windows onto one line; only the
                    // plate and the thresholds were off-message.
                    logoStyle: .plain, logoSize: 16, coloursBrandMarks: true,
                    panelWidth: 340, rowBackground: .always,
                    showsPercentage: true, showsAmounts: false, showsCountdowns: true,
                    showsPlanNames: false, showsAccountLabels: false,
                    // Every service on screen at once is the whole preset, and a
                    // reserved trace is 24pt a row against rows that are 38.
                    showsRowSparkline: false,
                    secondaryWindows: .chips, secondaryWindowLimit: 3, rowActions: .onHover,
                    // The bar is the shipped 5pt even here. Compact buys its
                    // density from line-height, and a preset that fits every
                    // service on screen is the last one that can afford a meter
                    // too thin to show a single-digit reading.
                    meterStyle: .bar, meterThickness: 5, colorRamp: .usage,
                    cautionThreshold: 0.80, warningThreshold: 0.95,
                    sortOrder: .urgency, grouping: .flat, disconnectedServices: .collapsed,
                    showsAllAccounts: false, hidesQuotalessServices: false, showsHeaderSummary: true,
                    menuBarStyle: .markAndFigure, menuBarValue: .highest,
                    menuBarServiceCount: 3, menuBarColour: .alertOnly, menuBarGlyphHeight: 13
                )
            case .minimal:
                return Snapshot(
                    density: .compact, textScale: 1.0,
                    // The preset the whole direction was always closest to: a
                    // plain mark, no windows, no meter. Only the mark was big.
                    logoStyle: .plain, logoSize: 16, coloursBrandMarks: true,
                    panelWidth: 300, rowBackground: .plain,
                    showsPercentage: true, showsAmounts: false, showsCountdowns: false,
                    showsPlanNames: false, showsAccountLabels: false,
                    showsRowSparkline: false,
                    secondaryWindows: .hidden, secondaryWindowLimit: 1, rowActions: .never,
                    meterStyle: .numberOnly, meterThickness: 4, colorRamp: .usage,
                    cautionThreshold: 0.80, warningThreshold: 0.95,
                    sortOrder: .alphabetical, grouping: .flat, disconnectedServices: .hidden,
                    showsAllAccounts: false, hidesQuotalessServices: true, showsHeaderSummary: false,
                    // One number in the bar, and the count that was always sized
                    // for it. Three bare figures side by side have nothing to say
                    // which service each belongs to — the fault the per-service
                    // marks were added to fix — so `.figureOnly` carries a ceiling
                    // of one in the style itself, and this preset's count of one
                    // is the same statement made from the other end. They agree
                    // rather than one clamping the other, which is what lets the
                    // pane grey the stepper out here without rewriting the number
                    // behind it.
                    menuBarStyle: .figureOnly, menuBarValue: .highest,
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
                    logoStyle: .plain, logoSize: 22, coloursBrandMarks: true,
                    panelWidth: 460, rowBackground: .always,
                    showsPercentage: true, showsAmounts: true, showsCountdowns: true,
                    showsPlanNames: true, showsAccountLabels: true,
                    // The one preset that turns the trace on, because it is the
                    // one for someone who wants everything and the only one that
                    // can afford it. The cost is the 24pt a connected row the
                    // default's own note totals up, and a little more here — this
                    // is the comfortable density at 105% type, where the trace is
                    // 19pt before its pitch. On a 460pt panel with every window
                    // and every account already expanded that is in keeping;
                    // anywhere else it is the preset's own claim being spent.
                    showsRowSparkline: true,
                    secondaryWindows: .expanded, secondaryWindowLimit: 6, rowActions: .always,
                    meterStyle: .bar, meterThickness: 5, colorRamp: .usage,
                    cautionThreshold: 0.75, warningThreshold: 0.92,
                    sortOrder: .urgency, grouping: .usageBand, disconnectedServices: .shown,
                    showsAllAccounts: true, hidesQuotalessServices: false, showsHeaderSummary: true,
                    menuBarStyle: .markAndFigure, menuBarValue: .average,
                    menuBarServiceCount: 3, menuBarColour: .perBar, menuBarGlyphHeight: 14
                )
            case .monochrome:
                return Snapshot(
                    density: .cozy, textScale: 1.0,
                    logoStyle: .plain, logoSize: 18,
                    // The last brand colour in the panel, off. Everything else
                    // here was already greyscale — the ramp, the rings, the plate
                    // that is gone from every preset — and a mark in Anthropic's
                    // orange was the one hue left standing in a preset named for
                    // having none. The summary above promises it in the same
                    // commit, which is the whole reason this waited: a preset that
                    // says "greyscale marks" and draws orange ones is worse than
                    // one that never claimed it.
                    //
                    // The cost, stated because somebody will see it and file it:
                    // an install already on Monochrome has no `coloursBrandMarks`
                    // in its store, so it reads the default `true`, and the moment
                    // this ships their pane says Custom until they click the chip
                    // again. That is the honest failure — the alternative is
                    // adopting the flip into everyone's store from
                    // `adoptCurrentLook`, which would reach every user who never
                    // chose this preset.
                    coloursBrandMarks: false,
                    panelWidth: 356, rowBackground: .plain,
                    showsPercentage: true, showsAmounts: true, showsCountdowns: true,
                    showsPlanNames: false, showsAccountLabels: true,
                    showsRowSparkline: false,
                    secondaryWindows: .chips, secondaryWindowLimit: 3, rowActions: .onHover,
                    meterStyle: .ring, meterThickness: 4, colorRamp: .mono,
                    // The warning is the one moment this preset spends a colour,
                    // so it spends it where every other preset does.
                    cautionThreshold: 0.60, warningThreshold: 0.95,
                    sortOrder: .manual, grouping: .status, disconnectedServices: .collapsed,
                    showsAllAccounts: false, hidesQuotalessServices: false, showsHeaderSummary: true,
                    // Silhouettes, two of them, and the one colour setting this
                    // preset is allowed. The count was already sized for this
                    // style: under `.markOnly` a third undifferentiated mark adds
                    // width without adding a reading.
                    //
                    // `.alertOnly` rather than the `.monochrome` this preset used
                    // to carry, and it is not a softening of the preset. Under
                    // `.markOnly` the mark *is* the reading — there is no figure
                    // and no column, so the tint is the only channel left — and
                    // `.monochrome` would have left this strip with identity and
                    // no reading at all. Below the warning it is still a template
                    // and still takes the menu bar's own light, dark and vibrancy
                    // treatment, which is the case that is true almost all of the
                    // time; above it the strip spends a colour exactly where the
                    // panel beside it does.
                    menuBarStyle: .markOnly, menuBarValue: .highest,
                    menuBarServiceCount: 2, menuBarColour: .alertOnly, menuBarGlyphHeight: 13
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
        public var coloursBrandMarks: Bool
        public var panelWidth: Double
        public var rowBackground: RowBackground
        public var showsPercentage: Bool
        public var showsAmounts: Bool
        public var showsCountdowns: Bool
        public var showsPlanNames: Bool
        public var showsAccountLabels: Bool
        public var showsRowSparkline: Bool
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
        public var menuBarStyle: MenuBarStyle
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
            // On, and it is the one default here that can be argued both ways,
            // so the argument is written down. A brand mark in its own hue is
            // the one place the panel spends colour on identity rather than on
            // measurement, and that is a rule this design otherwise holds
            // absolutely. It is allowed because the live band holds `Ink.mark`'s
            // own lightness: the hue arrives, the weight does not move, and
            // every ink in the panel measures within 0.35:1 of what it measured
            // before. The alternative — off by default, on by choice — ships
            // fifteen identical grey silhouettes to every new install, which
            // makes a mark worth less than the first letter of its own name.
            coloursBrandMarks: Bool = true,
            panelWidth: Double = 356,
            rowBackground: RowBackground = .hover,
            showsPercentage: Bool = true,
            showsAmounts: Bool = true,
            showsCountdowns: Bool = true,
            // On, because the plan no longer costs a shape to say. It used to be
            // a filled capsule — chrome, on every row, around the one word on
            // the line that never changes — and it is now the tail of the same
            // muted run as the account: `ada@example.com · Pro`.
            showsPlanNames: Bool = true,
            showsAccountLabels: Bool = true,
            // Off, and the four reasons are about what "on by default" would
            // cost rather than about whether the drawing is any good. It costs
            // height that cannot be reclaimed: 18pt of trace plus 6pt of pitch
            // is 24pt per connected row, and nine rows is 216pt on a panel whose
            // rows are 38–66pt — half a panel again, for a drawing about
            // yesterday. It is empty exactly when a user is most likely to see
            // it, because a fresh install has no history, so on by default ships
            // as fifteen blank reserved slots that read as a rendering fault
            // rather than as a feature waiting for data. It is the only optional
            // drawing in the row that has to reserve at all — the pace line is
            // on by default precisely because it costs nothing when it says
            // nothing. And it is a second reading of a window the row already
            // reports: a default should be the smallest panel that answers "how
            // much have I got left", and this answers "and how did I get here",
            // which is a question the user asks by turning it on.
            showsRowSparkline: Bool = false,
            // The windows fold onto the trailing half of the caption line. A
            // second full-width bar per row cost 24pt each and was what turned
            // one service crossing a threshold into a panel washed in amber.
            secondaryWindows: SecondaryWindowStyle = .chips,
            secondaryWindowLimit: Int = 4,
            rowActions: RowActionVisibility = .onHover,
            meterStyle: MeterStyle = .bar,
            // 5 and not 4. A one-digit reading is the case that decides this: at
            // 4pt, 7% of a 278pt track is 19.5 × 4pt of resting grey, which has
            // no mass and reads as an empty track — the meter stops measuring at
            // exactly the readings only the meter can show. A point buys the
            // stub presence, costs the row nothing that density does not already
            // spend, and lands the secondary bar on a clean 3pt.
            meterThickness: Double = 5,
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
            menuBarStyle: MenuBarStyle = .markAndFigure,
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
            self.coloursBrandMarks = coloursBrandMarks
            self.panelWidth = panelWidth
            self.rowBackground = rowBackground
            self.showsPercentage = showsPercentage
            self.showsAmounts = showsAmounts
            self.showsCountdowns = showsCountdowns
            self.showsPlanNames = showsPlanNames
            self.showsAccountLabels = showsAccountLabels
            self.showsRowSparkline = showsRowSparkline
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
            self.menuBarStyle = menuBarStyle
            self.menuBarValue = menuBarValue
            self.menuBarServiceCount = menuBarServiceCount
            self.menuBarColour = menuBarColour
            self.menuBarGlyphHeight = menuBarGlyphHeight
        }
    }

    public var snapshot: Snapshot {
        Snapshot(
            density: density, textScale: textScale,
            logoStyle: logoStyle, logoSize: logoSize, coloursBrandMarks: coloursBrandMarks,
            panelWidth: panelWidth, rowBackground: rowBackground,
            showsPercentage: showsPercentage, showsAmounts: showsAmounts, showsCountdowns: showsCountdowns,
            showsPlanNames: showsPlanNames, showsAccountLabels: showsAccountLabels,
            showsRowSparkline: showsRowSparkline,
            secondaryWindows: secondaryWindows, secondaryWindowLimit: secondaryWindowLimit, rowActions: rowActions,
            meterStyle: meterStyle, meterThickness: meterThickness, colorRamp: colorRamp,
            cautionThreshold: cautionThreshold, warningThreshold: warningThreshold,
            sortOrder: sortOrder, grouping: grouping, disconnectedServices: disconnectedServices,
            showsAllAccounts: showsAllAccounts, hidesQuotalessServices: hidesQuotalessServices,
            showsHeaderSummary: showsHeaderSummary,
            menuBarStyle: menuBarStyle, menuBarValue: menuBarValue,
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
        coloursBrandMarks = snapshot.coloursBrandMarks
        panelWidth = snapshot.panelWidth
        rowBackground = snapshot.rowBackground
        showsPercentage = snapshot.showsPercentage
        showsAmounts = snapshot.showsAmounts
        showsCountdowns = snapshot.showsCountdowns
        showsPlanNames = snapshot.showsPlanNames
        showsAccountLabels = snapshot.showsAccountLabels
        showsRowSparkline = snapshot.showsRowSparkline
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
        menuBarStyle = snapshot.menuBarStyle
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

    /// Internal rather than private, and the reason is a test that could not be
    /// written.
    ///
    /// `adoptCurrentLook` empties this domain once per look generation, so the
    /// question "is the hotkey binding inside the wipe?" is a question about
    /// these raw values. `HotkeyStoreTests` could only ask it through the string
    /// prefix, because `@testable` raises internal to public and leaves private
    /// alone — so the enum the wipe iterates was not nameable from the test that
    /// exists to bound it, and the test asserted a property of the *prefix*
    /// instead of a property of the *set*.
    ///
    /// Internal is the smallest widening that fixes that: nothing outside this
    /// module can see it, `AppearanceSettings` being public does not carry it
    /// into the public API, and `testNoAppearanceKeyCollidesWithTheBinding` can
    /// now walk `Key.allCases` and compare the real strings.
    enum Key: String, CaseIterable {
        case density = "aibars.appearance.density"
        case textScale = "aibars.appearance.textScale"
        case logoStyle = "aibars.appearance.logoStyle"
        case logoSize = "aibars.appearance.logoSize"
        case coloursBrandMarks = "aibars.appearance.coloursBrandMarks"
        case panelWidth = "aibars.appearance.panelWidth"
        case rowBackground = "aibars.appearance.rowBackground"
        case showsPercentage = "aibars.appearance.showsPercentage"
        case showsAmounts = "aibars.appearance.showsAmounts"
        case showsCountdowns = "aibars.appearance.showsCountdowns"
        case showsPlanNames = "aibars.appearance.showsPlanNames"
        case showsAccountLabels = "aibars.appearance.showsAccountLabels"
        case showsRowSparkline = "aibars.appearance.showsRowSparkline"
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
        /// The strip style, still stored under the string the setting shipped
        /// with. The case is named for the property and the property is named
        /// for what it now controls, but the *key* is what a user's preference is
        /// filed under, and renaming a persisted key to tidy a call site is how a
        /// preference gets silently dropped on upgrade — the same rule
        /// `menuBarPercent` states for `menuBarValue` and keeps its own name for.
        case menuBarStyle = "aibars.appearance.menuBarLabel"
        case menuBarValue = "aibars.appearance.menuBarValue"
        case menuBarServiceCount = "aibars.appearance.menuBarServiceCount"
        case menuBarColour = "aibars.appearance.menuBarColour"
        case menuBarGlyphHeight = "aibars.appearance.menuBarGlyphHeight"
        case didMigrate = "aibars.appearance.didMigrateFromAppState"
        /// Which generation of the look the values in this store belong to. An Int
        /// rather than a Bool per generation, because the next pass that moves a
        /// default has to bump one number instead of inventing a fourth key and
        /// remembering to exempt it from the wipe below.
        case adoptedLookGeneration = "aibars.appearance.adoptedLookGeneration"

        /// Generation two's stamp, when the generation was spelled as a Bool.
        /// Read once, to place an existing install on the ladder, then deleted.
        case legacyDidAdoptSecondGeneration = "aibars.appearance.didAdoptSecondGeneration"

        /// Retired with the four abstract bars. Read once in `init` so a user who
        /// set a bar count keeps a service count near it, and never written.
        case legacyMenuBarBarCount = "aibars.appearance.menuBarBarCount"
        /// Retired outright: a gradient makes two bars of equal length look
        /// unequal at the tip, which is exactly the down-column comparison the
        /// figure rail and the pace notch are both built on. Named only so
        /// `migrateLegacyKeys` can delete it.
        case legacyGradientFill = "aibars.appearance.usesGradientFill"

        /// What the look adoption below leaves alone: the stamp itself, the record
        /// that the one-time import from AppState has already run, and the one
        /// legacy key `init` still reads. Clearing the import record would re-run
        /// the import, and a key written by a version two generations back would
        /// then overwrite exactly the defaults the wipe exists to deliver.
        ///
        /// `legacyMenuBarBarCount` is here because the wipe was eating it. The
        /// order is `adoptCurrentLook` (the first statement of `init`) → the reads
        /// → `migrateLegacyKeys`, so a key removed by the wipe is gone before the
        /// read at `menuBarServiceCount` can see it: a user who had set one bar
        /// silently got three services, and the carry-over — and the comment
        /// promising it — were dead code for the entire population they were
        /// written for. Nothing caught it because `adoptCurrentLook` returns early
        /// for every store except `UserDefaults.standard`, so the scratch domain
        /// the tests use never ran the wipe at all.
        ///
        /// Exempting it costs nothing beyond this launch: `migrateLegacyKeys`
        /// writes the clamped count under the current key and removes this one on
        /// the same launch it is read, so it survives the wipe exactly once and
        /// then is not there to survive anything.
        var survivesLookAdoption: Bool {
            switch self {
            case .adoptedLookGeneration, .didMigrate, .legacyMenuBarBarCount: return true
            default: return false
            }
        }
    }

    /// The look this build ships, and the only thing to change when a DEFAULT
    /// moves.
    ///
    /// 3: the bar went from 4pt to 5pt so a single-digit reading has mass, and the
    /// colour rule became "chroma means measurement or state" — which is carried by
    /// tokens for everybody, but only reaches a stored `meterThickness` of 4
    /// through the adoption below.
    ///
    /// Deliberately still 3 for `coloursBrandMarks`, `showsRowSparkline` and the
    /// six strip styles, and the next author to reach for this should read the
    /// reason first. Adoption exists to deliver a moved DEFAULT to an install that
    /// already has a value stored under that key. Both new keys have never been
    /// written for anybody, so `readBool ?? defaults` already lands every existing
    /// install on the shipped value at the next launch — there is nothing stored
    /// to overrule. And `menuBarStyle` keeps its key *and* its raw values, so what
    /// is stored there is either the shipped default or a value a preset wrote
    /// while saying what it wanted the strip to look like; honouring it is the fix
    /// this pass makes, not a regression to migrate away. A bump would clear every
    /// user's density, panel width, thresholds and custom order to correct
    /// precisely nothing.
    ///
    /// Still 3 for the three preset flips as well, and this is the one that looks
    /// most like a reason to bump. A preset table is not a default: nobody's store
    /// holds "Monochrome", it holds the thirty-two values that happened to equal
    /// Monochrome's, so an install already on it reads `coloursBrandMarks: true`
    /// and shows as Custom until the chip is clicked again. Bumping to close that
    /// gap would wipe the appearance domain of every user who never chose the
    /// preset in order to re-select it for the few who did — a change to everyone's
    /// app to correct one unhighlighted chip.
    private static let lookGeneration = 3

    /// Takes an existing install to the current look, once per generation.
    ///
    /// This exists because a redesign that only changes DEFAULTS changes nothing
    /// for anybody who has already run the app. Every setting is written to the
    /// store on `didSet`, and the first launch writes the lot, so by the second
    /// launch there are no unset values left for a new default to reach. The
    /// author saw the reskin land on tokens — surfaces, ink, type — while the
    /// structural half of it did not move at all: logos still in their old
    /// coloured tiles, a second full-width meter still on every row, the amber
    /// band still starting at 0.60. It looked like nothing had happened, because
    /// for the settings that were pinned, nothing had. It happened a second time
    /// with the bar: a 4pt meter written to the store two versions ago is a 4pt
    /// meter for ever, and the fix for an invisible one-digit reading would have
    /// shipped to new installs only.
    ///
    /// So the appearance domain is cleared once per generation and allowed to fall
    /// back to the new defaults. Deliberately blunt: there is no way to tell a
    /// value the user chose from a value the first launch happened to write, so
    /// preserving "customisations" would mean preserving the old design under a
    /// new name. Scoped tightly in return — only `aibars.appearance.*`, so
    /// sessions, budgets, alert rules, per-provider switches and account names are
    /// all untouched, and `customOrder` is the one appearance key that is a
    /// decision rather than a look, so it comes back empty and sorts in declared
    /// order rather than losing a row.
    private static func adoptCurrentLook(in store: UserDefaults) {
        // Only the real domain. A scratch domain is one a test or a preview
        // authored deliberately — several tests seed malformed values precisely
        // to prove a bad store cannot break the layout — and clearing those would
        // be this migration deciding it knows better than the fixture.
        guard store === UserDefaults.standard else { return }
        // Generation two stamped a Bool under its own key, so an install that has
        // already adopted that look counts as two rather than as never adopted;
        // anything else is generation zero and is about to get the lot anyway.
        let stamped = store.object(forKey: Key.adoptedLookGeneration.rawValue) as? Int
            ?? (store.bool(forKey: Key.legacyDidAdoptSecondGeneration.rawValue) ? 2 : 0)
        guard stamped < lookGeneration else { return }
        for key in Key.allCases where !key.survivesLookAdoption {
            store.removeObject(forKey: key.rawValue)
        }
        store.set(lookGeneration, forKey: Key.adoptedLookGeneration.rawValue)
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
        // Whole points only, and rounded *before* the clamp so the bounds stay
        // exact: 13.5 → 14, 9.6 → 10, 16.4 → 16. The tuner offered half steps and
        // the rasteriser rounds the width it measures but passes the height
        // through raw, so a stored 13.5 renders a soft strip at 1× for ever and
        // the readout beside the slider disagrees with the menu bar. Rounding on
        // read is the half of that fix that reaches an install which already has
        // a fractional value in its store; the tuner's step is the half that
        // stops another one being minted.
        menuBarGlyphHeight = min(max(menuBarGlyphHeight.rounded(), 10), 16)
        warningThreshold = min(max(warningThreshold, 0.50), 0.98)
        cautionThreshold = min(max(cautionThreshold, cautionRange.lowerBound), cautionRange.upperBound)
    }

    private func persistAll() {
        write(density.rawValue, .density)
        write(textScale, .textScale)
        write(logoStyle.rawValue, .logoStyle)
        write(logoSize, .logoSize)
        write(coloursBrandMarks, .coloursBrandMarks)
        write(panelWidth, .panelWidth)
        write(rowBackground.rawValue, .rowBackground)
        write(showsPercentage, .showsPercentage)
        write(showsAmounts, .showsAmounts)
        write(showsCountdowns, .showsCountdowns)
        write(showsPlanNames, .showsPlanNames)
        write(showsAccountLabels, .showsAccountLabels)
        write(showsRowSparkline, .showsRowSparkline)
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
        write(menuBarStyle.rawValue, .menuBarStyle)
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
        if store.string(forKey: Key.menuBarStyle.rawValue) == "name" {
            store.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle.rawValue)
        }

        guard !store.bool(forKey: Key.didMigrate.rawValue) else { return }

        // A raw value that no longer parses — "name" is the only one — leaves the
        // default in place, which is where the retirement above sends it anyway.
        if let raw = store.string(forKey: "aibars.menuBarDisplay"),
           let style = MenuBarStyle(rawValue: raw) {
            menuBarStyle = style
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
