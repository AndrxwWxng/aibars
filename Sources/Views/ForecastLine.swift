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
//     `UsageProjection.outcome`, for the one thing the sentence cannot carry:
//     whether this is a warning or a note.
//
// The samples, the fit, the refusals and every word of the copy stay there.
// This decides where the line is drawn, in what ink, and whether it is drawn
// at all.
// ---------------------------------------------------------------------------

/// One caption under a row's meters saying where the current pace is heading.
///
/// Only ever draws when there is something honest to say. No samples yet, a
/// service that isn't being spent, a cap further out than half an hour of
/// samples can claim, or the setting switched off all produce an `EmptyView`
/// with no height reserved behind it.
///
/// That is the opposite of how the rest of the row treats a line that comes and
/// goes — `RowActions` and the loading spinner both hold their space precisely
/// so the panel cannot resize under the pointer, because `MenuBarExtra` sizes
/// its window to the content. Reserving space here would be worse than useless:
/// most rows have no pace to report at all, so every row in the panel would
/// carry a blank line for the sake of the one that does. The resize is avoided
/// from the other end instead — the caller places this inside the detail
/// `VStack`, which already varies in height from one row to the next, and the
/// line is only ever added to a row being drawn fresh rather than switched on
/// under a panel that is already open.
public struct ForecastLine: View {
    @ObservedObject private var appearance: AppearanceSettings
    /// The row's id — "claude#2", not "claude". Two accounts of one service are
    /// spent at their own rates and are sampled against their own keys.
    public let providerID: String
    /// When the window this row's headline meter belongs to renews. Only the
    /// ink reads it, and only to keep a projected cap that the reset now beats
    /// from being drawn as a warning.
    public let resetDate: Date?

    /// Held plainly rather than observed, unlike the appearance beside it. The
    /// samples are recorded by the same refresh that publishes the usage this
    /// row is drawn from, so the row is already being rebuilt whenever the
    /// projection has changed; observing the store as well would let a pace line
    /// arrive on its own between refreshes, which is the mid-flight resize this
    /// view exists to avoid. The setting is read the same way, on the way in: it
    /// lives in a settings window that cannot be open at the same time as the
    /// panel, and the panel is rebuilt by the time it is.
    private let trend: UsageTrendStore

    public init(
        providerID: String,
        resetDate: Date?,
        appearance: AppearanceSettings? = nil,
        trend: UsageTrendStore? = nil
    ) {
        self.providerID = providerID
        self.resetDate = resetDate
        // Resolved here rather than as default arguments, as everywhere else in
        // the panel: a default argument is evaluated at the call site, and both
        // shared objects are main-actor isolated, so that would constrain who is
        // allowed to build a row.
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
        self.trend = trend ?? UsageTrendStore.shared
    }

    public var body: some View {
        // One clock for the sentence and for the ink, so a countdown that reads
        // as inside the window cannot be drawn as though it isn't.
        let now = Date()
        let projection = trend.projection(for: providerID)
        if let line = Self.text(projection: projection, now: now, showsPace: trend.showsPaceInPanel) {
            Text(line)
                .font(.system(size: appearance.metrics.captionSize))
                .foregroundStyle(ink(for: projection))
                // A pace that wraps to a second line has grown the row by more
                // than the reading is worth.
                .lineLimit(1)
        }
    }

    /// The caption, or nil when the pace says nothing worth a line.
    ///
    /// Static and given its own clock so the copy can be asserted without
    /// hosting a view. The wording, and every refusal behind it — idle, falling,
    /// an arrival past the horizon — belongs to `UsageForecast`; this adds only
    /// the setting, which is the one part of the decision a forecast has no
    /// business knowing about.
    public static func text(projection: UsageProjection?, now: Date, showsPace: Bool) -> String? {
        guard showsPace, let projection else { return nil }
        return UsageForecast.phrase(for: projection, now: now)
    }

    /// Secondary, except where the cap is projected to arrive before the window
    /// renews — which is `.capsAt`, since a reset that gets there first is
    /// reported as `.resetsFirst` instead. That line is reassurance and reads as
    /// the note it is; this one is the row's own warning and takes the ink the
    /// meter beside it would.
    private func ink(for projection: UsageProjection?) -> Color {
        guard let outcome = projection?.outcome, case .capsAt(let eta) = outcome else { return .secondary }
        // The forecast has already weighed the renewal it was given, so this
        // agrees with it on every ordinary refresh. It is checked again against
        // the date the row is currently drawing because that is the fresher of
        // the two: a window that renews first is not a warning, and a line whose
        // samples were taken under the previous reset must not be painted as one.
        if let resetDate, eta >= resetDate { return .secondary }
        // Every ramp returns the warning colour at or above its threshold, so a
        // full meter is how a caller asks for "whatever this panel warns in"
        // without naming a colour the user has already configured elsewhere. No
        // ramp can reach the brand colour at this percent, which is why there is
        // no provider accent to pass in.
        return appearance.tint(for: 1, providerAccent: .secondary)
    }
}
