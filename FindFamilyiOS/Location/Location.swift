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

    private var lastUpdateAt: Date = .distantPast
    private var tickCount = 0
    private var lastBatteryLevels: [Int64: Float] = [:]
    private var lastUserLocationName: [Int64: String] = [:]
    private var isProcessing = false

    /// Last location delivered by CoreLocation. Cached so the timer-driven
    /// heartbeat below can keep publishing even when CLLocationUpdate goes quiet
    /// (e.g. the phone is sitting on a desk).
    private var lastKnownLocation: CLLocation?

    /// Background timer that keeps `runTick` firing every `shareIntervalSeconds`
    /// regardless of whether CoreLocation has delivered a new fix. This mirrors
    /// Modern-Apps Android `syncHeartbeat` which runs on a 30 s loop independent
    /// of location callbacks — without it, a stationary iPhone never calls
    /// `/api/location/receive` and so never sees peer locations.
    private var heartbeatTask: Task<Void, Never>?

    private let geocoder = CLGeocoder()

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
        lastKnownLocation = loc
        let now = Date()
        if !sleep && now.timeIntervalSince(lastUpdateAt) < Self.shareIntervalSeconds { return }
        lastUpdateAt = now
        if isProcessing { return }
        isProcessing = true
        Task { [weak self] in
            await self?.runTick(loc: loc, sleep: sleep)
            self?.isProcessing = false
        }
    }

    private func runTick(loc: CLLocation, sleep: Bool) async {
        guard Networking.shared.isReady else { return }
        let battery = max(0, UIDevice.current.batteryLevel) * 100
        let coord = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let me = LocationValue(
            id: Int64.random(in: Int64.min...Int64.max),
            userid: Networking.shared.userid,
            coord: coord,
            speed: Float(max(0, loc.speed)),
            acc: Float(max(0, loc.horizontalAccuracy)),
            timestamp: Date(),
            battery: battery
        )

        // Periodically (re)register so the server has our current key.
        tickCount += 1
        if tickCount % 100 == 1 { _ = await Networking.shared.ensureUserExists() }

        // 1. Reverse geocode -> "Home" / "Unnamed Location" placeholder.
        var myPlaceName = "Unnamed Location"
        if let placemarks = try? await geocoder.reverseGeocodeLocation(loc),
           let p = placemarks.first {
            myPlaceName = [p.name, p.locality].compactMap { $0 }.first ?? "Unnamed Location"
        }

        // 2. Waypoint enter/exit using haversine.
        let waypoints = Database.shared.waypointsSubject.value
        for wp in waypoints {
            let dist = haversine(coord, wp.coord)
            if dist < wp.range { myPlaceName = wp.name; break }
        }

        // Update the local "Me" user's locationName + persist our own LocationValue so
        // we appear on the map and our own history works.
        Database.shared.insertLocationValue(me)
        if var meUser = Database.shared.user(id: Networking.shared.userid) {
            if meUser.locationName != myPlaceName {
                meUser.locationName = myPlaceName
                meUser.lastLocationChangeTime = Date()
                Database.shared.upsertUser(meUser)
            }
        }

        // 3. Delete expired temporary links.
        let now = Date()
        for link in Database.shared.temporaryLinksSubject.value where link.deleteAt < now {
            Database.shared.deleteTemporaryLink(link)
        }

        // 4. Publish my location to EVERY user in our database (matches Modern-Apps
        // behavior — there's no `sendingEnabled` / `mutualConnection` filter at this
        // layer; discovery happens implicitly via location publishing).
        let users = Database.shared.usersSubject.value
        for u in users where u.id != Networking.shared.userid {
            _ = await Networking.shared.publishLocation(me, toUser: u)
        }
        for link in Database.shared.temporaryLinksSubject.value {
            _ = await Networking.shared.publishLocation(me, toLink: link)
        }

        // 5. Receive incoming peer locations. Any sender we don't already know about
        // is added as AWAITING_REQUEST (Modern-Apps uses received locations — not a
        // separate `/api/request_sharing` endpoint — to discover incoming requests).
        if let incoming = await Networking.shared.receiveLocations() {
            let knownIds = Set(users.map { $0.id } + [Networking.shared.userid])
            let newSenderIds = Set(incoming.map { $0.userid }).subtracting(knownIds)
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
            for loc in incoming {
                Database.shared.insertLocationValue(loc)
                await updateUserLocationName(loc)
                await maybeNotifyBatteryDrop(loc)
            }
        }

        // 6. Trim old locations (>7 days).
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        Database.shared.deleteLocationValuesOlderThan(cutoff)

        // 7. Drain the UWB session-setup channel. Each envelope is published
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

    private func updateUserLocationName(_ loc: LocationValue) async {
        guard var user = Database.shared.user(id: loc.userid) else { return }
        // Recompute the display name on every incoming fix: prefer a matching waypoint,
        // otherwise reverse-geocode the fresh coordinate. This mirrors the local "Me"
        // handling above and Android's heartbeat. Previously the geocode only ran while
        // the stored name was still "Unnamed Location", so once a peer had any real name
        // it never refreshed and the main-page list showed a location stuck for weeks.
        var newName: String?
        for wp in Database.shared.waypointsSubject.value {
            if haversine(loc.coord, wp.coord) < wp.range { newName = wp.name; break }
        }
        if newName == nil,
           let placemarks = try? await geocoder.reverseGeocodeLocation(
               CLLocation(latitude: loc.coord.lat, longitude: loc.coord.lon)
           ), let p = placemarks.first {
            newName = [p.name, p.locality].compactMap { $0 }.first
        }
        // If we couldn't resolve a fresh name, keep the existing one rather than clobbering it.
        let resolved = newName ?? user.locationName
        if resolved != user.locationName {
            user.locationName = resolved
            user.lastLocationChangeTime = Date()
            Database.shared.upsertUser(user)
            if let prev = lastUserLocationName[user.id], prev != resolved {
                NotificationsUtil.send(
                    title: Strings.notifWaypointEnterTitle,
                    body: Strings.notifWaypointEnterBody(user.name, resolved),
                    category: "WAYPOINT_ENTER_EXIT"
                )
            }
            lastUserLocationName[user.id] = resolved
        }
    }

    private func maybeNotifyBatteryDrop(_ loc: LocationValue) async {
        let prev = lastBatteryLevels[loc.userid]
        lastBatteryLevels[loc.userid] = loc.battery
        guard let prev = prev else { return }
        if prev > 20 && loc.battery <= 20 {
            if let user = Database.shared.user(id: loc.userid) {
                NotificationsUtil.send(
                    title: Strings.notifBatteryLowTitle,
                    body: Strings.notifBatteryLowBody(user.name, Int(loc.battery)),
                    category: "BATTERY_LOW"
                )
            }
        }
    }
}
