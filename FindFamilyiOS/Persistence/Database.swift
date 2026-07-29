import Foundation
import Combine
import SQLite3

/// Lightweight SQLite wrapper providing CRUD + Combine publishers for each entity.
/// All access is serialized through a single dispatch queue to keep things simple and safe.
final class Database {
    static let shared = Database()

    private let queue = DispatchQueue(label: "cc.findfamily.db", qos: .userInitiated)
    private var db: OpaquePointer?

    // Publishers for live data. Each subject re-emits when the underlying table changes.
    let usersSubject = CurrentValueSubject<[User], Never>([])
    let waypointsSubject = CurrentValueSubject<[Waypoint], Never>([])
    let temporaryLinksSubject = CurrentValueSubject<[TemporaryLink], Never>([])
    let locationValuesSubject = CurrentValueSubject<[LocationValue], Never>([])
    let latestLocationsSubject = CurrentValueSubject<[Int64: LocationValue], Never>([:])

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
                if l.timestamp > cur.timestamp { out[l.userid] = l }
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
            INSERT OR REPLACE INTO users (id, name, photo, locationName, sendingEnabled, requestStatus, lastLocationChangeTime, encryptionKey, platform, pqcEncryptionKey)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            usersSubject.send(loadUsers())
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
        // pqcEncryptionKey column added via idempotent migration; SELECT explicitly to handle older dbs.
        let sql = "SELECT id, name, photo, locationName, sendingEnabled, requestStatus, lastLocationChangeTime, encryptionKey, platform, pqcEncryptionKey FROM users;"
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            // Fallback: older schema without pqcEncryptionKey (should be migrated, but be safe during dev).
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
                    pqcEncryptionKey: nil
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
                pqcEncryptionKey: text(stmt, 9)
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
            let sql = "INSERT INTO locationValues (userid, lat, lon, speed, acc, timestamp, battery) VALUES (?, ?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, l.userid)
            sqlite3_bind_double(stmt, 2, l.coord.lat)
            sqlite3_bind_double(stmt, 3, l.coord.lon)
            sqlite3_bind_double(stmt, 4, Double(l.speed))
            sqlite3_bind_double(stmt, 5, Double(l.acc))
            sqlite3_bind_int64(stmt, 6, Int64(l.timestamp.timeIntervalSince1970))
            sqlite3_bind_double(stmt, 7, Double(l.battery))
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
        let sql = "SELECT id, userid, lat, lon, speed, acc, timestamp, battery FROM locationValues;"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(LocationValue(
                id: sqlite3_column_int64(stmt, 0),
                userid: sqlite3_column_int64(stmt, 1),
                coord: Coord(lat: sqlite3_column_double(stmt, 2), lon: sqlite3_column_double(stmt, 3)),
                speed: Float(sqlite3_column_double(stmt, 4)),
                acc: Float(sqlite3_column_double(stmt, 5)),
                timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6))),
                battery: Float(sqlite3_column_double(stmt, 7))
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
                let sql = "INSERT INTO temporaryLinks (name, key, publicKey, deleteAt, pqcPublicKey, pqcKey) VALUES (?, ?, ?, ?, ?, ?);"
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                bindText(stmt, 1, link.name)
                bindText(stmt, 2, link.key)
                bindText(stmt, 3, link.publicKey)
                sqlite3_bind_int64(stmt, 4, Int64(link.deleteAt.timeIntervalSince1970))
                bindOptionalText(stmt, 5, link.pqcPublicKey)
                bindOptionalText(stmt, 6, link.pqcKey)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                result.id = sqlite3_last_insert_rowid(db)
            } else {
                let sql = "INSERT OR REPLACE INTO temporaryLinks (id, name, key, publicKey, deleteAt, pqcPublicKey, pqcKey) VALUES (?, ?, ?, ?, ?, ?, ?);"
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                sqlite3_bind_int64(stmt, 1, link.id)
                bindText(stmt, 2, link.name)
                bindText(stmt, 3, link.key)
                bindText(stmt, 4, link.publicKey)
                sqlite3_bind_int64(stmt, 5, Int64(link.deleteAt.timeIntervalSince1970))
                bindOptionalText(stmt, 6, link.pqcPublicKey)
                bindOptionalText(stmt, 7, link.pqcKey)
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
        let sql = "SELECT id, name, key, publicKey, deleteAt, pqcPublicKey, pqcKey FROM temporaryLinks;"
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
                    pqcKey: nil
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
                pqcKey: text(stmt, 6)
            ))
        }
        sqlite3_finalize(stmt)
        return out
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
}
