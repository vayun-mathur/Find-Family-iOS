import Foundation
import CoreLocation

// MARK: - Coord

struct Coord: Codable, Hashable, Equatable {
    var lat: Double
    var lon: Double

    init(_ lat: Double, _ lon: Double) {
        self.lat = lat
        self.lon = lon
    }
    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static let zero = Coord(0, 0)
}

/// Great-circle distance in meters (Haversine).
func haversine(_ p1: Coord, _ p2: Coord) -> Double {
    let R = 6_371_000.0
    let dLat = (p2.lat - p1.lat) * .pi / 180
    let dLon = (p2.lon - p1.lon) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(p1.lat * .pi / 180) * cos(p2.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return R * c
}

// MARK: - Request status

enum RequestStatus: String, Codable, CaseIterable {
    case mutualConnection = "MUTUAL_CONNECTION"
    case awaitingRequest = "AWAITING_REQUEST"
    case awaitingResponse = "AWAITING_RESPONSE"
}

// MARK: - User

/// Distinguishes a normal person contact from a tracker row. Trackers reuse the
/// `User` row (and therefore the whole map/list/relay pipeline) but are
/// non-interactive. Stored as the enum name (`"PERSON"`/`"TRACKER"`), matching Android.
/// Release rows are always `.person`.
enum UserKind: String, Codable, Hashable {
    case person = "PERSON"
    case tracker = "TRACKER"
}

/// Tracker hardware support on iOS. The data layer understands tracker rows
/// (`UserKind.tracker`, inbound-auth exclusion) so cross-platform relay packets
/// never break parsing — but there is deliberately no tracker UI on iOS
/// (no add/bind/scan flows) and this gate must stay `false`. Any future
/// tracker surface must check `TrackerFeature.isEnabled` first, mirroring
/// Android's `TrackerFeature` (`BuildConfig.DEV_BUILD`) gate.
enum TrackerFeature {
    static let isEnabled = false
}

struct User: Identifiable, Codable, Hashable, Equatable {
    var id: Int64
    var name: String
    /// Either an "image-data:base64,..." string, a contact identifier, or nil.
    var photo: String?
    var locationName: String
    var sendingEnabled: Bool
    var requestStatus: RequestStatus
    var lastLocationChangeTime: Date
    /// Cached recipient public key (base64-encoded PEM).
    var encryptionKey: String?
    /// Peer device platform (`"android"` or `"ios"`), learned from incoming heartbeats.
    /// Used by the UWB ranging path to pick same-platform vs cross-platform protocol.
    var platform: String? = nil
    /// Post-quantum public bundle (base64 of [4B kemLen][kemPubDer][dsaPubDer]), nullable for migration.
    /// Same format as Android Office `Pqc.bundle` / `ff_pqc` key directory.
    var pqcEncryptionKey: String? = nil
    /// Hidden per-peer sender-auth secrets (GHSA-x94x-v6f7-wwpp). Encryption to the peer's
    /// bundle proves who a packet is *for*, not who it is *from*, and the userid inside is
    /// self-declared. Each direction holds its own 128-bit secret (base64url unpadded):
    /// `outboundPairId` is what this device puts in every packet to this peer (created once
    /// at explicit connect time); `inboundPairId` is what it expects from them, pinned
    /// trust-on-first-use. Null = unpinned/legacy. Never user-visible, never logged in
    /// full, never sent outside the encrypted payload.
    var inboundPairId: String? = nil
    var outboundPairId: String? = nil
    /// Whether this row is a person contact or a tracker. Defaults to `.person`;
    /// only tracker rows ever carry it as `.tracker`. Mirrors Android `User.kind`.
    var kind: UserKind = .person
    /// Id of the waypoint this user is currently inside, used for enter/exit hysteresis.
    /// Nullable for migration and when the user is outside every waypoint.
    var lastWaypointId: Int64? = nil
    /// Deadline at which `sendingEnabled` auto-flips (the "Disable/Enable after" timer).
    /// `nil` means "Never" (no pending auto-toggle). Nullable for migration.
    var sharingAutoToggleAt: Date? = nil
    /// Waypoint whose arrival (by "Me") flips `sendingEnabled`. Null means no arrival trigger.
    /// Mutually exclusive with `sharingAutoToggleAt`: setting one clears the other.
    /// Mirrors Android `User.sharingAutoToggleWaypointId`.
    var sharingAutoToggleWaypointId: Int64? = nil

    static let empty = User(
        id: 0, name: "", photo: nil, locationName: "Unnamed Location",
        sendingEnabled: false, requestStatus: .mutualConnection,
        lastLocationChangeTime: Date(), encryptionKey: nil, platform: nil, pqcEncryptionKey: nil,
        inboundPairId: nil, outboundPairId: nil,
        lastWaypointId: nil, sharingAutoToggleAt: nil
    )
    // NOTE: no custom Decodable init on purpose. `kind` and `sharingAutoToggleWaypointId`
    // both carry defaults, so the synthesized decoder already tolerates old backups that
    // lack those keys — and, critically, adding any custom init would suppress the
    // memberwise initializer every call site uses.
}

// MARK: - Waypoint

struct Waypoint: Identifiable, Codable, Hashable, Equatable {
    var id: Int64
    var name: String
    /// Geofence radius in meters.
    var range: Double
    var coord: Coord

    static let newWaypoint = Waypoint(id: 0, name: "", range: 100, coord: .zero)
}

// MARK: - LocationValue

/// Why a location was reported. Mirrors `LocationSource` in Modern-Apps.
///
/// The distinction that matters: `live`, `shutdown` and `batteryLow` all describe *the tracked
/// device's own* position. `networkSighting` does not — its coordinate belongs to whichever
/// stranger's phone sighted the beacon. Mapping such a value onto `live` would therefore draw
/// someone else's location on a family member's pin, so sightings are persisted (the `source`
/// column keeps them queryable) but never move the pin, rename the place, or raise alerts.
/// Unrecognised values are dropped rather than guessed. See `LocationSource.decode`.
enum LocationSource: String, Codable, Hashable {
    case live = "LIVE"
    case shutdown = "SHUTDOWN"
    case batteryLow = "BATTERY_LOW"
    /// A crowd finder's proxy report: the coordinate is where the finder was standing, not
    /// where the device is. Stored, never mapped. Mirrors Android `NETWORK_SIGHTING`.
    case networkSighting = "NETWORK_SIGHTING"

    /// Decode-only. Never sent, never displayed — a value from a peer newer than this build,
    /// whose meaning we cannot know.
    case unknown = "__UNKNOWN__"

    /// Absent on the wire means a peer predating the field, which only ever sent live reports.
    /// Present but unrecognised means a peer newer than us.
    static func decode(_ raw: String?) -> LocationSource {
        guard let raw else { return .live }
        return LocationSource(rawValue: raw) ?? .unknown
    }
}

struct LocationValue: Identifiable, Codable, Hashable, Equatable {
    var id: Int64
    var userid: Int64
    var coord: Coord
    /// Meters per second.
    var speed: Float
    /// Horizontal accuracy in meters.
    var acc: Float
    var timestamp: Date
    /// 0–100.
    var battery: Float
    /// When the report was SENT, as opposed to when the fix was MEASURED (`timestamp`).
    ///
    /// These differ for a shutdown report, which deliberately carries a stale fix. Recency must
    /// be judged on this, not on `timestamp` — ranking a shutdown report by its measurement time
    /// makes it lose to the live heartbeat that preceded it, so it is stored and then never
    /// shown. Peers predating the field fall back to `timestamp`.
    ///
    /// Deliberately has no default: every construction site should decide, because getting it
    /// wrong is silent.
    var reportedAt: Date
    var source: LocationSource

    /// Convert to wire form. ULong on the wire, epoch-millis timestamp.
    func toCompatible(sleep: Bool? = nil, senderPlatform: String? = nil, pairId: String? = nil) -> LocationValueCompatible {
        LocationValueCompatible(
            id: UInt64(bitPattern: id),
            userid: UInt64(bitPattern: userid),
            coord: coord,
            speed: speed,
            acc: acc,
            timestamp: Int64((timestamp.timeIntervalSince1970 * 1000).rounded()),
            battery: battery,
            sleep: sleep,
            senderPlatform: senderPlatform,
            pairId: pairId
        )
    }
}

/// JSON wire format for /api/location/* (mirrors `LocationValueCompatible` in Modern-Apps).
/// The Modern-Apps Kotlin model has a NESTED `coord` object (the Room `@Embedded` flattens
/// to DB columns, but kotlinx.serialization keeps the field nested in JSON).
///
/// `id` and `sleep` are optional here because kotlinx.serialization's default
/// `encodeDefaults = false` omits fields that equal their declared default value
/// (`id = 0uL`, `sleep = null`), so the inbound JSON may not include them.
struct LocationValueCompatible: Codable {
    var id: UInt64?
    var userid: UInt64
    var coord: Coord
    var speed: Float
    var acc: Float
    var timestamp: Int64  // epoch millis
    var battery: Float
    var sleep: Bool?
    /// Sender's platform tag (`"android"` or `"ios"`). Optional for backward compatibility.
    var senderPlatform: String?
    /// Hidden sender-auth secret (GHSA-x94x-v6f7-wwpp): the sender's outbound pair ID for
    /// the recipient. Base64url unpadded, ~22 chars. Nil = peer predates sender auth.
    /// Same JSON key `pairId` as Android. Unknown keys are ignored on decode, so old
    /// builds interoperate.
    var pairId: String? = nil
    /// `LocationValue.reportedAt` in epoch milliseconds. Absent from peers predating it, in
    /// which case it falls back to `timestamp` — an older peer only ever sent live reports.
    ///
    /// iOS does not currently SEND this: it only ever produces live reports, and absent already
    /// means live. Left nil rather than populated to keep the outbound payload byte-identical
    /// to what older Android peers already parse.
    var reportedAt: Int64? = nil
    /// `LocationSource` by name. A plain string rather than the enum so a value this build has
    /// never heard of degrades to `.unknown` instead of failing the whole decode — Android and
    /// older iOS peers have to keep interoperating. Absent entirely means the peer predates the
    /// field, which is `.live`. Not sent by iOS, for the same reason as `reportedAt`.
    var source: String? = nil

    func toLocationValue() -> LocationValue {
        let measured = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return LocationValue(
            id: Int64(bitPattern: id ?? 0),
            userid: Int64(bitPattern: userid),
            coord: coord,
            speed: speed,
            acc: acc,
            timestamp: measured,
            battery: battery,
            reportedAt: reportedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
                ?? measured,
            source: LocationSource.decode(source)
        )
    }
}

// MARK: - TemporaryLink

struct TemporaryLink: Identifiable, Codable, Hashable, Equatable {
    var id: Int64
    var name: String
    /// Base64(PEM) RSA private key — embedded in the share URL fragment, never sent to the server.
    var key: String
    /// Base64(PEM) RSA public key — registered for the link's id and used by senders.
    var publicKey: String
    var deleteAt: Date
    /// PQC ephemeral public bundle (base64 [4B kemLen][kemPub][dsaPub]), nullable for migration.
    var pqcPublicKey: String? = nil
    /// Legacy: the full PQC private bundle (base64 [4B kemPrivLen][kemPriv][dsaPriv]) that older
    /// builds put in the fragment as `#pqc_key=`. Only set on links created before [pqcSeed].
    var pqcKey: String? = nil
    /// The 32-byte ML-KEM link seed (base64url, unpadded) — what goes in the fragment as `#s=`.
    /// This is the link's entire secret; the recipient's browser expands it into the keypair.
    var pqcSeed: String? = nil
}

// MARK: - NoShowAlert

/// A watch for an expected arrival that never happened. Mirrors Android `data/NoShowAlert.kt`.
///
/// The scheduler (`NoShowScheduler.sweepDueNow`, run from every `runTick`) asks for rows whose
/// deadline — `expectedAt` plus `grace` — has passed without the watched user appearing, then
/// notifies and marks them fired. Time storage mirrors Android: `expectedAt` as epoch seconds,
/// `grace` as whole milliseconds, booleans as 0/1 integers.
struct NoShowAlert: Identifiable, Codable, Hashable, Equatable {
    var id: Int64
    /// Row id of the watched `User`.
    var watchedUserId: Int64
    /// Waypoint the user was expected at. Null means any fresh, accurate fix counts as arrival.
    var waypointId: Int64?
    /// When the user was expected.
    var expectedAt: Date
    /// Extra wait after `expectedAt` before the alert becomes due.
    var grace: TimeInterval
    /// Whether this alert has already fired. Set atomically via `markFired`.
    var fired: Bool = false
    /// When true the row is deleted after firing; when false it stays and can be re-armed.
    var oneShot: Bool = true
}
