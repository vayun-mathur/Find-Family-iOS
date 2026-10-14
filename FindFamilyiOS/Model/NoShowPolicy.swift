import Foundation

/// Pure due/containment policy for no-show alerts. Mirrors Android `domain/NoShowPolicy.kt`.
///
/// Unit-testable by construction: every input is a primitive or `Date`. No database types —
/// the scheduler maps rows to these parameters at its own boundary (`NoShowScheduler`).
///
/// Containment mirrors the live geofence path (`haversine` + `BackgroundTask.resolveWaypoint`):
/// entering needs the whole error circle inside the radius, leaving needs it wholly outside
/// a hysteresis margin, and fixes worse than `maxAccuracyMeters` cannot move the answer. The
/// same constant also gates the whole fix pipeline: intake drops anything coarser at
/// `recordFix`, inbound drops coarser peer fixes before storage. Shutdown / battery-low parting
/// reports are the one bypass — they republish the last held fix however stale, marked as
/// such. The distance itself is a pure haversine rather than the platform geodesic, so values
/// agree to within the sub-meter noise the strict inequalities already tolerate.
enum NoShowPolicy {
    /// Mirror of the inbound geofence accuracy gate: worse fixes decide nothing.
    /// Also the intake gate (`BackgroundTask.maxFixAccuracyMeters`) so the fix pipeline,
    /// the live geofence, and the no-show path can never drift apart.
    static let maxAccuracyMeters = 100.0

    /// Mirror of the inbound exit hysteresis: leaving needs a clear margin.
    static let exitHysteresis = 1.2

    /// Mean Earth radius in meters, matching the platform geodesic scale.
    static let earthRadiusMeters = 6_371_000.0

    /// The alert deadline: the moment `grace` after `expectedAt` it becomes due.
    static func deadline(expectedAt: Date, grace: TimeInterval) -> Date {
        expectedAt.addingTimeInterval(grace)
    }

    /// True once `now` has reached `expectedAt` plus `grace` (inclusive).
    static func isDue(expectedAt: Date, grace: TimeInterval, now: Date) -> Bool {
        now >= deadline(expectedAt: expectedAt, grace: grace)
    }

    /// True when a fix is precise enough to decide geofence membership.
    static func isAccurateEnough(accuracyMeters: Double) -> Bool {
        accuracyMeters.isFinite && accuracyMeters >= 0 && accuracyMeters <= maxAccuracyMeters
    }

    /// Pure haversine distance in meters. Same contract as the data-layer geodesic
    /// (meters between WGS84 points); the spherical approximation differs by far
    /// less than a typical fix accuracy.
    static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        haversine(Coord(lat: lat1, lon: lon1), Coord(lat: lat2, lon: lon2))
    }

    /// Enter semantics: the whole error circle must fit inside `rangeMeters`.
    /// Strict `<`, mirroring inbound — a circle exactly touching the boundary stays
    /// where it was.
    static func isEnterInside(distanceMeters: Double, accuracyMeters: Double, rangeMeters: Double) -> Bool {
        distanceMeters + accuracyMeters < rangeMeters
    }

    /// Exit semantics: still inside while any part of the error circle (plus the
    /// hysteresis margin) overlaps the radius. Strict `<`, mirroring inbound.
    static func isStillInside(distanceMeters: Double, accuracyMeters: Double, rangeMeters: Double) -> Bool {
        distanceMeters - accuracyMeters < rangeMeters * exitHysteresis
    }

    /// A fix only proves arrival when it was *measured* at or after the expectation.
    /// Shutdown and low-battery reports deliberately republish a stale last-known
    /// position, so ranking them by send time would let a parting shot from long
    /// before `expectedAt` suppress an alert it says nothing about.
    static func isFixFreshForArrival(fixTimestamp: Date, expectedAt: Date) -> Bool {
        fixTimestamp >= expectedAt
    }

    /// Arrival at a waypoint: a fresh, accurate fix whose whole error circle is
    /// inside the radius. Any failed gate reads as "not arrived" — a fix that
    /// cannot say which side of the boundary it is on must not suppress the alert.
    static func hasArrivedAtWaypoint(
        fixLat: Double,
        fixLon: Double,
        fixAccuracyMeters: Double,
        fixTimestamp: Date,
        expectedAt: Date,
        waypointLat: Double,
        waypointLon: Double,
        waypointRangeMeters: Double
    ) -> Bool {
        guard isFixFreshForArrival(fixTimestamp: fixTimestamp, expectedAt: expectedAt) else { return false }
        guard isAccurateEnough(accuracyMeters: fixAccuracyMeters) else { return false }
        let distance = haversineMeters(lat1: fixLat, lon1: fixLon, lat2: waypointLat, lon2: waypointLon)
        return isEnterInside(distanceMeters: distance, accuracyMeters: fixAccuracyMeters, rangeMeters: waypointRangeMeters)
    }

    /// Arrival when the alert watches no waypoint: a fresh fix that is also accurate
    /// enough. A coarse fix cannot say where the person is, so it must not suppress
    /// the alert.
    static func hasAnyFreshFix(
        fixTimestamp: Date,
        expectedAt: Date,
        fixAccuracyMeters: Double
    ) -> Bool {
        isFixFreshForArrival(fixTimestamp: fixTimestamp, expectedAt: expectedAt)
            && isAccurateEnough(accuracyMeters: fixAccuracyMeters)
    }

    /// Fire-once guard for the scheduler: fires only for an unfired alert whose
    /// deadline has passed and whose arrival was not observed. Persistence
    /// (claim-then-notify, delete vs re-arm) stays with the scheduler; this is
    /// the in-memory half that keeps a second pass from double-firing.
    static func shouldFire(
        fired: Bool,
        expectedAt: Date,
        grace: TimeInterval,
        now: Date,
        arrived: Bool
    ) -> Bool {
        !fired && !arrived && isDue(expectedAt: expectedAt, grace: grace, now: now)
    }
}

// MARK: - NoShowScheduler (model + schedule side; the dialog UI comes from another agent)

/// Scheduler + sweep for no-show alerts. Mirrors Android `platform/NoShowCheckScheduler.kt`.
///
/// SCHEDULING DECISION (documented per the task): timer-based sweep from `runTick`,
/// NOT `BGTaskScheduler`. Reasons: (1) the tick already runs every ~3 s whenever the app
/// is alive (foreground + background-location session), so a due alert fires within
/// seconds without any extra wakeups; (2) a `BGTaskScheduler` task would need a
/// `UIBackgroundModes` identifier in `Info.plist` plus registration in `AppDelegate` —
/// both outside this change's file list — and iOS still wouldn't grant exact-alarm
/// timing for it, so it would be a second, coarser timer anyway. If exact
/// deadline delivery is ever needed, register a `BGAppRefreshTask` and have it call
/// `sweepDueNow()`; the sweep itself is already re-entrant-safe via the atomic claim.
///
/// The actual due/arrival decision lives in `NoShowPolicy` (pure); this is only the glue:
/// sweep when the tick calls, and notify on the claimed alerts. Claiming is atomic via
/// `markNoShowAlertFired` (0/1 rows), so concurrent sweeps cannot double-fire. One-shot
/// rows are deleted after claiming; recurring rows stay with `fired = true` until re-armed.
///
/// Notification strings live here rather than in `Strings` because `Util/Util.swift` is
/// owned by another agent — the UI agent is free to move them when it builds the dialog.
@MainActor
final class NoShowScheduler {
    static let shared = NoShowScheduler()

    private init() {}

    /// Check every due alert against the latest fixes and claim the ones that fire.
    /// Callable from the tick (wired) and from any future background task. Returns the
    /// claimed alerts for the notification step, which this same function delivers so a
    /// headless tick still alerts.
    @discardableResult
    func sweepDueNow() async -> [NoShowAlert] {
        let now = Date()
        let due = Database.shared.dueNoShowAlerts(now: now)
        guard !due.isEmpty else { return [] }
        let latestByUser = Database.shared.latestLocationsSubject.value
        var fired: [NoShowAlert] = []
        for alert in due {
            if let claimed = tryClaimAlert(alert, latestByUser: latestByUser, now: now) {
                fired.append(claimed)
            }
        }
        return fired
    }

    /// Evaluate one due alert and claim it if it should fire. Returns the claimed
    /// (fired = true) copy, or nil when this alert must not notify this sweep.
    private func tryClaimAlert(
        _ alert: NoShowAlert,
        latestByUser: [Int64: LocationValue],
        now: Date
    ) -> NoShowAlert? {
        let fix = latestByUser[alert.watchedUserId]
        let arrived = isArrived(alert: alert, fix: fix)
        guard NoShowPolicy.shouldFire(
            fired: alert.fired,
            expectedAt: alert.expectedAt,
            grace: alert.grace,
            now: now,
            arrived: arrived
        ) else { return nil }
        // Claim first: only the sweep whose UPDATE matches notifies.
        guard Database.shared.markNoShowAlertFired(id: alert.id) == 1 else { return nil }
        if alert.oneShot {
            Database.shared.deleteNoShowAlert(alert)
        }
        var claimed = alert
        claimed.fired = true
        notifyNoShow(claimed)
        return claimed
    }

    private func isArrived(alert: NoShowAlert, fix: LocationValue?) -> Bool {
        guard let fix else { return false }
        // Network sightings are finder proxies, not the person's position — they prove
        // nothing about arrival. The accuracy/freshness gates below would reject most of
        // them anyway; this makes the intent explicit.
        guard fix.source != .networkSighting else { return false }
        guard let waypointId = alert.waypointId else {
            return NoShowPolicy.hasAnyFreshFix(
                fixTimestamp: fix.timestamp,
                expectedAt: alert.expectedAt,
                fixAccuracyMeters: Double(fix.acc)
            )
        }
        // A deleted waypoint proves nothing — same as Android, which returns false here
        // so the alert fires rather than silently watching a place that no longer exists.
        guard let waypoint = Database.shared.waypointsSubject.value.first(where: { $0.id == waypointId }) else {
            return false
        }
        return NoShowPolicy.hasArrivedAtWaypoint(
            fixLat: fix.coord.lat,
            fixLon: fix.coord.lon,
            fixAccuracyMeters: Double(fix.acc),
            fixTimestamp: fix.timestamp,
            expectedAt: alert.expectedAt,
            waypointLat: waypoint.coord.lat,
            waypointLon: waypoint.coord.lon,
            waypointRangeMeters: waypoint.range
        )
    }

    /// Fires the user-visible alert. Stable identifier per alert (re-deliveries replace
    /// rather than stack, mirroring Android's `"$alertId::NO_SHOW"` notify id) and grouped
    /// per watched person via the thread identifier (mirroring the per-person channel).
    private func notifyNoShow(_ alert: NoShowAlert) {
        let user = Database.shared.user(id: alert.watchedUserId)
        let name = user?.name ?? "ID \(Base26.encode(alert.watchedUserId))"
        let message: String
        if let waypointId = alert.waypointId {
            let place = Database.shared.waypointsSubject.value.first(where: { $0.id == waypointId })?.name
                ?? "the expected place"
            message = "\(name) didn't arrive at \(place)"
        } else {
            message = "Haven't seen \(name)"
        }
        NotificationsUtil.send(
            title: name,
            body: message,
            category: "NO_SHOW",
            userId: alert.watchedUserId,
            identifier: "ff-noshow-\(alert.id)"
        )
    }
}
