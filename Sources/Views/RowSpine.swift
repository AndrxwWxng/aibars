import SwiftUI

/// Why a row is asking for attention.
///
/// Closed at three, and closed on purpose. The spine is the only vertical
/// coloured element anywhere in the panel, so its meaning has to stay one
/// sentence long — "this row wants you" — and a fourth reason is what turns a
/// bookmark into a decoration. Adding a case here is a review-blocking change.
public enum SpineReason: Equatable {
    /// At or above `warningThreshold`.
    case nearCap
    /// Locked, expired, or no credential: `ProviderError.isAuth`, or nothing
    /// stored to ask with.
    case needsUser
    /// The last request failed outright.
    case failed
}

/// The decision behind the 2pt bookmark at a row's leading edge, with no view
/// in it.
///
/// Separated from `RowSpineView` for the reason `PaceGeometry` is separated
/// from the meter: three booleans and a colour can be asserted, a rendered
/// 2pt rectangle can only be eyeballed. It is also the part that has to agree
/// with the rest of the near-cap contract — the fill's square trailing end and
/// the figure's heavier weight — and agreement between three channels is a
/// thing to test, not to hope for.
public enum RowSpine {

    /// The reason this row spines, or nil when it is quiet.
    ///
    /// `failed` outranks `needsUser` outranks `nearCap`: a row that is not
    /// answering has nothing true to say about how full it is, and the last
    /// percentage it reported is only getting staler. Ranked rather than
    /// combined, because one mark can carry one meaning.
    ///
    /// A row with no credential spines even though nothing has gone wrong yet:
    /// it is listed and it is empty, which is a decision waiting on the user.
    /// That does not make a fresh install a picket fence — the panel folds
    /// disconnected services into a disclosure group by default, so what
    /// reaches this is a row the panel has already chosen to list.
    public static func reason(
        percent: Double?,
        warningThreshold: Double,
        error: ProviderError?,
        isConnected: Bool
    ) -> SpineReason? {
        // `isAuth` is the provider's own line between "the credential is the
        // problem" and "the request is": `blocked` and `rateLimited` stay out
        // of it deliberately, so a captive portal reads as a failure to the
        // user rather than as a session they have to go and repair.
        if let error { return error.isAuth ? .needsUser : .failed }
        guard isConnected else { return .needsUser }
        // Status-only services report no percentage, and a spine is not
        // something to invent for them.
        guard let percent, percent.isFinite, warningThreshold.isFinite,
              percent >= warningThreshold else { return nil }
        return .nearCap
    }

    /// The ink the mark is drawn in.
    ///
    /// `tint` is the row's own resolved tint — what `AppearanceSettings.tint`
    /// already handed the meter beside it — so `nearCap` cannot disagree with
    /// the bar it is bookmarking under `.accent` or `.provider`. The two state
    /// reasons take the state inks instead: neither is a usage reading, and the
    /// ramp is a rule about readings.
    ///
    /// `.mono` is the exception and takes `Color.primary` for all three. The
    /// user asked for a panel with no hue in it, and the spine is the one
    /// vertical coloured element there is — leaving it saturated would make it
    /// the only thing in the panel ignoring the setting. Nothing is lost by
    /// that: what carries "this row wants you" is the mark being *there*, and
    /// presence survives greyscale, monochrome and a colour-blind eye alike.
    /// Full opacity, never a wash: a 2pt mark has no contrast to give away.
    public static func ink(
        _ reason: SpineReason,
        ramp: AppearanceSettings.ColorRamp,
        tint: Color
    ) -> Color {
        guard ramp != .mono else { return .primary }
        switch reason {
        case .nearCap:   return tint
        case .needsUser: return Tokens.Ink.attention
        case .failed:    return Tokens.Ink.failure
        }
    }

    /// How wide the mark is drawn.
    ///
    /// Three points under increased contrast for the same reason the pace notch
    /// widens: colour alone cannot rescue a 2pt mark on a low-contrast display,
    /// and the mark is the first thing such a display loses.
    public static func width(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? Tokens.Control.spineWidthIncreased : Tokens.Control.spineWidth
    }
}

/// The bookmark itself.
///
/// It fills the height it is given rather than measuring one, and it is held
/// off the card's top and bottom by the caller — that inset is what makes it
/// read as a bookmark *in* the card instead of as the card's own leading edge.
/// Placement is the row's business; this knows only what it means and what
/// colour that is.
public struct RowSpineView: View {
    public let reason: SpineReason
    public let ramp: AppearanceSettings.ColorRamp
    /// The row's resolved tint, used only by `.nearCap`. Passed in rather than
    /// resolved here so the mark and the meter beside it cannot be drawn from
    /// two different readings of the same settings.
    public let tint: Color

    /// Read here rather than taken as an argument, as `MeterTrack` does: the
    /// caller has no more to say about it than the environment already does.
    @Environment(\.colorSchemeContrast) private var contrast

    public init(reason: SpineReason, ramp: AppearanceSettings.ColorRamp, tint: Color) {
        self.reason = reason
        self.ramp = ramp
        self.tint = tint
    }

    public var body: some View {
        // Capsule rather than a bare rectangle: rounded at half its own width,
        // so the ends read as a mark laid on the card rather than as something
        // the card was cut off by.
        Capsule(style: Tokens.Radius.style)
            .fill(RowSpine.ink(reason, ramp: ramp, tint: tint))
            .frame(width: RowSpine.width(increasedContrast: contrast == .increased))
            // The row says all three of these in words already — a status line,
            // a countdown, a figure — so a shape repeating them is noise to a
            // screen reader.
            .accessibilityHidden(true)
            // Decoration never eats a click. A filled shape is hit-testable, and
            // a row that carries this in an overlay would otherwise have a 2pt
            // dead strip down its leading edge.
            .allowsHitTesting(false)
    }
}
