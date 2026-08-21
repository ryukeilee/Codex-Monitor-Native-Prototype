import Foundation

/// Density policy for popover quota cards: suppress per-card text that only
/// echoes information already carried elsewhere on the panel, keeping the
/// cards scannable without hiding window-local anomalies.
enum QuotaCardDensityPolicy {
    /// The trailing state badge on a quota card ("最新"/"历史缓存"/"刷新中"/…)
    /// duplicates snapshot-level freshness already shown by the popover header
    /// status line, or the cached-history caption rendered next to the
    /// percentage. Keep the badge only when it is the sole visual carrier of
    /// the state: window-local data anomalies (`invalid`/`unavailable`) and
    /// windows whose reset deadline has passed while the snapshot still shows
    /// pre-reset values ("已恢复，待刷新"). The accessibility contract keeps
    /// exposing `stateText` regardless of badge visibility.
    static func showsStateBadge(
        fieldState: QuotaFieldState,
        trustedPercent: Int?,
        resetAt: Date?,
        now: Date
    ) -> Bool {
        switch fieldState {
        case .invalid, .unavailable:
            return true
        case .live, .cached:
            guard trustedPercent == nil, let resetAt else { return false }
            return !QuotaTemporalSemantics.isPending(deadline: resetAt, at: now)
        }
    }
}
