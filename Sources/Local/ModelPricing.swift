import Foundation

/// Published list price for one model, in US dollars per million tokens.
///
/// The two cache rates are optional because "not published" and "free" are
/// different facts, and a caller adding up a bill has to be able to tell them
/// apart. Every Anthropic model below publishes both; the optionality is there
/// so a model that does not can still be listed with the rates it does have.
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let output: Double
    /// Writing a five-minute cache entry.
    public let cacheWrite5m: Double?
    /// Reading a cache entry, at either time-to-live.
    public let cacheRead: Double?

    public init(
        input: Double,
        output: Double,
        cacheWrite5m: Double? = nil,
        cacheRead: Double? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheRead = cacheRead
    }
}

/// Per-million-token list prices, and the arithmetic that turns a local token
/// count into dollars.
///
/// Every figure here was read off a published price list on `asOf` and typed in
/// by hand. Nothing is derived from a model's name and nothing is borrowed from
/// a neighbouring model: a model this table does not carry prices to nil, and
/// the caller says "no price for <model>" instead of showing a dollar figure. A
/// spend figure built on a made-up rate is worse than no spend figure, because
/// it looks like it was measured.
public enum ModelPricing {
    /// The day the figures below were read. Worth showing next to any total, so
    /// that a table which has fallen behind is visible rather than merely wrong.
    public static let asOf = "2026-08-11"

    // MARK: - Lookup

    /// The price for `model`, or nil when this table does not carry it.
    ///
    /// Matching runs on a normalised id (see `normalised(_:)`). An exact hit
    /// wins. Failing that, the longest key that is a prefix of the id wins —
    /// but only when what follows the key is a dated snapshot suffix: a hyphen
    /// and at least six digits. That digit rule is the whole safety of the
    /// fallback. `claude-opus-4-5-20251101` resolves to the `claude-opus-4-5`
    /// family, because a dated id is the same model; a model nobody here has
    /// heard of, say `claude-opus-4-9`, does not quietly inherit
    /// `claude-opus-4`'s rates, because "-9" is not a date. Unknown is a better
    /// answer than plausible.
    public static func price(for model: String) -> ModelPrice? {
        let id = normalised(model)
        guard !id.isEmpty else { return nil }
        if let exact = table[id] { return exact }

        var best: (key: String, price: ModelPrice)?
        for (key, price) in table {
            guard id.hasPrefix(key), isDatedSuffix(id.dropFirst(key.count)) else { continue }
            // Longest wins: `claude-sonnet-4-5-20250929` is prefixed by both
            // `claude-sonnet-4` and `claude-sonnet-4-5`, and only one of those
            // is the model that produced the tokens.
            if let current = best, current.key.count >= key.count { continue }
            best = (key, price)
        }
        return best?.price
    }

    // MARK: - Cost

    /// What `bucket` cost at `model`'s list rates, or nil when the model is
    /// unpriced — or when the bucket holds cache tokens this table has no rate
    /// for. Part of a total is not a total.
    ///
    /// These are standard-speed, standard-context rates. Fast mode and the
    /// long-context tier some models publish above 200k prompt tokens both bill
    /// higher and neither is modelled, so a bucket containing either reads low.
    /// The figure is what the same tokens would have cost at API rates; a
    /// subscription does not charge per token.
    ///
    /// This is a two-line adapter onto the token-count overload below. That is
    /// deliberate: the arithmetic stays reachable without building a bucket, so
    /// it can be tested, and so a second local source can reuse it.
    public static func cost(_ bucket: ClaudeCodeBucket, model: String) -> Double? {
        cost(
            input: bucket.inputTokens,
            output: bucket.outputTokens,
            cacheWrite5m: bucket.cacheCreationTokens,
            cacheRead: bucket.cacheReadTokens,
            model: model
        )
    }

    /// The same sum over loose token counts.
    ///
    /// A missing cache rate only fails the sum when there are cache tokens to
    /// price: a bucket that never touched the cache is priced exactly, and
    /// refusing it would be pedantry rather than honesty.
    public static func cost(
        input: Int,
        output: Int,
        cacheWrite5m: Int,
        cacheRead: Int,
        model: String
    ) -> Double? {
        guard let price = price(for: model) else { return nil }

        var total = perMillion(input, price.input) + perMillion(output, price.output)
        if cacheWrite5m > 0 {
            guard let rate = price.cacheWrite5m else { return nil }
            total += perMillion(cacheWrite5m, rate)
        }
        if cacheRead > 0 {
            guard let rate = price.cacheRead else { return nil }
            total += perMillion(cacheRead, rate)
        }
        return total
    }

    /// A negative count is a corrupt log line, not a refund, so it contributes
    /// nothing rather than subtracting from the day's spend.
    private static func perMillion(_ tokens: Int, _ rate: Double) -> Double {
        guard tokens > 0 else { return 0 }
        return Double(tokens) / 1_000_000 * rate
    }

    // MARK: - Normalising a model id

    /// Lower-cased, with routing prefixes and platform version suffixes removed.
    ///
    /// A log line can name the same model as `claude-opus-5`,
    /// `anthropic/claude-opus-5`, `us.anthropic.claude-opus-5-v1:0` or
    /// `claude-haiku-4-5@20251001` depending on which platform served it. None
    /// of that changes what was charged, so it is stripped before matching.
    static func normalised(_ model: String) -> String {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Whatever routing the caller's log put in front of it, the model id
        // starts at "claude".
        if let start = id.range(of: "claude") {
            id = String(id[start.lowerBound...])
        }

        // Vertex separates the release date with "@"; the date is handled by the
        // dated-suffix rule, so it is enough to make it look like the others.
        if let at = id.firstIndex(of: "@") {
            id.replaceSubrange(at...at, with: "-")
        }

        // Bedrock stamps a model version on the end: "-v1:0".
        if let colon = id.firstIndex(of: ":") {
            id = String(id[..<colon])
        }
        if let marker = id.range(of: "-v", options: .backwards) {
            let version = id[marker.upperBound...]
            if !version.isEmpty, version.allSatisfy(\.isNumber) {
                id = String(id[..<marker.lowerBound])
            }
        }

        return id
    }

    /// True for an empty remainder, or for a hyphen followed by at least six
    /// digits. Six because a family number is one or two: without the floor,
    /// `claude-opus-4-5` would file under `claude-opus-4`'s rates, which are
    /// three times higher.
    private static func isDatedSuffix<S: StringProtocol>(_ remainder: S) -> Bool {
        if remainder.isEmpty { return true }
        guard remainder.first == "-" else { return false }
        let digits = remainder.dropFirst()
        return digits.count >= 6 && digits.allSatisfy(\.isNumber)
    }

    // MARK: - The prices

    /// Keyed by the published model id, undated. Dated ids reach these through
    /// the prefix rule in `price(for:)`.
    ///
    /// Anthropic's cache rates have so far been a fixed multiple of input —
    /// 1.25x to write a five-minute entry, 0.1x to read one — but they are typed
    /// out rather than computed, so that a model which departs from the multiple
    /// can be added without unpicking anything.
    private static let table: [String: ModelPrice] = [
        // Fable tier.
        "claude-fable-5":   ModelPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheRead: 1),
        "claude-mythos-5":  ModelPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheRead: 1),

        // Opus. The tier halved at 4.5 and has held since.
        "claude-opus-5":    ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheRead: 0.5),
        "claude-opus-4-8":  ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheRead: 0.5),
        "claude-opus-4-7":  ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheRead: 0.5),
        "claude-opus-4-6":  ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheRead: 0.5),
        "claude-opus-4-5":  ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheRead: 0.5),
        "claude-opus-4-1":  ModelPrice(input: 15, output: 75, cacheWrite5m: 18.75, cacheRead: 1.5),
        "claude-opus-4":    ModelPrice(input: 15, output: 75, cacheWrite5m: 18.75, cacheRead: 1.5),
        "claude-3-opus":    ModelPrice(input: 15, output: 75, cacheWrite5m: 18.75, cacheRead: 1.5),

        // Sonnet. Sonnet 5 is on an introductory 2/10 until 2026-08-31; the list
        // rate is what is carried here, because a discount that expires on a
        // date this table cannot see would go on being applied afterwards.
        "claude-sonnet-5":     ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheRead: 0.3),
        "claude-sonnet-4-6":   ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheRead: 0.3),
        "claude-sonnet-4-5":   ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheRead: 0.3),
        "claude-sonnet-4":     ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheRead: 0.3),
        "claude-3-7-sonnet":   ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheRead: 0.3),
        "claude-3-5-sonnet":   ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheRead: 0.3),
        "claude-3-sonnet":     ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheRead: 0.3),

        // Haiku.
        "claude-haiku-4-5":  ModelPrice(input: 1, output: 5, cacheWrite5m: 1.25, cacheRead: 0.1),
        "claude-3-5-haiku":  ModelPrice(input: 0.8, output: 4, cacheWrite5m: 1, cacheRead: 0.08),
        "claude-3-haiku":    ModelPrice(input: 0.25, output: 1.25, cacheWrite5m: 0.3, cacheRead: 0.03),
    ]
}
