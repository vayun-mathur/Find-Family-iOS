import Foundation

enum NetworkError: Error {
    case badStatus(Int)
    case badBody
}

/// Thin URLSession wrapper for JSON POST endpoints.
final class NetworkClient {
    let baseURL = URL(string: "https://findfamily.cc")!
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: cfg)
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
///   - Server parallel endpoints `/api/pqc/*` store PQC bundles separately from RSA; publish/receive
///     have `_pqc` variants. If peer has PQC key, publish ONLY to PQC endpoint (higher tier).
///   - Receive drains both classic and PQC queues for backward compat during rollout.
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

    /// Whether the server holds a *classic* (RSA) key for [id]. Used only to detect peers on an
    /// outdated, pre-quantum app — FindFamily never encrypts with RSA anymore.
    func hasClassicKey(forUserid id: Int64) async -> Bool {
        let body = Data(#"{"userid": \#(UInt64(bitPattern: id))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/getkey", jsonBody: body)
            networkIsDown = false
            return http.statusCode == 200 && !data.isEmpty
        } catch {
            checkNetworkDown(error)
            return false
        }
    }

    /// Whether the server holds a *PQC* bundle for [id] (independent of this device's PQC
    /// availability, unlike [getPqcKeyRaw]). Used for peer-capability detection.
    private func serverHasPqcKey(forUserid id: Int64) async -> Bool {
        let body = Data(#"{"userid": \#(UInt64(bitPattern: id))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/pqc/getkey", jsonBody: body)
            networkIsDown = false
            return http.statusCode == 200 && !data.isEmpty
        } catch {
            checkNetworkDown(error)
            return false
        }
    }

    /// Post-quantum capability of a peer, used to gate connecting/sharing.
    enum PeerCrypto {
        case pqc          // peer has a PQC bundle — sharing works
        case needsUpdate  // peer has only a classic key — outdated app, must update
        case unknown      // not registered, or the lookup failed (offline)
    }

    /// Checks a peer's PQC capability "when connecting": a PQC bundle present → `.pqc`; only a
    /// classic key → `.needsUpdate` (show the update prompt); neither → `.unknown`.
    func peerCryptoStatus(forUserid id: Int64) async -> PeerCrypto {
        if await serverHasPqcKey(forUserid: id) { return .pqc }
        return await hasClassicKey(forUserid: id) ? .needsUpdate : .unknown
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
            networkIsDown = false
            guard http.statusCode == 200 else { return nil }
            guard let b64 = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                  let bundleData = Data(base64Encoded: b64),
                  !bundleData.isEmpty
                else { return nil }
            return bundleData
        } catch {
            checkNetworkDown(error)
            return nil
        }
    }

    /// Fetches peer PQC bundle, caches to DB, returns Data.
    func getPqcBundle(forUserid id: Int64) async -> Data? {
        guard pqcAvailable else { return nil }
        if let data = await getPqcKeyRaw(forUserid: id) {
            // Cache atomically so we don't clobber other columns (sharingAutoToggleAt etc.).
            if let u = Database.shared.user(id: id), u.pqcEncryptionKey == nil {
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
        return await publishEncryptedPqc(location: location, recipientID: user.id, bundle: bundle) ?? false
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
        return await publishEncryptedPqc(location: location, recipientID: link.id, bundle: bundle) ?? false
    }

    private func publishEncryptedPqc(location: LocationValue, recipientID: Int64, bundle: Data) async -> Bool? {
        guard pqcAvailable else { return nil }
        do {
            let json = try JSONEncoder().encode(location.toCompatible(senderPlatform: Self.platformTag))
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

    func receiveLocations() async -> [LocationValue]? {
        return await receiveLocationsPqc()
    }

    private func receiveLocationsPqc() async -> [LocationValue]? {
        guard pqcAvailable, (try? PQCKeyManager.shared.identity()) != nil else { return [] }
        let body = Data(#"{"userid": \#(UInt64(bitPattern: userid))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/location/receive_pqc", jsonBody: body)
            networkIsDown = false
            if http.statusCode == 204 || data.isEmpty { return [] }
            guard http.statusCode == 200 else {
                print("receiveLocationsPqc: HTTP \(http.statusCode)")
                return nil
            }
            let arr = try JSONDecoder().decode([String].self, from: data)
            var out: [LocationValue] = []
            for b64 in arr {
                guard let sealed = Data(base64Encoded: b64) else {
                    print("receiveLocationsPqc: skipped non-base64")
                    continue
                }
                do {
                    let plain = try PQCKeyManager.shared.decrypt(sealed: sealed)
                    let comp = try JSONDecoder().decode(LocationValueCompatible.self, from: plain)
                    let loc = comp.toLocationValue()
                    out.append(loc)
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
            checkNetworkDown(error)
            return nil
        }
    }

    func sendSharingRequest(to requestedID: Int64) async -> Bool {
        let body = encodeJSON([
            "requester": .uint64(UInt64(bitPattern: userid)),
            "requested": .uint64(UInt64(bitPattern: requestedID)),
        ])
        return await postBool("/api/request_sharing/send", body: body)
    }

    func retrieveSharingRequests() async -> [Int64] {
        let body = Data(#"{"requester": \#(UInt64(bitPattern: userid))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/request_sharing/retrieve", jsonBody: body)
            networkIsDown = false
            guard http.statusCode == 200 else { return [] }
            let arr = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            return arr.compactMap { UInt64($0).map { Int64(bitPattern: $0) } }
        } catch {
            checkNetworkDown(error)
            return []
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
            networkIsDown = false
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
            checkNetworkDown(error)
            return nil
        }
    }

    // MARK: - Helpers

    private func postBool(_ path: String, body: Data) async -> Bool {
        do {
            let (_, http) = try await client.postJSON(path: path, jsonBody: body)
            networkIsDown = false
            // Server returns 200 *or* 204 No Content on success for register/publish/problem.
            return (200..<300).contains(http.statusCode)
        } catch {
            checkNetworkDown(error)
            return false
        }
    }

    private func checkNetworkDown(_ error: Error) {
        if !networkIsDown {
            print("network error: \(error.localizedDescription)")
        }
        networkIsDown = true
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
