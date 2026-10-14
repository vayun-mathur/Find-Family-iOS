import Foundation

enum NetworkError: Error {
    case badStatus(Int)
    case badBody
}

/// Thin URLSession wrapper for JSON POST endpoints.
///
/// Main-actor bound: `URLSession` itself is thread-safe, but `reset()` replaces the
/// session object, so all access is serialized here (Swift 6 region-isolation
/// requirement — `Networking` only ever touches it from the main actor anyway).
@MainActor
final class NetworkClient {
    let baseURL = URL(string: "https://findfamily.cc")!
    private var session: URLSession
    init() {
        self.session = Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }

    /// Drops the current session and builds a fresh one with the same config.
    /// The liveness tripwire calls this - the HTTP equivalent of Android tearing
    /// down and re-establishing the socket. Note: invalidates in-flight tasks.
    func reset() {
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    func postJSON(path: String, jsonBody: Data) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonBody
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw NetworkError.badBody }
        return (data, http)
    }
}

// MARK: - Networking singleton

/// Mirrors `Networking.kt` from Modern-Apps. Owns identity (userid, RSA + PQC key pairs),
/// registration with the server, and the encrypted publish/receive flows.
///
/// PQC support mirrors Office's Android `PqcIdentity.loadOrCreate` system:
///   - Device PQC identity uses `PQCKeyManager` which stores `ff_pqcKemPub/Priv`, `ff_pqcDsaPub/Priv`
///     (same as Android's `ff_pqc` prefix) in Keychain, with bundle format [4B kemLen][kemPub][dsaPub]
///     and sealed layout [4B encapLen][encap][aes] (aes = [12B iv][ct||tag]), KDF SHA256(BE32(1)||Z).
///   - Server parallel endpoints `/api/pqc/*` store PQC bundles separately from RSA.
///
/// This app is **post-quantum only**: it publishes to and receives from the `_pqc` endpoints
/// exclusively and never touches the classic RSA location/UWB queues, and it registers only a
/// PQC bundle. Android keeps its classic fallback for other peers, but it always prefers PQC
/// when the peer has a bundle registered — which this app does on every launch.
@MainActor
final class Networking: ObservableObject {
    static let shared = Networking()

    private let client = NetworkClient()
    private(set) var userid: Int64 = 0
    // PQC identity — mirrors Office/FF Android ff_pqc prefix. FindFamily is post-quantum only.
    private var pqcPublicBundleB64: String = ""
    private var pqcIdentity: PQCIdentity?
    var pqcAvailable: Bool { pqcIdentity != nil }

    private var networkIsDown = false
    // MARK: - Retry backoff + liveness tripwire

    /// Mirrors Android's socket loop (`Networking.kt`): reconnects with 1s→15s
    /// doubling backoff and treats no-inbound-for-75s as half-open death
    /// (`NetworkingLive.kt` superviseConnection). iOS polls over stateless HTTP
    /// every 3s (`BackgroundTask`), so the equivalents live here: every transport
    /// error sleeps with doubling backoff (so a 3s tick loop can't hammer a dead
    /// server), and no successful round-trip for ~75s resets the shared session.
    private static let backoffInitial: TimeInterval = 1.0
    private static let backoffMax: TimeInterval = 15.0
    private static let livenessTimeout: TimeInterval = 75.0

    private var consecutiveFailures = 0
    // Explicit `Networking.` (not `Self.`): covariant Self cannot be referenced from
    // a stored-property initializer, even in a final class (Swift 6 enforces this).
    private var currentBackoff: TimeInterval = Networking.backoffInitial
    /// Last completed HTTP round-trip (any status - a response proves liveness).
    /// Starts at launch so a server dead from boot still trips the wire at ~75s.
    private var lastSuccessAt = Date()

    /// Local platform tag included in outgoing heartbeat payloads so peers learn we're on iOS.
    static let platformTag = "ios"

    @Published private(set) var isReady = false

    private init() {}

    func start() async {
        // Stable identity: only generate userid on first launch.
        if let stored = Keychain.getInt64(key: "userid"), stored != 0 {
            userid = stored
        } else {
            userid = Int64.random(in: Int64.min...Int64.max)
            Keychain.setInt64(userid, key: "userid")
        }

        // PQC identity — post-quantum only. If the Rust XCFramework isn't linked this throws and
        // pqcAvailable stays false; the app cannot share until the native lib is present. There is
        // deliberately no RSA fallback.
        do {
            let id = try PQCKeyManager.shared.identity()
            pqcIdentity = id
            pqcPublicBundleB64 = id.publicBundle.base64EncodedString()
            print("Networking: PQC identity ready bundleLen=\(id.publicBundle.count)")
        } catch {
            print("Networking: PQC unavailable (native not linked?): \(error.localizedDescription)")
            pqcIdentity = nil
            pqcPublicBundleB64 = ""
        }

        isReady = true
        ensureMeUserExists()
        // Apply any auto-toggle timers that fell due while the app was not running
        // (mirrors Android's cold-start applyDueAutoToggles in the ViewModel init).
        Database.shared.applyDueAutoToggles(now: Date())
        _ = await ensureUserExists()
    }

    /// Ensure there's a "Me" entry in the users table representing the device owner.
    /// id matches `userid` so the rest of the UI can identify it and so incoming
    /// LocationValues stored for our own id stitch together correctly.
    private func ensureMeUserExists() {
        if Database.shared.user(id: userid) == nil {
            let me = User(
                id: userid,
                name: "Me",
                photo: nil,
                locationName: "Unnamed Location",
                sendingEnabled: false,
                requestStatus: .mutualConnection,
                lastLocationChangeTime: Date(),
                encryptionKey: nil,
                pqcEncryptionKey: nil
            )
            Database.shared.upsertUser(me)
        }
    }

    // MARK: - Endpoints

    func registerPqc() async -> Bool {
        guard !pqcPublicBundleB64.isEmpty else { return false }
        let body = encodeJSON([
            "userid": .uint64(UInt64(bitPattern: userid)),
            "key": .string(pqcPublicBundleB64),
        ])
        let ok = await postBool("/api/pqc/register", body: body)
        print("Networking: registerPqc userid=\(UInt64(bitPattern: userid)) ok=\(ok) bundleLen=\(pqcIdentity?.publicBundle.count ?? -1)")
        return ok
    }

    func ensureUserExists() async -> Bool {
        // PQC-only: register/self-heal the post-quantum bundle. Without PQC there is nothing to
        // register and the app cannot share until the native lib is present.
        guard pqcAvailable else { return false }
        if let serverBundle = await getPqcKeyRaw(forUserid: userid) {
            if serverBundle.base64EncodedString() != pqcPublicBundleB64 {
                print("Networking: server PQC bundle mismatch for self, re-registering")
                return await registerPqc()
            }
            return true
        }
        return await registerPqc()
    }

    /// Post-quantum capability of a peer, used to gate connecting/sharing.
    enum PeerCrypto {
        case pqc          // peer has a PQC bundle — sharing works
        case needsUpdate  // peer has only a classic key — outdated app, must update
        case unknown      // not registered, or the lookup failed (offline)
        case keyMismatch  // the relay's bundle doesn't match the invite link's fingerprint
    }

    /// Outcome of the connect-time key check. `verifiedBundleB64` is set only when an
    /// invite fingerprint was supplied and matched, and is meant to go straight onto the
    /// `User` row being created — pinning the key that was checked, so `resolvedPqcBundle`
    /// prefers it and a later lookup can't swap in one the fingerprint never covered.
    struct PeerKeyCheck {
        let status: PeerCrypto
        let verifiedBundleB64: String?
    }

    /// Checks a peer's PQC capability "when connecting", over the relay socket. A PQC
    /// bundle → `.pqc`; only a classic key → `.needsUpdate` (show the update prompt);
    /// neither, or the lookup failed → `.unknown`.
    ///
    /// `expectedFingerprint` is the `k=` value of the invite link this came from, when
    /// there was one. The relay's bundle has to hash to it, or the result is
    /// `.keyMismatch` — this is what stops the relay handing out a key it controls
    /// instead of the sender's.
    func peerCryptoStatus(forUserid id: Int64, expectedFingerprint: String? = nil) async -> PeerKeyCheck {
        guard let res = await RelayKeyLookup.getKey(userId: id) else {
            return PeerKeyCheck(status: .unknown, verifiedBundleB64: nil)
        }
        switch res.status {
        case .pqc:
            guard let expected = expectedFingerprint else {
                return PeerKeyCheck(status: .pqc, verifiedBundleB64: nil)
            }
            guard let bundle = res.bundle, !bundle.isEmpty else {
                return PeerKeyCheck(status: .unknown, verifiedBundleB64: nil)
            }
            guard InviteFingerprint.matches(userId: id, publicBundle: bundle, expected: expected) else {
                print("Networking: invite fingerprint mismatch for \(UInt64(bitPattern: id))")
                return PeerKeyCheck(status: .keyMismatch, verifiedBundleB64: nil)
            }
            return PeerKeyCheck(status: .pqc, verifiedBundleB64: bundle.base64EncodedString())
        case .classic:
            return PeerKeyCheck(status: .needsUpdate, verifiedBundleB64: nil)
        case .noKey:
            return PeerKeyCheck(status: .unknown, verifiedBundleB64: nil)
        }
    }

    /// The invite link to share: the https bounce page, which many messaging apps will
    /// linkify where a bare `findfamily://` URI is left as plain text. Both values ride in
    /// the fragment, which browsers never send, so the server sees only that some share
    /// page was opened. `k` is a 22-character hash of our public bundle, not the bundle
    /// itself (~4 kB base64) — the recipient fetches the key from the relay and checks it
    /// against this. Omitted when PQC is unavailable, leaving the id-only link.
    func inviteLink() -> String {
        let base = "https://ma.vayunmathur.com/ff/share#id=\(Base26.encode(userid))"
        guard let bundle = pqcIdentity?.publicBundle else { return base }
        return base + "&k=" + InviteFingerprint.encode(userId: userid, publicBundle: bundle)
    }

    /// Computes the quantum-safe verification "security code" (safety number) for a connection:
    /// a fingerprint of both this device's and [user]'s PQC bundles, identical on both peers.
    /// Returns nil if PQC is unavailable locally or the peer has no PQC bundle. The heavy
    /// SHA-256 ×4000 runs off the main actor.
    func securityCode(for user: User) async -> String? {
        guard pqcAvailable, let myBundle = pqcIdentity?.publicBundle,
              let peerBundle = await resolvedPqcBundle(for: user) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            PQCSecurityCode.compute(myBundle: myBundle, theirBundle: peerBundle)
        }.value
    }

    /// Raw PQC bundle Data fetch (base64 decoded), for registration self-heal check.
    func getPqcKeyRaw(forUserid id: Int64) async -> Data? {
        guard pqcAvailable else { return nil }
        let body = Data(#"{"userid": \#(UInt64(bitPattern: id))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/pqc/getkey", jsonBody: body)
            noteSuccess()
            guard http.statusCode == 200 else { return nil }
            guard let b64 = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                  let bundleData = Data(base64Encoded: b64),
                  !bundleData.isEmpty
                else { return nil }
            return bundleData
        } catch {
            await noteTransportFailure(error)
            return nil
        }
    }

    /// Fetches peer PQC bundle, caches to DB, returns Data.
    func getPqcBundle(forUserid id: Int64) async -> Data? {
        guard pqcAvailable else { return nil }
        if let data = await getPqcKeyRaw(forUserid: id) {
            // Overwrite rather than fill-only-if-empty, matching Android: this is only
            // reached when there was no cached bundle to prefer, and a stale value here
            // would keep us encrypting to a key the peer has already replaced. Written on
            // its own so the other columns (sharingAutoToggleAt etc.) aren't clobbered.
            if Database.shared.user(id: id) != nil {
                Database.shared.setPqcEncryptionKey(id: id, pqcEncryptionKey: data.base64EncodedString())
            }
            return data
        }
        return nil
    }

    // MARK: - Publish Location (post-quantum only)

    func publishLocation(_ location: LocationValue, toUser user: User) async -> Bool {
        guard let bundle = await resolvedPqcBundle(for: user) else {
            print("Networking: publishLocation no PQC bundle for \(UInt64(bitPattern: user.id)); peer must update")
            return false
        }
        // Hidden sender auth (GHSA-x94x-v6f7-wwpp): our outbound pair-ID secret for this
        // peer, created once and never rotated (the peer pins the first value it sees).
        let pairId = outboundPairId(for: user)
        return await publishEncryptedPqc(location: location, recipientID: user.id, bundle: bundle, pairId: pairId) ?? false
    }

    /// Our outbound pair-ID secret for `user`. Uses the conditional write so two
    /// concurrent ticks cannot mint different values - the loser re-reads the winner.
    private func outboundPairId(for user: User) -> String {
        if let existing = user.outboundPairId, !existing.isEmpty { return existing }
        let fresh = PairAuth.generatePairId()
        Database.shared.setOutboundPairIdIfAbsent(id: user.id, pairId: fresh)
        return Database.shared.user(id: user.id)?.outboundPairId ?? fresh
    }

    private func resolvedPqcBundle(for user: User) async -> Data? {
        guard pqcAvailable else { return nil }
        if let b64 = user.pqcEncryptionKey, let data = Data(base64Encoded: b64), !data.isEmpty {
            return data
        }
        // Opportunistic fetch from server.
        if let data = await getPqcBundle(forUserid: user.id) {
            return data
        }
        return nil
    }

    func publishLocation(_ location: LocationValue, toLink link: TemporaryLink) async -> Bool {
        guard pqcAvailable, let b64 = link.pqcPublicKey, let bundle = Data(base64Encoded: b64), !bundle.isEmpty else {
            return false
        }
        // Anonymous link viewers prove nothing about identity and expect no auth.
        return await publishEncryptedPqc(location: location, recipientID: link.id, bundle: bundle, pairId: nil) ?? false
    }

    private func publishEncryptedPqc(location: LocationValue, recipientID: Int64, bundle: Data, pairId: String?) async -> Bool? {
        guard pqcAvailable else { return nil }
        do {
            let json = try JSONEncoder().encode(location.toCompatible(senderPlatform: Self.platformTag, pairId: pairId))
            // Encrypt via PQC (ML-KEM encaps + AES-GCM), same as Kotlin Pqc.encryptTo
            let sealed = try PQCKeyManager.shared.encryptTo(bundle: bundle, plaintext: json)
            let body = encodeJSON([
                "recipientUserID": .uint64(UInt64(bitPattern: recipientID)),
                "encryptedLocation": .string(sealed.base64EncodedString()),
            ])
            let ok = await postBool("/api/location/publish_pqc", body: body)
            print("publishEncryptedPqc to \(UInt64(bitPattern: recipientID)) ok=\(ok) encLen=\(sealed.count)")
            return ok
        } catch {
            print("publishEncryptedPqc error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Receive (post-quantum only)

    /// Drains the post-quantum queue. The classic RSA queue is deliberately not read:
    /// this app publishes and receives post-quantum only, so anything sitting in the
    /// classic queue was sent by a peer that hasn't picked up our PQC key yet.
    func receiveLocations() async -> [(LocationValue, String?)]? {
        return await receiveLocationsPqc()
    }

    private func receiveLocationsPqc() async -> [(LocationValue, String?)]? {
        guard pqcAvailable, (try? PQCKeyManager.shared.identity()) != nil else { return [] }
        let body = Data(#"{"userid": \#(UInt64(bitPattern: userid))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/location/receive_pqc", jsonBody: body)
            noteSuccess()
            if http.statusCode == 204 || data.isEmpty { return [] }
            guard http.statusCode == 200 else {
                print("receiveLocationsPqc: HTTP \(http.statusCode)")
                return nil
            }
            let arr = try JSONDecoder().decode([String].self, from: data)
            // Each element pairs the fix with its claimed pair ID (GHSA-x94x-v6f7-wwpp).
            // Callers must authenticate before storing - see BackgroundTask.runTick.
            var out: [(LocationValue, String?)] = []
            for b64 in arr {
                guard let sealed = Data(base64Encoded: b64) else {
                    print("receiveLocationsPqc: skipped non-base64")
                    continue
                }
                do {
                    let plain = try PQCKeyManager.shared.decrypt(sealed: sealed)
                    let comp = try JSONDecoder().decode(LocationValueCompatible.self, from: plain)
                    let loc = comp.toLocationValue()
                    // Fail closed on a source this build does not know. `live`, `shutdown` and
                    // `batteryLow` all mean "the tracked device's own position"; a newer peer's
                    // category might not - a network sighting carries the FINDER's coordinate.
                    // Rendering that as a family member's position would send someone to the
                    // wrong place, so an uninterpretable report is dropped rather than guessed.
                    guard loc.source != .unknown else {
                        print("receiveLocationsPqc: dropped report with unknown source '\(comp.source ?? "")'")
                        continue
                    }
                    out.append((loc, comp.pairId))
                    if let platform = comp.senderPlatform,
                       let u = Database.shared.user(id: loc.userid),
                       u.platform != platform {
                        Database.shared.setPlatform(id: loc.userid, platform: platform)
                    }
                } catch {
                    print("receiveLocationsPqc: decrypt/parse failure: \(error.localizedDescription)")
                }
            }
            print("receiveLocationsPqc: \(out.count) location(s) for userid=\(UInt64(bitPattern: userid))")
            return out
        } catch {
            await noteTransportFailure(error)
            return nil
        }
    }

    func problem(_ message: String) async {
        let body = encodeJSON(["problem": .string(message)])
        _ = await postBool("/api/problem", body: body)
    }

    // MARK: - UWB session-setup channel (post-quantum only)

    /// Publishes [envelope] to [recipientID] via the peer's PQC bundle. Returns false if the peer
    /// has no PQC bundle (they are on an outdated app).
    func publishUwbMessage(_ envelope: UwbEnvelope, to recipientID: Int64) async -> Bool {
        guard pqcAvailable else { return false }
        var pqcBundle: Data? = nil
        if let user = Database.shared.user(id: recipientID),
           let b64 = user.pqcEncryptionKey,
           let data = Data(base64Encoded: b64), !data.isEmpty {
            pqcBundle = data
        } else if let data = await getPqcBundle(forUserid: recipientID) {
            pqcBundle = data
        }
        guard let bundle = pqcBundle else {
            print("publishUwbMessage: no PQC bundle for \(UInt64(bitPattern: recipientID)); peer must update")
            return false
        }
        return await publishUwbMessagePqc(envelope, to: recipientID, bundle: bundle) ?? false
    }

    private func publishUwbMessagePqc(_ envelope: UwbEnvelope, to recipientID: Int64, bundle: Data) async -> Bool? {
        guard pqcAvailable else { return nil }
        do {
            let json = try JSONEncoder().encode(envelope)
            let sealed = try PQCKeyManager.shared.encryptTo(bundle: bundle, plaintext: json)
            let body = encodeJSON([
                "recipientUserID": .uint64(UInt64(bitPattern: recipientID)),
                "encryptedLocation": .string(sealed.base64EncodedString()),
            ])
            let ok = await postBool("/api/uwb/publish_pqc", body: body)
            print("publishUwbMessagePqc to \(UInt64(bitPattern: recipientID)) ok=\(ok)")
            return ok
        } catch {
            print("publishUwbMessagePqc encrypt error: \(error)")
            return nil
        }
    }

    /// Drains incoming UWB envelopes from the PQC queue (post-quantum only).
    func receiveUwbMessages() async -> [UwbEnvelope]? {
        return await receiveUwbMessagesPqc()
    }

    private func receiveUwbMessagesPqc() async -> [UwbEnvelope]? {
        guard pqcAvailable, (try? PQCKeyManager.shared.identity()) != nil else { return [] }
        let body = Data(#"{"userid": \#(UInt64(bitPattern: userid))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/uwb/receive_pqc", jsonBody: body)
            noteSuccess()
            if http.statusCode == 204 || data.isEmpty { return [] }
            guard http.statusCode == 200 else { return nil }
            let arr = try JSONDecoder().decode([String].self, from: data)
            var out: [UwbEnvelope] = []
            for b64 in arr {
                guard let sealed = Data(base64Encoded: b64) else { continue }
                if let plain = try? PQCKeyManager.shared.decrypt(sealed: sealed),
                   let env = try? JSONDecoder().decode(UwbEnvelope.self, from: plain) {
                    out.append(env)
                }
            }
            return out
        } catch {
            await noteTransportFailure(error)
            return nil
        }
    }

    // MARK: - Helpers

    private func postBool(_ path: String, body: Data) async -> Bool {
        do {
            let (_, http) = try await client.postJSON(path: path, jsonBody: body)
            noteSuccess()
            // Server returns 200 *or* 204 No Content on success for register/publish/problem.
            return (200..<300).contains(http.statusCode)
        } catch {
            await noteTransportFailure(error)
            return false
        }
    }

    /// A completed round-trip resets the failure streak: transport works, so any
    /// wedged-poll suspicion is cleared. Called for any HTTP status - even a 500
    /// proves the server is reachable. Failure semantics are unchanged: callers
    /// still map non-2xx / empty / error to false / [] / nil as before.
    private func noteSuccess() {
        consecutiveFailures = 0
        currentBackoff = Self.backoffInitial
        lastSuccessAt = Date()
        networkIsDown = false
    }

    /// A transport error (thrown by URLSession - timeout, DNS, refused, TLS): log
    /// once while down, then sleep with 1s→15s doubling backoff so the 3s tick
    /// loop doesn't hammer a dead server. Transport-error vs empty stays
    /// distinct - callers still return nil/false (error) vs [] (empty) as before.
    private func noteTransportFailure(_ error: Error) async {
        if !networkIsDown {
            print("network error: \(error.localizedDescription)")
        }
        networkIsDown = true
        consecutiveFailures += 1
        checkLivenessTripwire()
        let nap = currentBackoff
        currentBackoff = min(currentBackoff * 2, Self.backoffMax)
        print("Networking: backing off \(nap)s after \(consecutiveFailures) consecutive failure(s)")
        try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
    }

    /// Half-open detector (equivalent of Android's reconnect): if no successful
    /// round-trip for ~75s the poll loop is wedged - reset the shared session
    /// and log loudly. Re-arms for another window so a truly dead server trips
    /// at most once per 75s; the backoff counter is left intact.
    private func checkLivenessTripwire() {
        let idle = Date().timeIntervalSince(lastSuccessAt)
        guard idle >= Self.livenessTimeout else { return }
        print("Networking: LIVENESS TRIPWIRE - no successful round-trip for \(Int(idle))s " +
            "(\(consecutiveFailures) consecutive failures); resetting URLSession")
        client.reset()
        lastSuccessAt = Date()
    }
}

// MARK: - Minimal JSON encoder that preserves UInt64 unquoted

/// We need numeric values for `userid` etc. to remain unquoted JSON numbers, even when they
/// exceed `Int64.max` (since the Android side encodes them as `ULong`). JSONEncoder handles
/// `UInt64` as a number for values that fit, so this is a simple wrapper that keeps the
/// per-key types explicit.
private enum JSONValue {
    case string(String)
    case uint64(UInt64)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
}

private func encodeJSON(_ dict: [String: JSONValue]) -> Data {
    var parts: [String] = []
    // Preserve insertion order by iterating over keys array — Swift dictionary literals
    // don't preserve order, but the server is fine with any ordering.
    for (k, v) in dict {
        parts.append("\(quote(k)):\(serialize(v))")
    }
    return Data("{\(parts.joined(separator: ","))}".utf8)
}

private func serialize(_ value: JSONValue) -> String {
    switch value {
    case .string(let s): return quote(s)
    case .uint64(let n): return String(n)
    case .int64(let n): return String(n)
    case .double(let d): return String(d)
    case .bool(let b): return b ? "true" : "false"
    }
}

private func quote(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    out += "\""
    return out
}
