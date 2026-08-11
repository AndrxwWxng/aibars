import Foundation

/// What a service says has been spent, and the ceiling it is spent against.
///
/// Money is held in minor units and an exponent rather than a `Double`, because
/// a bill is an exact quantity: `0.1 + 0.2` is not `0.3` in binary floating
/// point, and a spend row that disagrees with the provider's own invoice by a
/// cent is worse than no spend row at all.
public struct SpendReport: Codable, Hashable {
    /// How much this figure is worth trusting. A row must never present the
    /// second as the first: one is the provider's own accounting, the other is
    /// arithmetic we did locally and could be wrong about.
    public enum Confidence: String, Codable {
        /// The provider reported the amount. Its number, its ledger.
        case measured
        /// A local token count priced against a published rate card. Right up
        /// until the rate card changes, or the count misses cached tokens.
        case estimated
    }

    /// What span the amount covers. `rollingHours` is a window that slides;
    /// `day`/`week`/`month` are calendar periods the provider resets on.
    public enum Period: Codable, Hashable {
        case rollingHours(Int)
        case day
        case week
        case month
        case lifetime

        /// Written out by hand rather than synthesised. The compiler encodes an
        /// associated value as `{"rollingHours":{"_0":24}}`, and `_0` is a
        /// detail of how the case is spelled today, not something a persisted
        /// file should depend on surviving a rename.
        private enum CodingKeys: String, CodingKey {
            case kind
            case hours
        }

        private enum Kind: String, Codable {
            case rollingHours
            case day
            case week
            case month
            case lifetime
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .rollingHours: self = .rollingHours(try container.decode(Int.self, forKey: .hours))
            case .day:          self = .day
            case .week:         self = .week
            case .month:        self = .month
            case .lifetime:     self = .lifetime
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .rollingHours(let hours):
                try container.encode(Kind.rollingHours, forKey: .kind)
                try container.encode(hours, forKey: .hours)
            case .day:      try container.encode(Kind.day, forKey: .kind)
            case .week:     try container.encode(Kind.week, forKey: .kind)
            case .month:    try container.encode(Kind.month, forKey: .kind)
            case .lifetime: try container.encode(Kind.lifetime, forKey: .kind)
            }
        }
    }

    /// What a payload said about the ceiling, in three states rather than two.
    /// "There is no ceiling" and "there is a ceiling we could not read" are
    /// different facts, and only one of them is safe to show a user.
    public enum Ceiling {
        /// The provider says this spend is uncapped.
        case uncapped
        /// The provider gave a ceiling, in the same minor units as the amount.
        case limit(Int)
        /// A ceiling was present in the payload and we could not parse it.
        case unreadable
    }

    /// Spent so far, in minor units of `currency` scaled by `exponent`.
    public let amountMinor: Int
    /// ISO 4217, uppercased. Never guessed: a payload without a currency is a
    /// parse failure at the provider, not a report denominated in dollars.
    public let currency: String
    /// Decimal places between `amountMinor` and one major unit. 2 for USD, 0
    /// for JPY, 6 where a provider bills in micro-units.
    public let exponent: Int
    /// The ceiling, in the same minor units. `nil` means genuinely uncapped —
    /// an unreadable ceiling never reaches this field, see `init?(…ceiling:…)`.
    public let limitMinor: Int?
    public let period: Period
    public let confidence: Confidence
    /// When this period rolls over, when the provider says. Rolling windows and
    /// lifetime totals generally do not have one.
    public let resetDate: Date?

    /// Nine places is far past any real minor unit — micro-billing is six — and
    /// an unclamped exponent out of a payload can push `Decimal` past its own
    /// exponent range, where the amount stops being a number at all.
    private static let exponentRange = 0...9

    public init(
        amountMinor: Int,
        currency: String,
        exponent: Int = 2,
        limitMinor: Int? = nil,
        period: Period,
        confidence: Confidence,
        resetDate: Date? = nil
    ) {
        self.amountMinor = amountMinor
        self.currency = currency.trimmingCharacters(in: .whitespaces).uppercased()
        self.exponent = min(max(exponent, Self.exponentRange.lowerBound), Self.exponentRange.upperBound)
        self.limitMinor = limitMinor
        self.period = period
        self.confidence = confidence
        self.resetDate = resetDate
    }

    /// The parser's initialiser. Returns `nil` when the payload carried a
    /// ceiling we could not read, which poisons the whole report rather than
    /// letting it read as uncapped — showing a spend with no ceiling beside one
    /// that has a ceiling we simply failed to parse is the worse of the two.
    public init?(
        amountMinor: Int,
        currency: String,
        exponent: Int = 2,
        ceiling: Ceiling,
        period: Period,
        confidence: Confidence,
        resetDate: Date? = nil
    ) {
        let limit: Int?
        switch ceiling {
        case .uncapped:            limit = nil
        case .limit(let value):    limit = value
        case .unreadable:          return nil
        }
        self.init(
            amountMinor: amountMinor,
            currency: currency,
            exponent: exponent,
            limitMinor: limit,
            period: period,
            confidence: confidence,
            resetDate: resetDate
        )
    }

    /// Reports are persisted between launches, and a file on disk is untrusted
    /// input like any other, so decoding goes through the clamping initialiser.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            amountMinor: try container.decode(Int.self, forKey: .amountMinor),
            currency: try container.decode(String.self, forKey: .currency),
            exponent: try container.decode(Int.self, forKey: .exponent),
            limitMinor: try container.decodeIfPresent(Int.self, forKey: .limitMinor),
            period: try container.decode(Period.self, forKey: .period),
            confidence: try container.decode(Confidence.self, forKey: .confidence),
            resetDate: try container.decodeIfPresent(Date.self, forKey: .resetDate)
        )
    }

    /// The amount in major units, exactly. `Decimal` and not `Double` for the
    /// same reason the storage is integral.
    /// Whether the figure was priced up locally rather than billed.
    ///
    /// A convenience over `confidence` because callers ask this far more often
    /// than they branch on the whole enum, and `confidence == .estimated`
    /// repeated at every call site is the kind of thing that gets inverted once.
    public var isEstimate: Bool { confidence == .estimated }

    public var amount: Decimal {
        Decimal(amountMinor) * Decimal(sign: .plus, exponent: -exponent, significand: 1)
    }

    /// How much of the ceiling is gone, 0...1.
    ///
    /// `nil` when there is nothing to be a fraction of — uncapped, or a ceiling
    /// of zero. Not 0, and not 1: both of those are readings, and "we were not
    /// given a limit" is not a reading.
    public var percent: Double? {
        guard let limitMinor, limitMinor > 0 else { return nil }
        return min(max(Double(amountMinor) / Double(limitMinor), 0), 1)
    }

    /// The amount, formatted in the reader's locale.
    ///
    /// Sub-unit precision is kept only where it changes the reading: a $0.0043
    /// API charge shown as $0.00 is a lie about zero, while $32.847291 is six
    /// digits of noise on a figure nobody acts on below the cent. The range,
    /// rather than a fixed length, is what stops the small case padding out to
    /// `$0.004300`.
    public var display: String {
        let value = amount
        let floor = min(exponent, 2)
        let ceiling = (exponent > 2 && abs(value) < 1) ? exponent : floor
        return value.formatted(.currency(code: currency).precision(.fractionLength(floor...ceiling)))
    }

    private enum CodingKeys: String, CodingKey {
        case amountMinor
        case currency
        case exponent
        case limitMinor
        case period
        case confidence
        case resetDate
    }
}
