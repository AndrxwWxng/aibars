import Foundation
import Combine

/// One spending limit: an amount, the currency it is stated in, and the
/// fractions of it worth being told about.
///
/// The amount is in minor units — 3284 is $32.84 — because money that round
/// trips through JSON as a Double eventually comes back as 32.839999999999996,
/// and because a budget is compared against a provider's own figure rather than
/// added to it.
///
/// The currency travels with the budget rather than sitting once on the store:
/// providers state their own (DeepSeek answers in CNY for some accounts and USD
/// for others) and nothing in this app converts between them. A budget is
/// compared against spend in its own currency or it is not compared at all.
public struct Budget: Codable, Equatable, Sendable {
    /// The limit, in minor units of `currency`. Never negative.
    public var amountMinor: Int

    /// ISO 4217, upper case. Not checked against a list of codes: a provider
    /// that starts reporting a currency this app has never heard of should
    /// still get a budget, and a code that is simply wrong is the user's to fix.
    public var currency: String

    /// Fractions of the amount that earn an alert, 0…1, ascending, at most
    /// four. 1.0 is a level like any other and is the one that means "this is
    /// the budget", so it is included by default.
    public var alertsAt: [Double]

    /// What a budget is stated in when nobody said. Public because whoever
    /// builds the editor has to seed a new budget with something.
    public static let defaultCurrency = "USD"

    /// One warning while there is still time to change course, and one at the
    /// budget itself.
    public static let defaultAlerts: [Double] = [0.80, 1.0]

    /// Values are cleaned here rather than trusted, because a bad number in
    /// UserDefaults outlives the session that produced it.
    public init(
        amountMinor: Int,
        currency: String = Budget.defaultCurrency,
        alertsAt: [Double] = Budget.defaultAlerts
    ) {
        self.amountMinor = max(0, amountMinor)
        self.currency = Budget.cleaned(currency)
        self.alertsAt = Budget.cleaned(alertsAt)
    }

    /// The same value with the initialiser's rules applied again. Used by the
    /// store on every write, so a budget mutated in place — `amountMinor = -1`
    /// on a `var` — cannot be persisted in a state the initialiser would have
    /// refused.
    var sanitised: Budget {
        Budget(amountMinor: amountMinor, currency: currency, alertsAt: alertsAt)
    }

    /// Decoded field by field rather than by synthesis, following
    /// `ThresholdRules`: adding a field in a later version should not make every
    /// stored budget undecodable and silently drop the amounts the user set.
    /// Delegating to the initialiser means the fallbacks and the cleaning are
    /// stated once each.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            amountMinor: try container.decodeIfPresent(Int.self, forKey: .amountMinor) ?? 0,
            currency: try container.decodeIfPresent(String.self, forKey: .currency)
                ?? Budget.defaultCurrency,
            alertsAt: try container.decodeIfPresent([Double].self, forKey: .alertsAt)
                ?? Budget.defaultAlerts
        )
    }

    private static func cleaned(_ currency: String) -> String {
        let trimmed = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.isEmpty ? defaultCurrency : trimmed
    }

    /// Levels are rounded to a basis point before they are deduplicated, so two
    /// spellings of eighty percent arriving from different places cannot both
    /// survive and alert twice. Capped at four, from the top: more spend alerts
    /// than that is noise, and if a list has to be cut it is the level nearest
    /// the budget that the user least wanted to lose.
    private static func cleaned(_ levels: [Double]) -> [Double] {
        var seen: Set<Double> = []
        var out: [Double] = []
        for level in levels where level.isFinite && level > 0 && level <= 1 {
            let rounded = (level * 10_000).rounded() / 10_000
            guard seen.insert(rounded).inserted else { continue }
            out.append(rounded)
        }
        return Array(out.sorted().suffix(4))
    }
}

/// The budgets the user set, and nothing else.
///
/// Deliberately small: one amount per service, one that covers everything, the
/// currency each is stated in, and the levels each alerts at. What was actually
/// spent is a provider's answer and belongs with the readings. Conversion
/// between currencies, pro-rating a part month, and anything resembling an
/// invoice would be a second billing system living inside a menu bar app.
///
/// Persisted as one JSON object under "aibars.spend.budgets". A blob that no
/// longer decodes is discarded rather than repaired: the user is shown no
/// budgets and can set them again, which is better than a store that half
/// remembers.
@MainActor
public final class BudgetStore: ObservableObject {
    /// The app's single instance. Shared because the refresh loop reads budgets
    /// to decide what to alert on while the settings pane writes them, exactly
    /// as they share `AppearanceSettings` and `AlertCenter`.
    public static let shared = BudgetStore()

    /// The key the overall budget lives under: the empty string, which no
    /// service id can be. A constant so no caller has to write a bare `""` and
    /// leave the next reader guessing what it meant.
    public static let overallKey = ""

    /// Keyed by `UsageProvider.serviceID` rather than by `id`: two Claude
    /// accounts are one subscription as far as the person paying is concerned,
    /// and a budget that split itself the moment a second account was added
    /// would be a budget nobody set. `overallKey` — the empty string — holds
    /// the one that covers every service together.
    ///
    /// Settable in bulk so the editor can bind straight to it. Every write is
    /// cleaned and persisted here, so there is one path to disk however the
    /// value arrived.
    @Published public var budgets: [String: Budget] {
        didSet {
            let clean = Self.sanitised(budgets)
            // Assigning inside a property's own observer does not run the
            // observer again, so this pass still owes the write below.
            if clean != budgets { budgets = clean }
            // The common case is a pane redrawing with nothing changed, and the
            // store should not be touched to say so.
            guard clean != oldValue else { return }
            persist(clean)
        }
    }

    /// `store` is injectable so tests get a scratch domain rather than the
    /// user's own settings.
    public init(store: UserDefaults = .standard) {
        self.store = store
        // Property observers do not run during initialisation, so what was read
        // off disk is cleaned here instead.
        self.budgets = Self.sanitised(Self.decode(from: store) ?? [:])
    }

    /// `nil` when the service has no budget. Callers should treat that as "not
    /// budgeted", never as zero: a budget of zero is a budget that every spend
    /// is already over.
    public func budget(for serviceID: String) -> Budget? {
        budgets[serviceID]
    }

    /// Passing `nil` removes the budget, which is how a budget is unset. There
    /// is no separate delete, because setting one to nothing and having none
    /// are the same state.
    public func setBudget(_ budget: Budget?, for serviceID: String) {
        budgets[serviceID] = budget
    }

    // MARK: - Storage

    private enum Key: String {
        case budgets = "aibars.spend.budgets"
    }

    private let store: UserDefaults

    private static func sanitised(_ budgets: [String: Budget]) -> [String: Budget] {
        budgets.mapValues(\.sanitised)
    }

    private func persist(_ budgets: [String: Budget]) {
        guard let data = try? JSONEncoder().encode(budgets) else { return }
        store.set(data, forKey: Key.budgets.rawValue)
    }

    private static func decode(from store: UserDefaults) -> [String: Budget]? {
        guard let data = store.data(forKey: Key.budgets.rawValue) else { return nil }
        return try? JSONDecoder().decode([String: Budget].self, from: data)
    }
}
