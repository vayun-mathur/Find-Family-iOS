import Foundation
import Combine
import SQLite3

/// Lightweight SQLite wrapper providing CRUD + Combine publishers for each entity.
/// All access is serialized through a single dispatch queue to keep things simple and safe.
///
/// Declared `@unchecked Sendable` (rather than plain `Sendable`) because the compiler
/// cannot verify queue discipline: all SQLite access (`db`) goes through `queue`, and
/// the `CurrentValueSubject`s are internally lock-protected — which is what makes
/// `shared` safe from any isolation (Swift 6 requirement).
final class Database: @unchecked Sendable {
    static let shared = Database()

    private let queue = DispatchQueue(label: "cc.findfamily.db", qos: .userInitiated)
    private var db: OpaquePointer?

    // Publishers for live data. Each subject re-emits when the underlying table changes.
    let usersSubject = CurrentValueSubject<[User], Never>([])
    let waypointsSubject = CurrentValueSubject<[Waypoint], Never>([])
    let temporaryLinksSubject = CurrentValueSubject<[TemporaryLink], Never>([])
    let locationValuesSubject = CurrentValueSubject<[LocationValue], Never>([])
    let latestLocationsSubject = CurrentValueSubject<[Int64: LocationValue], Never>([:])
    let noShowAlertsSubject = CurrentValueSubject<[NoShowAlert], Never>([])
    /// Persisted outbound-sharing master switch (Android `GLOBAL_SHARING_ENABLED_KEY`).
    /// Default true (opt-out). When off, `runTick` publishes to nobody but keeps receiving.
    let globalSharingEnabledSubject = CurrentValueSubject<Bool, Never>(true)

    private init() {
        open()
        migrate()
        reloadAll()
    }

    // MARK: - Open / migrate

    private var dbPath: String {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return dir.appendingPathComponent("findfamily.sqlite").path
    }

    private func open() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            fatalError("Could not open SQLite at \(dbPath)")
        }
        exec("PRAGMA foreign_keys = ON;")
        exec("PRAGMA journal_mode = WAL;")
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            photo TEXT,
            locationName TEXT NOT NULL,
            sendingEnabled INTEGER NOT NULL,
            requestStatus TEXT NOT NULL,
            lastLocationChangeTime INTEGER NOT NULL,
            encryptionKey TEXT
        );
        """)
        // Idempotent add-column migration. SQLite has no `ADD COLUMN IF NOT EXISTS`;
        // we check the schema first so the migration is silent on subsequent launches.
        if !columnExists(table: "users", column: "platform") {
            exec("ALTER TABLE users ADD COLUMN platform TEXT;")
        }
        if !columnExists(table: "users", column: "pqcEncryptionKey") {
            // PQC bundle cache (base64 of [4B kemLen][kemPubDer][dsaPubDer]) — same format as Office.
            exec("ALTER TABLE users ADD COLUMN pqcEncryptionKey TEXT;")
        }
        if !columnExists(table: "users", column: "lastWaypointId") {
            // Waypoint enter/exit hysteresis state (nullable). Additive migration only.
            exec("ALTER TABLE users ADD COLUMN lastWaypointId INTEGER;")
        }
        if !columnExists(table: "users", column: "sharingAutoToggleAt") {
            // Auto-toggle deadline in epoch seconds (nullable = "Never"). Additive migration only.
            exec("ALTER TABLE users ADD COLUMN sharingAutoToggleAt INTEGER;")
        }
        if !columnExists(table: "users", column: "inboundPairId") {
            // Hidden sender-auth secrets (GHSA-x94x-v6f7-wwpp): per-peer pair IDs, nullable
            // (= unpinned/legacy). Additive migration only; pinning happens at runtime.
            exec("ALTER TABLE users ADD COLUMN inboundPairId TEXT;")
        }
        if !columnExists(table: "users", column: "outboundPairId") {
            exec("ALTER TABLE users ADD COLUMN outboundPairId TEXT;")
        }
        if !columnExists(table: "users", column: "kind") {
            // Person vs tracker row. TEXT name (`"PERSON"`/`"TRACKER"`), defaulting
            // existing rows to PERSON. Additive migration only. Mirrors Android v9->10.
            exec("ALTER TABLE users ADD COLUMN kind TEXT NOT NULL DEFAULT 'PERSON';")
        }
        if !columnExists(table: "users", column: "sharingAutoToggleWaypointId") {
            // Arrival auto-toggle trigger (waypoint id). Null = none. Mutually exclusive
            // with sharingAutoToggleAt. Additive migration only. Mirrors Android v8->9.
            exec("ALTER TABLE users ADD COLUMN sharingAutoToggleWaypointId INTEGER;")
        }
        exec("""
        CREATE TABLE IF NOT EXISTS waypoints (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            name TEXT NOT NULL,
            range REAL NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS locationValues (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            userid INTEGER NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            speed REAL NOT NULL,
            acc REAL NOT NULL,
            timestamp INTEGER NOT NULL,
            battery REAL NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS index_LocationValue_timestamp ON locationValues (timestamp);")
        exec("CREATE INDEX IF NOT EXISTS index_LocationValue_userid_timestamp ON locationValues (userid, timestamp);")
        if !columnExists(table: "locationValues", column: "reportedAt") {
            // When the report was SENT (epoch seconds). Backfills from `timestamp`: every
            // pre-migration row was a live report, where the two are equal.
            // Mirrors Android v11->12.
            exec("ALTER TABLE locationValues ADD COLUMN reportedAt INTEGER NOT NULL DEFAULT 0;")
            exec("UPDATE locationValues SET reportedAt = timestamp WHERE reportedAt = 0;")
        }
        if !columnExists(table: "locationValues", column: "source") {
            // `LocationSource` name. Pre-migration rows were all live reports.
            // Mirrors Android v11->12.
            exec("ALTER TABLE locationValues ADD COLUMN source TEXT NOT NULL DEFAULT 'LIVE';")
        }
        exec("CREATE INDEX IF NOT EXISTS index_LocationValue_userid_reportedAt ON locationValues (userid, reportedAt);")
        exec("""
        CREATE TABLE IF NOT EXISTS temporaryLinks (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            name TEXT NOT NULL,
            key TEXT NOT NULL,
            publicKey TEXT NOT NULL,
            deleteAt INTEGER NOT NULL
        );
        """)
        if !columnExists(table: "temporaryLinks", column: "pqcPublicKey") {
            exec("ALTER TABLE temporaryLinks ADD COLUMN pqcPublicKey TEXT;")
        }
        if !columnExists(table: "temporaryLinks", column: "pqcKey") {
            exec("ALTER TABLE temporaryLinks ADD COLUMN pqcKey TEXT;")
        }
        if !columnExists(table: "temporaryLinks", column: "pqcSeed") {
            exec("ALTER TABLE temporaryLinks ADD COLUMN pqcSeed TEXT;")
        }
        exec("""
        CREATE TABLE IF NOT EXISTS noShowAlerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            watchedUserId INTEGER NOT NULL,
            waypointId INTEGER,
            expectedAt INTEGER NOT NULL,
            grace INTEGER NOT NULL,
            fired INTEGER NOT NULL,
            oneShot INTEGER NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS index_NoShowAlert_watchedUserId ON noShowAlerts (watchedUserId);")
        exec("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - Reload helpers

    func reloadAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.usersSubject.send(self.loadUsers())
            self.waypointsSubject.send(self.loadWaypoints())
            self.temporaryLinksSubject.send(self.loadTemporaryLinks())
            let locs = self.loadLocationValues()
            self.locationValuesSubject.send(locs)
            self.latestLocationsSubject.send(Self.computeLatest(locs))
            self.noShowAlertsSubject.send(self.loadNoShowAlerts())
            self.globalSharingEnabledSubject.send(self.loadGlobalSharingEnabled())
        }
    }

    private func reloadLocations() {
        let locs = loadLocationValues()
        locationValuesSubject.send(locs)
        latestLocationsSubject.send(Self.computeLatest(locs))
    }

    private static func computeLatest(_ locs: [LocationValue]) -> [Int64: LocationValue] {
        var out: [Int64: LocationValue] = [:]
        for l in locs {
            if let cur = out[l.userid] {
                // Rank on reportedAt (when we heard it), NOT timestamp (when the fix was
                // measured). A shutdown report deliberately carries a stale fix, so ranking by
                // measurement time makes it lose to the live heartbeat that preceded it — it
                // would be stored and then never surfaced, which is the silent half-working
                // failure this whole distinction exists to prevent. For every peer that
                // predates the field reportedAt == timestamp, so this is a no-op for them.
                if l.reportedAt > cur.reportedAt { out[l.userid] = l }
            } else {
                out[l.userid] = l
            }
        }
        return out
    }

    // MARK: - Users

    func upsertUser(_ u: User) {
        queue.sync {
            let sql = """
            INSERT OR REPLACE INTO users (id, name, photo, locationName, sendingEnabled, requestStatus, lastLocationChangeTime, encryptionKey, platform, pqcEncryptionKey, lastWaypointId, sharingAutoToggleAt, inboundPairId, outboundPairId, kind, sharingAutoToggleWaypointId)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, u.id)
            bindText(stmt, 2, u.name)
            bindOptionalText(stmt, 3, u.photo)
            bindText(stmt, 4, u.locationName)
            sqlite3_bind_int(stmt, 5, u.sendingEnabled ? 1 : 0)
            bindText(stmt, 6, u.requestStatus.rawValue)
            sqlite3_bind_int64(stmt, 7, Int64(u.lastLocationChangeTime.timeIntervalSince1970))
            bindOptionalText(stmt, 8, u.encryptionKey)
            bindOptionalText(stmt, 9, u.platform)
            bindOptionalText(stmt, 10, u.pqcEncryptionKey)
            bindOptionalInt64(stmt, 11, u.lastWaypointId)
            bindOptionalInt64(stmt, 12, u.sharingAutoToggleAt.map { Int64($0.timeIntervalSince1970) })
            bindOptionalText(stmt, 13, u.inboundPairId)
            bindOptionalText(stmt, 14, u.outboundPairId)
            bindText(stmt, 15, u.kind.rawValue)
            bindOptionalInt64(stmt, 16, u.sharingAutoToggleWaypointId)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    // MARK: - Atomic partial updates
    //
    // These mirror Android's UserDao partial-update queries. Whole-row `upsertUser`
    // from a stale snapshot would clobber columns another path just wrote
    // (e.g. `sharingAutoToggleAt` / `sendingEnabled`), so hot paths use these instead.

    /// Atomically update location display metadata without touching sharing/toggle columns.
    func updateLocationMeta(id: Int64, locationName: String, lastWaypointId: Int64?, lastLocationChangeTime: Date) {
        queue.sync {
            let sql = "UPDATE users SET locationName = ?, lastWaypointId = ?, lastLocationChangeTime = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, locationName)
            bindOptionalInt64(stmt, 2, lastWaypointId)
            sqlite3_bind_int64(stmt, 3, Int64(lastLocationChangeTime.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 4, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Atomically set the learned peer platform tag.
    func setPlatform(id: Int64, platform: String) {
        queue.sync {
            let sql = "UPDATE users SET platform = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, platform)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Atomically cache a peer's RSA public key (base64 PEM).
    func setEncryptionKey(id: Int64, encryptionKey: String) {
        queue.sync {
            let sql = "UPDATE users SET encryptionKey = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, encryptionKey)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Atomically cache a peer's PQC public bundle (base64).
    func setPqcEncryptionKey(id: Int64, pqcEncryptionKey: String) {
        queue.sync {
            let sql = "UPDATE users SET pqcEncryptionKey = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, pqcEncryptionKey)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Pin the inbound pair ID expected from a peer (GHSA-x94x-v6f7-wwpp). Guarded by
    /// `IS NULL` so a race or replayed first packet can never overwrite a pin.
    func pinInboundPairId(id: Int64, pairId: String) {
        queue.sync {
            let sql = "UPDATE users SET inboundPairId = ? WHERE id = ? AND inboundPairId IS NULL;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, pairId)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Set our outbound pair ID for a peer (our own secret, our choice).
    func setOutboundPairId(id: Int64, pairId: String) {
        queue.sync {
            let sql = "UPDATE users SET outboundPairId = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, pairId)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Fill our outbound pair ID only when absent (generate-on-first-send for legacy rows).
    func setOutboundPairIdIfAbsent(id: Int64, pairId: String) {
        queue.sync {
            let sql = "UPDATE users SET outboundPairId = ? WHERE id = ? AND outboundPairId IS NULL;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, pairId)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Atomically set only the auto-toggle deadline (nil = "Never"). Also clears any arrival
    /// trigger so the two auto-toggle modes stay mutually exclusive (mirrors Android).
    func setSharingAutoToggleAt(id: Int64, at: Date?) {
        queue.sync {
            let sql = "UPDATE users SET sharingAutoToggleAt = ?, sharingAutoToggleWaypointId = NULL WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindOptionalInt64(stmt, 1, at.map { Int64($0.timeIntervalSince1970) })
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Atomically set the arrival auto-toggle waypoint (nil = none). Also clears any time-based
    /// deadline so the two auto-toggle modes stay mutually exclusive (mirrors Android).
    func setSharingAutoToggleWaypointId(id: Int64, waypointId: Int64?) {
        queue.sync {
            let sql = "UPDATE users SET sharingAutoToggleWaypointId = ?, sharingAutoToggleAt = NULL WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindOptionalInt64(stmt, 1, waypointId)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Atomically flip sharing for every row whose arrival trigger points at a waypoint "Me"
    /// is currently inside. The waypoint id in the WHERE clause guards against TOCTOU races
    /// the same way the timer does: a cleared or re-pointed trigger no longer matches. Clears
    /// the trigger on flip so it fires once per arrival. Mirrors Android `applyDueArrivalToggles`.
    /// Returns rows flipped.
    @discardableResult
    func applyDueArrivalToggles(insideWaypointIds: [Int64]) -> Int {
        guard !insideWaypointIds.isEmpty else { return 0 }
        return queue.sync {
            let placeholders = insideWaypointIds.map { _ in "?" }.joined(separator: ",")
            let sql = "UPDATE users SET sendingEnabled = CASE WHEN sendingEnabled THEN 0 ELSE 1 END, sharingAutoToggleWaypointId = NULL WHERE sharingAutoToggleWaypointId IS NOT NULL AND sharingAutoToggleWaypointId IN (\(placeholders));"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            for (i, wid) in insideWaypointIds.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), wid)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            let changed = Int(sqlite3_changes(db))
            if changed > 0 {
                usersSubject.send(loadUsers())
            }
            return changed
        }
    }

    /// Atomically set sharing enabled AND clear any pending auto-toggle (manual toggle path).
    func setSendingEnabledAndClearToggle(id: Int64, enabled: Bool) {
        queue.sync {
            let sql = "UPDATE users SET sendingEnabled = ?, sharingAutoToggleAt = NULL, sharingAutoToggleWaypointId = NULL WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
        }
    }

    /// Atomically flip sharing for every row whose timer is due, clearing the timer.
    /// The WHERE clause guards against TOCTOU races: if the user manually cleared (NULL)
    /// or rescheduled to the future, the row no longer matches. Returns rows flipped.
    @discardableResult
    func applyDueAutoToggles(now: Date) -> Int {
        queue.sync {
            let nowEpoch = Int64(now.timeIntervalSince1970)
            let sql = "UPDATE users SET sendingEnabled = CASE WHEN sendingEnabled THEN 0 ELSE 1 END, sharingAutoToggleAt = NULL WHERE sharingAutoToggleAt IS NOT NULL AND sharingAutoToggleAt <= ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, nowEpoch)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            let changed = Int(sqlite3_changes(db))
            if changed > 0 {
                usersSubject.send(loadUsers())
            }
            return changed
        }
    }

    func deleteUser(_ u: User) {
        queue.sync {
            exec("DELETE FROM users WHERE id = \(u.id);")
            exec("DELETE FROM locationValues WHERE userid = \(u.id);")
            usersSubject.send(loadUsers())
            reloadLocations()
        }
    }

    private func loadUsers() -> [User] {
        var out: [User] = []
        // kind/sharingAutoToggleWaypointId columns added via idempotent migrations;
        // SELECT explicitly to handle older dbs (see rc-fallback below).
        let sql = "SELECT id, name, photo, locationName, sendingEnabled, requestStatus, lastLocationChangeTime, encryptionKey, platform, pqcEncryptionKey, lastWaypointId, sharingAutoToggleAt, inboundPairId, outboundPairId, kind, sharingAutoToggleWaypointId FROM users;"
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            // Fallback: older schema without the newer columns (should be migrated, but be safe during dev).
            sqlite3_finalize(stmt)
            let sql2 = "SELECT id, name, photo, locationName, sendingEnabled, requestStatus, lastLocationChangeTime, encryptionKey, platform FROM users;"
            sqlite3_prepare_v2(db, sql2, -1, &stmt, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(User(
                    id: sqlite3_column_int64(stmt, 0),
                    name: text(stmt, 1) ?? "",
                    photo: text(stmt, 2),
                    locationName: text(stmt, 3) ?? "",
                    sendingEnabled: sqlite3_column_int(stmt, 4) != 0,
                    requestStatus: RequestStatus(rawValue: text(stmt, 5) ?? "MUTUAL_CONNECTION") ?? .mutualConnection,
                    lastLocationChangeTime: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6))),
                    encryptionKey: text(stmt, 7),
                    platform: text(stmt, 8),
                    pqcEncryptionKey: nil,
                    kind: .person,
                    lastWaypointId: nil,
                    sharingAutoToggleAt: nil,
                    sharingAutoToggleWaypointId: nil
                ))
            }
            sqlite3_finalize(stmt)
            return out
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(User(
                id: sqlite3_column_int64(stmt, 0),
                name: text(stmt, 1) ?? "",
                photo: text(stmt, 2),
                locationName: text(stmt, 3) ?? "",
                sendingEnabled: sqlite3_column_int(stmt, 4) != 0,
                requestStatus: RequestStatus(rawValue: text(stmt, 5) ?? "MUTUAL_CONNECTION") ?? .mutualConnection,
                lastLocationChangeTime: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6))),
                encryptionKey: text(stmt, 7),
                platform: text(stmt, 8),
                pqcEncryptionKey: text(stmt, 9),
                inboundPairId: text(stmt, 12),
                outboundPairId: text(stmt, 13),
                kind: UserKind(rawValue: text(stmt, 14) ?? "PERSON") ?? .person,
                lastWaypointId: optInt64(stmt, 10),
                sharingAutoToggleAt: optInt64(stmt, 11).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sharingAutoToggleWaypointId: optInt64(stmt, 15)
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func user(id: Int64) -> User? {
        usersSubject.value.first { $0.id == id }
    }

    // MARK: - Waypoints

    func upsertWaypoint(_ w: Waypoint) -> Waypoint {
        var result = w
        queue.sync {
            if w.id == 0 {
                let sql = "INSERT INTO waypoints (name, range, lat, lon) VALUES (?, ?, ?, ?);"
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                bindText(stmt, 1, w.name)
                sqlite3_bind_double(stmt, 2, w.range)
                sqlite3_bind_double(stmt, 3, w.coord.lat)
                sqlite3_bind_double(stmt, 4, w.coord.lon)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                result.id = sqlite3_last_insert_rowid(db)
            } else {
                let sql = "INSERT OR REPLACE INTO waypoints (id, name, range, lat, lon) VALUES (?, ?, ?, ?, ?);"
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                sqlite3_bind_int64(stmt, 1, w.id)
                bindText(stmt, 2, w.name)
                sqlite3_bind_double(stmt, 3, w.range)
                sqlite3_bind_double(stmt, 4, w.coord.lat)
                sqlite3_bind_double(stmt, 5, w.coord.lon)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            waypointsSubject.send(loadWaypoints())
        }
        return result
    }

    func deleteWaypoint(_ w: Waypoint) {
        queue.sync {
            exec("DELETE FROM waypoints WHERE id = \(w.id);")
            waypointsSubject.send(loadWaypoints())
        }
    }

    private func loadWaypoints() -> [Waypoint] {
        var out: [Waypoint] = []
        let sql = "SELECT id, name, range, lat, lon FROM waypoints;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Waypoint(
                id: sqlite3_column_int64(stmt, 0),
                name: text(stmt, 1) ?? "",
                range: sqlite3_column_double(stmt, 2),
                coord: Coord(lat: sqlite3_column_double(stmt, 3), lon: sqlite3_column_double(stmt, 4))
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - LocationValues

    func insertLocationValue(_ l: LocationValue) {
        queue.sync {
            let sql = "INSERT INTO locationValues (userid, lat, lon, speed, acc, timestamp, battery, reportedAt, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, l.userid)
            sqlite3_bind_double(stmt, 2, l.coord.lat)
            sqlite3_bind_double(stmt, 3, l.coord.lon)
            sqlite3_bind_double(stmt, 4, Double(l.speed))
            sqlite3_bind_double(stmt, 5, Double(l.acc))
            sqlite3_bind_int64(stmt, 6, Int64(l.timestamp.timeIntervalSince1970))
            sqlite3_bind_double(stmt, 7, Double(l.battery))
            sqlite3_bind_int64(stmt, 8, Int64(l.reportedAt.timeIntervalSince1970))
            bindText(stmt, 9, l.source.rawValue)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            reloadLocations()
        }
    }

    func deleteLocationValuesOlderThan(_ cutoff: Date) {
        queue.sync {
            exec("DELETE FROM locationValues WHERE timestamp < \(Int64(cutoff.timeIntervalSince1970));")
            reloadLocations()
        }
    }

    func locationsFor(userid: Int64) -> [LocationValue] {
        locationValuesSubject.value.filter { $0.userid == userid }
    }

    private func loadLocationValues() -> [LocationValue] {
        var out: [LocationValue] = []
        // reportedAt/source persisted since the schema step; older rows backfilled at
        // migration time, so the SELECT reads them directly — no reconstruction.
        let sql = "SELECT id, userid, lat, lon, speed, acc, timestamp, battery, reportedAt, source FROM locationValues;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let measured = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
            let sent: Date = optInt64(stmt, 8).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? measured
            out.append(LocationValue(
                id: sqlite3_column_int64(stmt, 0),
                userid: sqlite3_column_int64(stmt, 1),
                coord: Coord(lat: sqlite3_column_double(stmt, 2), lon: sqlite3_column_double(stmt, 3)),
                speed: Float(sqlite3_column_double(stmt, 4)),
                acc: Float(sqlite3_column_double(stmt, 5)),
                timestamp: measured,
                battery: Float(sqlite3_column_double(stmt, 7)),
                reportedAt: sent,
                source: LocationSource.decode(text(stmt, 9))
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Temporary links

    func upsertTemporaryLink(_ link: TemporaryLink) -> TemporaryLink {
        var result = link
        queue.sync {
            if link.id == 0 {
                let sql = "INSERT INTO temporaryLinks (name, key, publicKey, deleteAt, pqcPublicKey, pqcKey, pqcSeed) VALUES (?, ?, ?, ?, ?, ?, ?);"
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                bindText(stmt, 1, link.name)
                bindText(stmt, 2, link.key)
                bindText(stmt, 3, link.publicKey)
                sqlite3_bind_int64(stmt, 4, Int64(link.deleteAt.timeIntervalSince1970))
                bindOptionalText(stmt, 5, link.pqcPublicKey)
                bindOptionalText(stmt, 6, link.pqcKey)
                bindOptionalText(stmt, 7, link.pqcSeed)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                result.id = sqlite3_last_insert_rowid(db)
            } else {
                let sql = "INSERT OR REPLACE INTO temporaryLinks (id, name, key, publicKey, deleteAt, pqcPublicKey, pqcKey, pqcSeed) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                sqlite3_bind_int64(stmt, 1, link.id)
                bindText(stmt, 2, link.name)
                bindText(stmt, 3, link.key)
                bindText(stmt, 4, link.publicKey)
                sqlite3_bind_int64(stmt, 5, Int64(link.deleteAt.timeIntervalSince1970))
                bindOptionalText(stmt, 6, link.pqcPublicKey)
                bindOptionalText(stmt, 7, link.pqcKey)
                bindOptionalText(stmt, 8, link.pqcSeed)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            temporaryLinksSubject.send(loadTemporaryLinks())
        }
        return result
    }

    func deleteTemporaryLink(_ link: TemporaryLink) {
        queue.sync {
            exec("DELETE FROM temporaryLinks WHERE id = \(link.id);")
            temporaryLinksSubject.send(loadTemporaryLinks())
        }
    }

    private func loadTemporaryLinks() -> [TemporaryLink] {
        var out: [TemporaryLink] = []
        // Try new schema first; fallback to old if column missing.
        let sql = "SELECT id, name, key, publicKey, deleteAt, pqcPublicKey, pqcKey, pqcSeed FROM temporaryLinks;"
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            sqlite3_finalize(stmt)
            let sql2 = "SELECT id, name, key, publicKey, deleteAt FROM temporaryLinks;"
            sqlite3_prepare_v2(db, sql2, -1, &stmt, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TemporaryLink(
                    id: sqlite3_column_int64(stmt, 0),
                    name: text(stmt, 1) ?? "",
                    key: text(stmt, 2) ?? "",
                    publicKey: text(stmt, 3) ?? "",
                    deleteAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4))),
                    pqcPublicKey: nil,
                    pqcKey: nil,
                    pqcSeed: nil
                ))
            }
            sqlite3_finalize(stmt)
            return out
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TemporaryLink(
                id: sqlite3_column_int64(stmt, 0),
                name: text(stmt, 1) ?? "",
                key: text(stmt, 2) ?? "",
                publicKey: text(stmt, 3) ?? "",
                deleteAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4))),
                pqcPublicKey: text(stmt, 5),
                pqcKey: text(stmt, 6),
                pqcSeed: text(stmt, 7)
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - No-show alerts

    /// Insert a new alert. The id is always allocated by SQLite AUTOINCREMENT, even when the
    /// caller passes a nonzero id — the column is never written explicitly, so a re-imported
    /// row can never collide with a live one.
    @discardableResult
    func createNoShowAlert(_ alert: NoShowAlert) -> NoShowAlert {
        var result = alert
        queue.sync {
            let sql = "INSERT INTO noShowAlerts (watchedUserId, waypointId, expectedAt, grace, fired, oneShot) VALUES (?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, alert.watchedUserId)
            bindOptionalInt64(stmt, 2, alert.waypointId)
            sqlite3_bind_int64(stmt, 3, Int64(alert.expectedAt.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 4, Int64((alert.grace * 1000).rounded()))
            sqlite3_bind_int(stmt, 5, alert.fired ? 1 : 0)
            sqlite3_bind_int(stmt, 6, alert.oneShot ? 1 : 0)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            result.id = sqlite3_last_insert_rowid(db)
            noShowAlertsSubject.send(loadNoShowAlerts())
        }
        return result
    }

    func noShowAlert(id: Int64) -> NoShowAlert? {
        noShowAlertsSubject.value.first { $0.id == id }
    }

    /// Alerts whose deadline (`expectedAt` + `grace`) has passed and which have not fired yet.
    /// Due-ness is decided by `NoShowPolicy.isDue` — the same function the scheduler's
    /// fire-guard uses — so the query and the policy can never drift apart (mirrors Android,
    /// where `getDue` and `NoShowPolicy.isDue` agree by construction).
    func dueNoShowAlerts(now: Date) -> [NoShowAlert] {
        noShowAlertsSubject.value.filter {
            !$0.fired && NoShowPolicy.isDue(expectedAt: $0.expectedAt, grace: $0.grace, now: now)
        }
    }

    /// Mark fired only if the row has not fired yet, so two concurrent scheduler runs cannot
    /// both claim it. Returns rows updated (0 or 1). Mirrors Android `markFired`.
    @discardableResult
    func markNoShowAlertFired(id: Int64) -> Int {
        queue.sync {
            let sql = "UPDATE noShowAlerts SET fired = 1 WHERE id = ? AND fired = 0;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            let changed = Int(sqlite3_changes(db))
            if changed > 0 {
                noShowAlertsSubject.send(loadNoShowAlerts())
            }
            return changed
        }
    }

    func rearmNoShowAlert(id: Int64) {
        queue.sync {
            let sql = "UPDATE noShowAlerts SET fired = 0 WHERE id = ?;"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            noShowAlertsSubject.send(loadNoShowAlerts())
        }
    }

    func deleteNoShowAlert(_ alert: NoShowAlert) {
        queue.sync {
            exec("DELETE FROM noShowAlerts WHERE id = \(alert.id);")
            noShowAlertsSubject.send(loadNoShowAlerts())
        }
    }

    private func loadNoShowAlerts() -> [NoShowAlert] {
        var out: [NoShowAlert] = []
        let sql = "SELECT id, watchedUserId, waypointId, expectedAt, grace, fired, oneShot FROM noShowAlerts;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(NoShowAlert(
                id: sqlite3_column_int64(stmt, 0),
                watchedUserId: sqlite3_column_int64(stmt, 1),
                waypointId: optInt64(stmt, 2),
                expectedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3))),
                grace: TimeInterval(sqlite3_column_int64(stmt, 4)) / 1000.0,
                fired: sqlite3_column_int(stmt, 5) != 0,
                oneShot: sqlite3_column_int(stmt, 6) != 0
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Settings (persisted key/value)

    /// Reads the persisted global-sharing switch (default true = opt-out, mirrors Android
    /// `GLOBAL_SHARING_ENABLED_KEY`). Synchronous on the DB queue; callers should prefer the
    /// `globalSharingEnabledSubject` snapshot on the tick path.
    func isGlobalSharingEnabled() -> Bool {
        queue.sync { loadGlobalSharingEnabled() }
    }

    func setGlobalSharingEnabled(_ enabled: Bool) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO settings (key, value) VALUES ('globalSharingEnabled', ?);"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            bindText(stmt, 1, enabled ? "1" : "0")
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            globalSharingEnabledSubject.send(enabled)
        }
    }

    /// Unsychronized read for use from inside `queue.sync` blocks (reloadAll) and the
    /// `isGlobalSharingEnabled()` wrapper. Must only be called on the DB queue.
    private func loadGlobalSharingEnabled() -> Bool {
        let sql = "SELECT value FROM settings WHERE key = 'globalSharingEnabled';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return true
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
        return (text(stmt, 0) ?? "1") != "0"
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            print("SQLite error executing [\(sql)]: \(msg)")
            sqlite3_free(err)
        }
    }

    /// Returns true if `column` already exists on `table`. Used to make ALTER TABLE
    /// migrations idempotent across launches (SQLite has no ADD COLUMN IF NOT EXISTS).
    private func columnExists(table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1), String(cString: cstr) == column {
                return true
            }
        }
        return false
    }

    private func text(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }

    /// Reads a nullable INTEGER column, returning nil for SQL NULL.
    private func optInt64(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, idx)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ s: String) {
        sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ s: String?) {
        if let s = s {
            bindText(stmt, idx, s)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindOptionalInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ v: Int64?) {
        if let v = v {
            sqlite3_bind_int64(stmt, idx, v)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }
}
