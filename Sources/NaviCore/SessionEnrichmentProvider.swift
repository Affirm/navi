import Foundation

/// Bridges `EventMonitor` (in NaviCore) to the enrichment service (in Navi).
/// EventMonitor only needs three operations — refresh on session create/update,
/// and evictions on session dismissal — while the concrete service that
/// actually probes git/gh/transcript metadata lives in the Navi target because
/// it depends on UI-toggle state from `FloatingWindowManager`. Defining the
/// protocol here keeps NaviCore from importing Navi.
public protocol SessionEnrichmentProvider: AnyObject {
    /// Schedule a refresh for the given session. May be a no-op if the
    /// concrete service is disabled (e.g. all enrichment toggles off).
    func refresh(for session: SessionInfo)

    /// Drop any caches keyed by the given session ID.
    func evict(sessionID: String)

    /// Drop any cwd-keyed caches for cwds not present in `activeCwds`.
    func evictUnused(activeCwds: Set<String>)
}
