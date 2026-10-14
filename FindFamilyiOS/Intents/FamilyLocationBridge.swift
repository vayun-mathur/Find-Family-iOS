import Combine
import Foundation

// MARK: - Family location App Group bridge (maps channel)

/// Publishes the latest family locations as JSON into the shared App Group
/// container `group.cc.findfamily.ios`, so a sibling extension or app (e.g. a
/// maps widget) can draw family pins without its own relay access.
///
/// Mirrors Android `ipc/FamilyLocationService.kt`:
/// - one snapshot per change (users + latest locations joined here instead of a
///   `combine` flow), written under `family_locations.json`;
/// - the device's own row is deliberately omitted — a consumer already draws the
///   user's own position from its own fix, so including it would put a second,
///   staler marker on top (same comment as Android `buildSnapshot`);
/// - rows without a display name are skipped — a nameless pin isn't actionable.
///
/// Wire shape (per entry): `{"id":<int64>,"name":<string>,"lat":<double>,
/// `"lon":<double>,"timestamp":<epoch seconds>,"battery":<0-100 float>}`.
/// Parallel to Android's parallel-array Bundle payload, in self-describing JSON.
///
/// Provisioning note: the container id must be registered under the same Apple
/// Developer Team as the app, and the app's `FindFamilyiOS.entitlements` must
/// list it under `com.apple.security.application-groups`. Without that profile
/// the write below is a no-op (container URL resolves nil) — it never throws.
enum FamilyLocationBridge {
    /// App Group id. Matches the `com.apple.security.application-groups` entry
    /// in `FindFamilyiOS.entitlements` (NEW file, next to `Info.plist`).
    static let groupIdentifier = "group.cc.findfamily.ios"

    /// File inside the shared container holding the latest snapshot JSON.
    static let fileName = "family_locations.json"

    /// Subscription state. Main-actor bound: only `start()` (itself `@MainActor`)
    /// touches these, so they are safe as global-actor-isolated state (Swift 6).
    @MainActor private static var bag = Set<AnyCancellable>()
    @MainActor private static var started = false

    /// Start publishing. Safe to call repeatedly; the second call is a no-op.
    /// Call sites: `AppDelegate` after networking starts (main actor).
    @MainActor
    static func start() {
        guard !started else { return }
        started = true
        // Identity is stable once networking has started; capture it here on the
        // main actor rather than reaching into `Networking` from the utility queue.
        let selfId = Networking.shared.userid
        // One snapshot per change of either side of the join.
        Publishers.CombineLatest(Database.shared.usersSubject, Database.shared.latestLocationsSubject)
            .receive(on: DispatchQueue.global(qos: .utility))
            .sink { users, latest in
                publish(users: users, latest: latest, selfId: selfId)
            }
            .store(in: &bag)
    }

    /// Builds the snapshot for these inputs and writes it, if the App Group
    /// container is available. Pure enough to unit-test the filtering.
    static func snapshot(users: [User], latest: [Int64: LocationValue], selfId: Int64) -> [[String: Any]] {
        // `selfId` is 0 until the identity bootstrap has run, and no real id is 0,
        // so the guard also stops a pre-init snapshot dropping an innocent row.
        var out: [[String: Any]] = []
        out.reserveCapacity(latest.count)
        for (id, loc) in latest {
            if selfId != 0 && id == selfId { continue }
            // Skip anyone we can't label — a nameless pin isn't actionable.
            guard let user = users.first(where: { $0.id == id }),
                  !user.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            out.append([
                "id": id,
                "name": user.name,
                "lat": loc.coord.lat,
                "lon": loc.coord.lon,
                "timestamp": Int64(loc.timestamp.timeIntervalSince1970),
                "battery": Double(loc.battery),
            ])
        }
        // Stable order so consumers diff cheaply.
        out.sort { ($0["id"] as! Int64) < ($1["id"] as! Int64) }
        return out
    }

    private static func publish(users: [User], latest: [Int64: LocationValue], selfId: Int64) {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            // Provisioning not set up (no matching profile / entitlements) — stay silent.
            return
        }
        let rows = snapshot(users: users, latest: latest, selfId: selfId)
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []) else { return }
        let url = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("FamilyLocationBridge: write failed: \(error.localizedDescription)")
        }
    }
}
