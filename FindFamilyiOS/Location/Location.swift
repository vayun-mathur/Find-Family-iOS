import Foundation
import CoreLocation
import UIKit
import UserNotifications
import OSLog

let logger = Logger(subsystem: "cc.findfamily.ios.swift", category: "Location")

// MARK: - LocationsHandler (CoreLocation pipeline)

/// Mirrors the `LocationsHandler` in the standalone Find-Family iOS app: uses iOS 17+
/// `CLLocationUpdate.liveUpdates()` driven by a `CLBackgroundActivitySession` plus a
/// `CLServiceSession(.always)` so updates keep flowing in the background.
@MainActor
final class LocationsHandler: ObservableObject {
    static let shared = LocationsHandler()

    private let manager = CLLocationManager()
    private var background: CLBackgroundActivitySession?
    private var session: CLServiceSession?
    private var task: Task<Void, Never>?

    private init() {
        manager.allowsBackgroundLocationUpdates = true
    }

    func authorize() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func startLocationUpdates() {
        authorize()
        guard task == nil else { return }
        logger.info("Starting location updates")
        task = Task { [weak self] in
            do {
                self?.background = CLBackgroundActivitySession()
                self?.session = CLServiceSession(authorization: .always)
                let updates = CLLocationUpdate.liveUpdates()
                for try await update in updates {
                    if let loc = update.location {
                        BackgroundTask.shared.onLocationUpdate(loc, sleep: false)
                    }
                    if update.authorizationDenied { Task { await Networking.shared.problem("Auth denied") } }
                    if update.authorizationDeniedGlobally { Task { await Networking.shared.problem("Auth denied globally") } }
                    if update.authorizationRequestInProgress { Task { await Networking.shared.problem("Auth in progress") } }
                    if update.authorizationRestricted { Task { await Networking.shared.problem("Auth restricted") } }
                    if update.insufficientlyInUse { Task { await Networking.shared.problem("Insufficient Use") } }
                    if update.locationUnavailable { Task { await Networking.shared.problem("Location Unavailable") } }
                    if update.serviceSessionRequired { Task { await Networking.shared.problem("Service Session required") } }
                    if update.stationary { Task { await Networking.shared.problem("Stationary") } }
                }
            } catch {
                logger.error("Could not start location updates: \(error.localizedDescription)")
            }
        }
    }

    func stopLocationUpdates() {
        task?.cancel()
        task = nil
        background = nil
        session = nil
    }
}

// MARK: - BackgroundTask (per-tick work)

/// Implements the per-tick logic from Modern-Apps `BackgroundTask.kt`:
/// throttled to 3s, reverse-geocodes, computes waypoint enter/exit, publishes to each
/// `sendingEnabled` user, receives + persists incoming locations, and emits
/// notifications for sharing requests + low-battery + waypoint transitions.
@MainActor
final class BackgroundTask {
    static let shared = BackgroundTask()

    static let shareIntervalSeconds: TimeInterval = 3.0

    /// Fixes worse than this are never held, published, or stored. Delegates to
    /// `NoShowPolicy.maxAccuracyMeters` so the fix pipeline, the live geofence, and the
    /// no-show path can never drift apart. Mirrors Android `MAX_FIX_ACCURACY_METERS`.
    static let maxFixAccuracyMeters: Float = Float(NoShowPolicy.maxAccuracyMeters)

    /// How stale the held fix has to be before a less accurate one replaces it. Long enough
    /// that a burst of coarse fixes cannot displace a good one, short enough that a device
    /// which has lost precision still reports where it now is. Mirrors Android `FIX_MAX_AGE`.
    static let fixMaxAge: TimeInterval = 120

    private var lastUpdateAt: Date = .distantPast
    private var tickCount = 0
    private var lastBatteryLevels: [Int64: Float] = [:]
    private var isProcessing = false

    /// Last location delivered by CoreLocation. Cached so the timer-driven
    /// heartbeat below can keep publishing even when CLLocationUpdate goes quiet
    /// (e.g. the phone is sitting on a desk).
    ///
    /// This is the HELD best fix, written only by `recordFix` — never assigned directly.
    /// Intake drops unusable fixes and keeps the best recent one rather than the newest,
    /// so a burst of coarse fixes cannot displace a good fix (mirrors Android
    /// `LocationTrackingService.lastKnownLocation` + `recordFix`).
    private var lastKnownLocation: CLLocation?

    /// Background timer that keeps `runTick` firing every `shareIntervalSeconds`
    /// regardless of whether CoreLocation has delivered a new fix. This mirrors
    /// Modern-Apps Android `syncHeartbeat` which runs on a 30 s loop independent
    /// of location callbacks — without it, a stationary iPhone never calls
    /// `/api/location/receive` and so never sees peer locations.
    private var heartbeatTask: Task<Void, Never>?

    private let geocoder = CLGeocoder()

    /// Separate geocoder for the off-tick inbound enrichment batch. `CLGeocoder` handles
    /// one request per instance, and the tick's own waypoint resolution uses `geocoder`
    /// while a batch may be enriching concurrently — sharing one instance would cancel.
    private let enrichGeocoder = CLGeocoder()

    /// Serialized off-tick enrichment chain (see persist-then-enrich in runTick). Each batch
    /// waits for the previous one so entry/exit and low-battery alerts still fire once each.
    /// Mirrors Android `enrichmentMutex`.
    private var enrichmentTail: Task<Void, Never>?

    private init() {
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                if let loc = self?.lastKnownLocation {
                    self?.onLocationUpdate(loc, sleep: false)
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.shareIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func onLocationUpdate(_ loc: CLLocation, sleep: Bool) {
        // Intake first: unusable fixes never become the held fix, and a coarser fix only
        // wins once the held one is stale (see `recordFix`). The tick below publishes the
        // HELD fix, not the raw delivery.
        recordFix(loc)
        guard let held = lastKnownLocation else { return }
        let now = Date()
        if !sleep && now.timeIntervalSince(lastUpdateAt) < Self.shareIntervalSeconds { return }
        lastUpdateAt = now
        if isProcessing { return }
        isProcessing = true
        Task { [weak self] in
            await self?.runTick(loc: held, sleep: sleep)
            self?.isProcessing = false
        }
    }

    /// Intake gate (mirrors Android `hasUsableAccuracy`): a fix without a finite,
    /// non-negative accuracy inside the gate cannot place anyone and is dropped before it
    /// can become the held fix, be published, or reach storage.
    private func hasUsableAccuracy(_ loc: CLLocation) -> Bool {
        let acc = loc.horizontalAccuracy
        guard acc >= 0, acc.isFinite else { return false }
        return acc <= Double(Self.maxFixAccuracyMeters)
    }

    /// Keeps the best recent fix rather than simply the newest one (mirrors Android
    /// `recordFix`). Fixes worse than the gate are dropped here and never become the held
    /// fix; a coarser fix only wins once the one being held has gone stale enough to be
    /// the worse answer. Out-of-order deliveries (non-positive age) never replace.
    private func recordFix(_ loc: CLLocation) {
        guard hasUsableAccuracy(loc) else { return }
        guard let held = lastKnownLocation else {
            lastKnownLocation = loc
            return
        }
        let age = loc.timestamp.timeIntervalSince(held.timestamp)
        guard age > 0 else { return }
        if age > Self.fixMaxAge || loc.horizontalAccuracy <= held.horizontalAccuracy {
            lastKnownLocation = loc
        }
    }

    private func runTick(loc: CLLocation, sleep: Bool) async {
        guard Networking.shared.isReady else { return }
        let battery = max(0, UIDevice.current.batteryLevel) * 100
        let coord = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let accuracy = loc.horizontalAccuracy
        let now = Date()
        let me = LocationValue(
            id: Int64.random(in: Int64.min...Int64.max),
            userid: Networking.shared.userid,
            coord: coord,
            speed: Float(max(0, loc.speed)),
            acc: Float(max(0, accuracy)),
            timestamp: now,
            battery: battery,
            // A live tick measures and reports at the same moment. iOS produces no other kind
            // of report — shutdown and network-sighting sources are Android-only for now.
            reportedAt: now,
            source: .live
        )

        // Periodically (re)register so the server has our current key.
        tickCount += 1
        if tickCount % 100 == 1 { _ = await Networking.shared.ensureUserExists() }

        // 1 + 2. Persist our own fix, then compute our current waypoint (with accuracy gate +
        // 1.2× exit hysteresis) and a display name. Uses the atomic partial update so
        // timers/flags set elsewhere (sharingAutoToggleAt / sendingEnabled) aren't clobbered.
        // The tick fix is a live CLLocation measurement, so the waypoint enrichment is
        // latency-free — the persist-then-enrich split below is for inbound batches only.
        Database.shared.insertLocationValue(me)
        if let meUser = Database.shared.user(id: Networking.shared.userid) {
            let (currentId, resolvedName) = await resolveWaypoint(coord: coord, accuracy: accuracy, prevId: meUser.lastWaypointId)
            let displayName = resolvedName ?? (meUser.locationName.isEmpty ? "Unnamed Location" : meUser.locationName)
            if currentId != meUser.lastWaypointId || displayName != meUser.locationName {
                Database.shared.updateLocationMeta(
                    id: meUser.id,
                    locationName: displayName,
                    lastWaypointId: currentId,
                    lastLocationChangeTime: Date()
                )
            }
        }

        // 3. Delete expired temporary links.
        for link in Database.shared.temporaryLinksSubject.value where link.deleteAt < now {
            Database.shared.deleteTemporaryLink(link)
        }

        // 4. Apply due auto-toggles, then publish. Mirrors Android: flip `sendingEnabled`
        // atomically for due timers AND for arrival triggers whose waypoint "Me" is currently
        // inside, reload sharing state, then publish only to peers with sharing enabled
        // (`id != me && sendingEnabled`) so the toggles are actually honored.
        Database.shared.applyDueAutoToggles(now: now)
        var publishBaseUsers = Database.shared.usersSubject.value
        publishBaseUsers = applyArrivalAutoToggles(base: publishBaseUsers, coord: coord)
        // The sharing master switch suppresses outbound publishing without touching the
        // per-person flags, so turning it back on resumes exactly the set of people the
        // user was sharing with. Receiving, waypoints and enrichment are unaffected.
        let sharingOut = Database.shared.globalSharingEnabledSubject.value
        let publishTargets = sharingOut
            ? publishBaseUsers.filter { $0.id != Networking.shared.userid && $0.sendingEnabled }
            : []
        for u in publishTargets {
            _ = await Networking.shared.publishLocation(me, toUser: u)
        }
        if sharingOut {
            for link in Database.shared.temporaryLinksSubject.value {
                _ = await Networking.shared.publishLocation(me, toLink: link)
            }
        }

        // 5. Receive incoming peer locations. Authenticate before storing
        // (GHSA-x94x-v6f7-wwpp): the ciphertext proves who a packet is FOR, not who it is
        // FROM. Three gates — time-clamp, sender-auth, storage-eligibility — mirror
        // Android `processIncomingFixes`: strangers become a pending request at most, and
        // their coordinates are never stored, mapped, or enriched. Tracker rows never pin
        // and never accept pair IDs: their positions come from crowd reports, not relay
        // packets, so a packet claiming a tracker id is dropped, never stored.
        if let incoming = await Networking.shared.receiveLocations() {
            let batchNow = Date()
            let snapshot = Database.shared.usersSubject.value
            let usersById = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
            // Eligible senders: mutual/response PERSON contacts known when this batch
            // arrived. Snapshotted once so a stranger cannot bootstrap themselves mid-batch.
            let eligibleIds = Set(snapshot.filter {
                $0.kind == .person
                    && ($0.requestStatus == .mutualConnection || $0.requestStatus == .awaitingResponse)
            }.map { $0.id })
            var storable: [LocationValue] = []
            storable.reserveCapacity(incoming.count)
            var strangerIds = Set<Int64>()
            for (loc, pairId) in incoming {
                if loc.userid == Networking.shared.userid { continue }
                if PairAuth.isFromTheFuture(reportedAt: loc.reportedAt, timestamp: loc.timestamp, now: batchNow) {
                    print("BackgroundTask: dropped future-dated fix from \(UInt64(bitPattern: loc.userid))")
                    continue
                }
                guard let peer = usersById[loc.userid], peer.kind == .person, eligibleIds.contains(loc.userid) else {
                    // Stranger, tracker claim, or not-yet-mutual: request row at most,
                    // never a pin, never storage.
                    if usersById[loc.userid] == nil { strangerIds.insert(loc.userid) }
                    else { print("BackgroundTask: dropped fix from ineligible sender \(UInt64(bitPattern: loc.userid))") }
                    continue
                }
                switch PairAuth.checkInbound(expected: peer.inboundPairId, incoming: pairId) {
                case .acceptMatch, .acceptLegacy:
                    storable.append(loc)
                case .acceptPin:
                    Database.shared.pinInboundPairId(id: loc.userid, pairId: pairId!)
                    storable.append(loc)
                case .dropMismatch, .dropMissing:
                    print("BackgroundTask: dropped unauthenticated fix claiming \(UInt64(bitPattern: loc.userid)) (pair \(PairAuth.logPreview(pairId)), expected \(PairAuth.logPreview(peer.inboundPairId)))")
                }
            }
            let knownIds = Set(snapshot.map { $0.id } + [Networking.shared.userid])
            let newSenderIds = strangerIds.subtracting(knownIds)
            for id in newSenderIds {
                let user = User(
                    id: id, name: "ID \(Base26.encode(id))", photo: nil,
                    locationName: "Unknown Location", sendingEnabled: true,
                    requestStatus: .awaitingRequest, lastLocationChangeTime: Date(),
                    encryptionKey: nil
                )
                Database.shared.upsertUser(user)
                NotificationsUtil.send(
                    title: Strings.notifSharingRequestTitle,
                    body: Strings.notifSharingRequestBody(Base26.encode(id)),
                    category: "SHARING_REQUEST"
                )
            }
            persistThenEnrich(storable)
        }

        // 6. Sweep due no-show alerts (timer-based: iOS has no exact-alarm equivalent wired
        // here, and the tick already runs every few seconds — see NoShowScheduler).
        await NoShowScheduler.shared.sweepDueNow()

        // 7. Trim old locations (>7 days).
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        Database.shared.deleteLocationValuesOlderThan(cutoff)

        // 8. Drain the UWB session-setup channel. Each envelope is published
        //    onto UwbInbox so an open Precision Finding view can react; if the
        //    envelope is a REQUEST and no view is open, post a notification.
        if let envelopes = await Networking.shared.receiveUwbMessages() {
            for env in envelopes {
                UwbInbox.shared.emit(env)
                if env.kind == UwbEnvelopeKind.request {
                    let senderId = Int64(bitPattern: env.sender)
                    let senderName = Database.shared.user(id: senderId)?.name ?? "Someone"
                    NotificationsUtil.send(
                        title: "Precision Finding request",
                        body: "\(senderName) wants to find you with Precision Finding. Tap to begin.",
                        category: "UWB_REQUEST"
                    )
                }
            }
        }
    }

    /// Arrival auto-toggle check (mirrors Android `applyArrivalAutoToggles`): flip sharing
    /// for any user whose trigger points at a waypoint "Me" is currently inside, using the
    /// plain enter check (`haversine < range`) exactly like Android. Returns the reloaded
    /// sharing roster when anything flipped so publish uses fresh flags.
    private func applyArrivalAutoToggles(base: [User], coord: Coord) -> [User] {
        let insideIds = Database.shared.waypointsSubject.value
            .filter { haversine($0.coord, coord) < $0.range }
            .map { $0.id }
        guard !insideIds.isEmpty else { return base }
        let flipped = Database.shared.applyDueArrivalToggles(insideWaypointIds: insideIds)
        if flipped > 0 {
            return Database.shared.usersSubject.value
        }
        return base
    }

    /// Persist-then-enrich (mirrors Android `processIncomingLocations`): the raw fixes hit
    /// storage synchronously first; waypoint detection, reverse-geocoding and notifications
    /// run off the tick on a serialized chain. CLGeocoder is a slow network call, so doing
    /// it inline would stall every subsequent tick until it returned — persisting last meant
    /// a slow/failed/cancelled enrichment silently dropped the location. Network sightings
    /// are stored but never mapped: their coordinate is the finder's, not the person's.
    private func persistThenEnrich(_ locList: [LocationValue]) {
        // A category this build cannot interpret is dropped rather than stored.
        let knownSource = locList.filter { $0.source != .unknown }
        if knownSource.count != locList.count {
            let dropped = Set(locList.filter { $0.source == .unknown }.map { $0.userid })
            print("BackgroundTask: dropped \(locList.count - knownSource.count) fix(es) with unrecognised source from \(dropped.map { UInt64(bitPattern: $0) })")
        }
        // Low-accuracy fixes are never used: anything worse than the intake gate never
        // reaches storage, the map, or latestLocations.
        let usable = knownSource.filter {
            $0.acc.isFinite && $0.acc >= 0 && $0.acc <= Self.maxFixAccuracyMeters
        }
        if usable.count != knownSource.count {
            print("BackgroundTask: dropped \(knownSource.count - usable.count) fix(es) worse than \(Self.maxFixAccuracyMeters)m")
        }
        guard !usable.isEmpty else { return }
        // Snapshot the previous latest-per-user BEFORE persisting, so the battery and
        // waypoint comparisons in the enrichment still see the prior state.
        let latestMap = Database.shared.latestLocationsSubject.value
        for loc in usable {
            Database.shared.insertLocationValue(loc)
        }
        // Enrichment runs off the tick. The tail chain keeps batches serialized so
        // entry/exit and low-battery alerts still fire once each.
        let previous = enrichmentTail
        enrichmentTail = Task { [weak self] in
            _ = await previous?.result
            guard !Task.isCancelled else { return }
            await self?.enrichIncomingLocations(usable, latestMap: latestMap)
        }
    }

    /// Best-effort follow-up to `persistThenEnrich`: recomputes waypoint entry/exit,
    /// reverse-geocodes the display name, and raises the entry/exit and low-battery
    /// notifications. `latestMap` is the latest-per-user snapshot taken *before* the new
    /// fixes were stored, so the comparisons below see the prior state.
    private func enrichIncomingLocations(_ locList: [LocationValue], latestMap: [Int64: LocationValue]) async {
        let users = Database.shared.usersSubject.value
        let waypoints = Database.shared.waypointsSubject.value
        for user in users {
            await enrichOneUser(user, locList: locList, latestMap: latestMap, waypoints: waypoints)
        }
    }

    private func enrichOneUser(
        _ user: User,
        locList: [LocationValue],
        latestMap: [Int64: LocationValue],
        waypoints: [Waypoint]
    ) async {
        guard let lastLoc = locList.filter({ $0.userid == user.id }).max(by: { $0.timestamp < $1.timestamp }) else { return }
        // Network sightings are crowding proxies: store, but never map, rename, or alert.
        guard lastLoc.source != .networkSighting else { return }
        let lastSavedLoc = latestMap[user.id]
        maybeNotifyBatteryDrop(lastLoc, previous: lastSavedLoc)
        let prevId = user.lastWaypointId
        let (_, currentId) = resolveWaypointIds(
            prevId: prevId,
            coord: lastLoc.coord,
            accuracy: Double(lastLoc.acc),
            waypoints: waypoints
        )
        let currentWaypoint: Waypoint? = currentId.flatMap { cid in waypoints.first { $0.id == cid } }
        let displayName = await resolveDisplayName(currentWaypoint: currentWaypoint, coord: lastLoc.coord)
            ?? user.locationName
        if currentId != prevId || displayName != user.locationName {
            // Atomic partial update — avoids a stale snapshot clobbering
            // sharingAutoToggleAt / sendingEnabled.
            Database.shared.updateLocationMeta(
                id: user.id,
                locationName: displayName,
                lastWaypointId: currentId,
                lastLocationChangeTime: Date()
            )
        }
        maybeNotifyEntryExit(user: user, prevId: prevId, currentId: currentId, currentWaypoint: currentWaypoint, displayName: displayName, waypoints: waypoints)
    }

    /// Synchronous battery edge detector shared by the tick and enrichment paths.
    /// Fires once as a peer crosses 15% (matches Android). Self fixes never notify.
    private func maybeNotifyBatteryDrop(_ loc: LocationValue, previous: LocationValue?) {
        let prior = previous?.battery ?? lastBatteryLevels[loc.userid] ?? 100
        lastBatteryLevels[loc.userid] = loc.battery
        guard loc.userid != Networking.shared.userid else { return }
        guard loc.battery <= 15, prior > 15 else { return }
        if let user = Database.shared.user(id: loc.userid) {
            NotificationsUtil.send(
                title: Strings.notifBatteryLowTitle,
                body: Strings.notifBatteryLowBody(user.name, Int(loc.battery)),
                category: "BATTERY_LOW",
                userId: loc.userid
            )
        }
    }

    /// Pure geofence id resolution shared by the tick and enrichment paths (mirrors
    /// Android `resolveWaypointId`). Returns the entered waypoint (for display naming)
    /// and the sticky current id:
    /// - accuracy too coarse → return prev (a fix that cannot say which side of the
    ///   boundary it is on must not move the answer);
    /// - enter requires haversine+accuracy < range (the whole error circle inside);
    /// - staying in prev requires haversine-accuracy < range*1.2 (any part of the error
    ///   circle plus the hysteresis margin still overlapping).
    /// Strict `<` throughout: a circle exactly touching the boundary stays where it was.
    private func resolveWaypointIds(
        prevId: Int64?,
        coord: Coord,
        accuracy: Double,
        waypoints: [Waypoint]
    ) -> (enteredId: Int64?, currentId: Int64?) {
        guard accuracy.isFinite, accuracy >= 0, accuracy <= NoShowPolicy.maxAccuracyMeters else {
            return (nil, prevId)
        }
        if let entered = waypoints.first(where: { haversine($0.coord, coord) + accuracy < $0.range }) {
            return (entered.id, entered.id)
        }
        let stillInsidePrev: Bool = {
            guard let pid = prevId, let wp = waypoints.first(where: { $0.id == pid }) else { return false }
            return haversine(wp.coord, coord) - accuracy < wp.range * NoShowPolicy.exitHysteresis
        }()
        return (nil, stillInsidePrev ? prevId : nil)
    }

    /// Computes the current waypoint id for a coordinate with the accuracy gate + 1.2× exit
    /// hysteresis and a display name. The returned name prefers the entered/sticky waypoint
    /// name, then a reverse-geocoded address, else nil (unresolved — callers keep the old name).
    private func resolveWaypoint(coord: Coord, accuracy: Double, prevId: Int64?) async -> (currentId: Int64?, name: String?) {
        let waypoints = Database.shared.waypointsSubject.value
        let (enteredId, currentId) = resolveWaypointIds(prevId: prevId, coord: coord, accuracy: accuracy, waypoints: waypoints)
        if let enteredId, let wp = waypoints.first(where: { $0.id == enteredId }) {
            return (currentId, wp.name)
        }
        if let cid = currentId, let wp = waypoints.first(where: { $0.id == cid }) {
            return (currentId, wp.name)
        }
        if let placemarks = try? await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: coord.lat, longitude: coord.lon)
        ), let p = placemarks.first {
            return (currentId, [p.name, p.locality].compactMap { $0 }.first)
        }
        return (currentId, nil)
    }

    /// Display name for the enrichment path: waypoint name, else a reverse-geocoded address,
    /// else nil (caller keeps the existing name rather than clobbering it). Runs on the
    /// dedicated enrichment geocoder so a concurrent tick resolution never cancels it.
    /// Mirrors Android `resolveDisplayName` (whose "Unknown Location" fallback the caller applies).
    private func resolveDisplayName(currentWaypoint: Waypoint?, coord: Coord) async -> String? {
        if let currentWaypoint { return currentWaypoint.name }
        if let placemarks = try? await enrichGeocoder.reverseGeocodeLocation(
            CLLocation(latitude: coord.lat, longitude: coord.lon)
        ), let p = placemarks.first {
            return [p.name, p.locality].compactMap { $0 }.first
        }
        return nil
    }

    /// Enter/exit notifications fire only on an actual waypoint transition, and never for self.
    /// Mirrors Android `maybeNotifyEntryExit`.
    private func maybeNotifyEntryExit(
        user: User,
        prevId: Int64?,
        currentId: Int64?,
        currentWaypoint: Waypoint?,
        displayName: String,
        waypoints: [Waypoint]
    ) {
        guard currentId != prevId, user.id != Networking.shared.userid else { return }
        if currentId != nil {
            NotificationsUtil.send(
                title: Strings.notifWaypointEnterTitle,
                body: Strings.notifWaypointEnterBody(user.name, currentWaypoint?.name ?? displayName),
                category: "WAYPOINT_ENTER_EXIT",
                userId: user.id
            )
        } else if let pid = prevId {
            let exitedName = waypoints.first { $0.id == pid }?.name ?? user.locationName
            NotificationsUtil.send(
                title: Strings.notifWaypointExitTitle,
                body: Strings.notifWaypointExitBody(user.name, exitedName),
                category: "WAYPOINT_ENTER_EXIT",
                userId: user.id
            )
        }
    }
}
