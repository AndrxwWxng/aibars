import SwiftUI

// ---------------------------------------------------------------------------
// What this file needs from the two models behind it, written down because it
// is the only contract between them and nothing here may widen it.
//
// `UsageTrendStore` (@MainActor, ObservableObject, `shared`):
//     showsPaceInPanel: Bool
//     func projection(for providerID: String) -> UsageProjection?
//
// `UsageForecast`:
//     static func phrase(for: UsageProjection, now: Date) -> String?
//
// The samples, the fit, the refusals and every word of the copy stay there —
// including whether this is a warning or a note, which the sentence says in
// words rather than in colour. This decides how the claim is set and whether it
// is drawn at all; `ProviderRow` decides where it goes.
// ---------------------------------------------------------------------------

/// The pace claim — "on pace to cap in 40m" — as a run on the row's caption
/// line.
///
/// It was a block: a fourth child of the row's detail stack, under the meter and
/// over the further windows. That is the defect this pass closed, and it is worth
/// stating in full because the shape of it is the shape of every height bug this
/// panel has had. `RowGeometry` knew how to reserve the block — `Lines.forecast`,
/// correct arithmetic, fifteen assertion sites behind it — and **nothing ever
/// inserted it**. So a row drew the block unreserved, and the first time half an hour of
/// samples supported a claim that row grew `contentSpacing + lineBox(captionSize)`
/// — 19pt at cozy/100%, roughly 171pt down a full panel — while the panel was
/// open. `MenuBarExtra` sizes its window to its content, so that is the window
/// resizing under the pointer.
///
/// Two ways out, and reserving was the wrong one. Holding a 19pt slot on every
/// row buys space for a line that is absent on nearly all of them: a fit needs
/// three samples five minutes apart, a rising slope, and an arrival inside twelve
/// hours, so a freshly launched panel has a projection for exactly nothing and
/// still pays the full 171pt. Folding costs nothing and cannot cost anything —
/// the caption is one `lineBox` whatever is on it, which is the same property
/// that already lets the chips, the spend and the countdown come and go on that
/// line without moving a row.
///
/// So the claim now rides at the tail of the sentence the caption already draws:
/// `5h session · resets in 1h 19m · on pace to cap in 40m`. Three consequences,
/// all of them wanted:
///
///   - **It cannot move a row.** Not "does not today": the run is one `Text` at
///     `lineLimit(1)` inside a line held at `Tokens.lineBox(detailSize)`, and it
///     is set a size *under* that line, so there is no arrangement of words in
///     which it is the tallest thing on the row.
///   - **It is dropped for width before anything else.** `MetricCaption` offers
///     it as the richest candidate of five, above the ladder that was there
///     before — so a line too tight to hold the pace draws exactly what it drew
///     before the pace existed, never less.
///   - **It follows the line rather than the row.** Under Minimal, where no
///     window line is reserved, there is no line to ride and no claim is made —
///     which is that preset's whole premise, a name and a number, and is the one
///     place the old block contradicted it.
///
/// The quieting the block did by position is done by size instead. The pace is a
/// claim the app is making and everything else on that line is a fact the
/// provider stated, so it is set one step down at `Metrics.captionSize`, which is
/// below `detailSize` at every density and every text scale (the floors are
/// staggered 9/10/11 for exactly this reason).
public struct ForecastLine: View {
    @ObservedObject private var appearance: AppearanceSettings

    /// The sentence, already decided. Nil draws nothing at all.
    ///
    /// Handed in rather than resolved here, and that is the one part of this
    /// view's shape that changed with the fold. The caption has to know whether
    /// there is a claim before it can decide whether to put a separator in front
    /// of one, and a view that answered that question a second time — by asking
    /// the trend store again — would be two copies of one decision, which is
    /// precisely how a reservation and a drawing come to disagree. `text` below
    /// is the decision; the row makes it once and both halves read the answer.
    ///
    /// `providerID`, `resetDate` and the trend store are gone with it. `resetDate`
    /// had already been dead for a release — it was the input to a warning ink
    /// this line no longer takes — and the store is now read one level up.
    public let phrase: String?

    public init(phrase: String?, appearance: AppearanceSettings? = nil) {
        self.phrase = phrase
        // Resolved here rather than as a default argument, as everywhere else in
        // the panel: a default argument is evaluated at the call site, and the
        // shared object is main-actor isolated, so that would constrain who is
        // allowed to build a row.
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    public var body: some View {
        if let phrase {
            Text(phrase)
                // A caption one size under the rest of the line it sits on, and
                // the only run in the panel set at this size. The pace is a claim
                // the app is making and the countdown beside it is a fact the
                // provider stated, so the claim is drawn quieter — and drawn
                // *smaller* is also what guarantees it can never be the run that
                // sets the line's height.
                //
                // `.regular` written out rather than left to the default, which is
                // §3.2: the panel has two weights, `titleWeight` for names,
                // figures and glyphs and `alertWeight` for a figure at its cap,
                // and every run of prose is regular. Inheriting the right weight
                // reads the same as being given it and says nothing about which
                // was meant, so the role each line plays is stated at each line.
                .font(.system(size: appearance.metrics.captionSize, weight: .regular))
                // SF Pro with tabular digits, not SF Mono: this is a run with
                // words in it, and mono on prose is the terminal pastiche the
                // direction rules out. Only the digits inside it need to hold
                // still, which is all this asks for. `View.monospacedDigit()` is
                // macOS 12; `Text.monospaced()` is 13.3 and would raise the
                // stated floor silently, so it is never called anywhere here.
                .monospacedDigit()
                // Muted, always, like every other run of prose in a row.
                //
                // This line used to take the meter's warning ink when the cap was
                // projected to land before the window renewed, and that is now
                // the wrong claim to make in colour. Colour in the panel body
                // says one thing — the meter beside it is at or past its caution
                // band — so an amber sentence over a bar resting in grey would be
                // reporting a state the row is not in, and it would be the
                // loudest thing on a panel whose whole complaint was that hue had
                // stopped meaning anything. Nothing is lost with it: the
                // distinction the ink drew is the difference between the two
                // sentences `UsageForecast` writes, "on pace to cap in 40m"
                // against "resets in 11h 59m, you'll finish under", which is
                // where a quiet interface puts it.
                //
                // `foregroundColor` and not `foregroundStyle`, for the reason
                // spelled out on `Ramp.figureDesign` and in `BudgetPane`: the
                // receiver here is still statically a `Text` — `font` and
                // `monospacedDigit` both hand one back — and the `Text` overload
                // of `foregroundStyle` is macOS 14, so it is the overload the
                // compiler would rather bind and the app's floor is 13. Same trap
                // as `Text.monospaced()`, one modifier along.
                .foregroundColor(Tokens.Ink.muted)
                // A pace that wraps to a second line has grown the row by more
                // than the reading is worth. It cannot wrap where it is drawn
                // now — `MetricCaption` only offers the candidate carrying it
                // when the whole untruncated run fits — and it is stated anyway,
                // because "the caller happens to measure me first" is not a
                // height contract.
                .lineLimit(1)
                // Held at a caption's line box rather than at whatever this
                // sentence happens to measure, so the wording changing — "under a
                // minute" for "on pace to cap in 1h 20m" — cannot move anything,
                // in the row or in the one place this is still drawn on its own,
                // which is `ForecastLineTests`. `minHeight` and not a fixed
                // height, as everywhere else in the row: at the top of the
                // text-scale range a caption's own line is a fraction taller than
                // the box, and the choice there is between a clipped descender
                // and a point over the reservation.
                .frame(minHeight: Tokens.lineBox(appearance.metrics.captionSize), alignment: .leading)
        }
    }

    /// The caption, or nil when the pace says nothing worth a line.
    ///
    /// Static and given its own clock so the copy can be asserted without
    /// hosting a view. The wording, and every refusal behind it — idle, falling,
    /// an arrival past the horizon — belongs to `UsageForecast`; this adds only
    /// the setting, which is the one part of the decision a forecast has no
    /// business knowing about.
    ///
    /// The one decision, asked once. `ProviderRow` calls this, hands the answer
    /// to the caption as `pace`, and the caption uses the same value for the
    /// separator in front of the run, for `hasContent`, and for the run itself.
    public static func text(projection: UsageProjection?, now: Date, showsPace: Bool) -> String? {
        guard showsPace, let projection else { return nil }
        return UsageForecast.phrase(for: projection, now: now)
    }
}
