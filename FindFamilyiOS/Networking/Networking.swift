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
    // RSA
    private var publicKey: SecKey?
    private var privateKey: SecKey?
    private var publicKeyPEMBase64: String = ""
    // PQC — mirrors Office/FF Android ff_pqc prefix
    private var pqcPublicBundleB64: String = ""
    private var pqcIdentity: PQCIdentity?
    var pqcAvailable: Bool { pqcIdentity != nil }

    private var networkIsDown = false

    /// Local platform tag included in outgoing heartbeat payloads so peers learn we're on iOS.
    static let platformTag = "ios"

    @Published private(set) var isReady = false

    private init() {}

    func start() async {
        do {
            // Stable identity: only generate userid on first launch.
            if let stored = Keychain.getInt64(key: "userid"), stored != 0 {
                userid = stored
            } else {
                userid = Int64.random(in: Int64.min...Int64.max)
                Keychain.setInt64(userid, key: "userid")
            }
            // RSA
            let (pri, pub) = try RSAKeyManager.shared.keyPair()
            privateKey = pri
            publicKey = pub
            let pem = try RSAPEM.publicKeyToPEM(pub)
            publicKeyPEMBase64 = Data(pem.utf8).base64EncodedString()

            // PQC — best effort. If Rust XCFramework not linked, this throws and we stay RSA-only.
            // This mirrors Android's try/catch around PqcIdentity so legacy builds keep working.
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
        } catch {
            print("Networking.start error: \(error)")
        }
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

    func register() async -> Bool {
        guard !publicKeyPEMBase64.isEmpty else { return false }
        let body = encodeJSON([
            "userid": .uint64(UInt64(bitPattern: userid)),
            "key": .string(publicKeyPEMBase64),
        ])
        return await postBool("/api/register", body: body)
    }

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
        var ok = true
        // RSA self-heal: re-register if the server has no key OR a key that differs from ours.
        // A DataStore/Keychain race on first launch could have registered an ephemeral key, so
        // peers would encrypt to the wrong pubkey. Detect the mismatch by comparing the base64
        // of the server's returned public key against our own PEM.
        if let serverKey = await getKey(forUserid: userid) {
            if let serverPem = try? RSAPEM.publicKeyToPEM(serverKey) {
                let serverB64 = Data(serverPem.utf8).base64EncodedString()
                if serverB64 != publicKeyPEMBase64 {
                    print("Networking: server RSA key mismatch for self, re-registering")
                    ok = await register() && ok
                }
            }
        } else {
            ok = await register() && ok
        }
        // PQC self-healing: same missing-or-mismatched detection for the PQC bundle.
        if pqcAvailable {
            if let serverBundle = await getPqcKeyRaw(forUserid: userid) {
                if serverBundle.base64EncodedString() != pqcPublicBundleB64 {
                    print("Networking: server PQC bundle mismatch for self, re-registering")
                    ok = await registerPqc() && ok
                }
            } else {
                ok = await registerPqc() && ok
            }
        }
        return ok
    }

    /// GET-style lookup: server returns the raw base64-PEM string in the response body.
    func getKey(forUserid id: Int64) async -> SecKey? {
        let body = Data(#"{"userid": \#(UInt64(bitPattern: id))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/getkey", jsonBody: body)
            networkIsDown = false
            guard http.statusCode == 200 else { return nil }
            // The response body is a raw base64(PEM) string (no JSON wrapping).
            guard let pemB64 = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                else { return nil }
            guard let pemData = Data(base64Encoded: pemB64),
                  let pem = String(data: pemData, encoding: .utf8)
                else { return nil }
            return RSAPEM.publicKeyFromPEM(pem)
        } catch {
            checkNetworkDown(error)
            return nil
        }
    }

    /// Computes the RSA verification "security code" (safety number) for a connection: a
    /// fingerprint of both this device's and [user]'s public keys, identical on both peers.
    /// Comparing them out-of-band confirms no key was substituted. Returns nil if the peer's
    /// key isn't known yet. Uses RSA keys to match Android's current SecurityCodeDialog.
    func securityCode(for user: User) async -> String? {
        guard let selfPub = publicKey else { return nil }
        // Prefer the cached peer key; otherwise fetch and cache it atomically.
        var peerKey: SecKey?
        if let encKeyB64 = user.encryptionKey,
           let pemData = Data(base64Encoded: encKeyB64),
           let pem = String(data: pemData, encoding: .utf8) {
            peerKey = RSAPEM.publicKeyFromPEM(pem)
        }
        if peerKey == nil, let k = await getKey(forUserid: user.id) {
            if let pem = try? RSAPEM.publicKeyToPEM(k) {
                Database.shared.setEncryptionKey(id: user.id, encryptionKey: Data(pem.utf8).base64EncodedString())
            }
            peerKey = k
        }
        guard let peer = peerKey else { return nil }
        // Extract canonical DER on the main actor (cheap), then run the SHA-256 ×4000
        // iteration off the main actor — `Networking` is @MainActor, so a plain call would
        // otherwise block the UI. Only `Data` (Sendable) crosses the boundary.
        guard let myDer = RSASecurityCode.canonicalDER(selfPub),
              let theirDer = RSASecurityCode.canonicalDER(peer) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SecurityCodeFormat.compute(myDer, theirDer)
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

    // MARK: - Publish Location (PQC routing: if peer has PQC key, ONLY use PQC endpoint)

    func publishLocation(_ location: LocationValue, toUser user: User) async -> Bool {
        // PQC fast-path: if peer has bundle (cached or just fetched), publish only to PQC endpoint.
        if let bundle = await resolvedPqcBundle(for: user) {
            if let ok = await publishEncryptedPqc(location: location, recipientID: user.id, bundle: bundle) {
                return ok
            }
            // if PQC encrypt fails, fallback to RSA
            print("Networking: publishLocation PQC failed for \(UInt64(bitPattern: user.id)), falling back to RSA")
        }
        return await publishLocationClassic(location, toUser: user)
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

    private func publishLocationClassic(_ location: LocationValue, toUser user: User) async -> Bool {
        let key: SecKey?
        if let encKeyB64 = user.encryptionKey,
           let pemData = Data(base64Encoded: encKeyB64),
           let pem = String(data: pemData, encoding: .utf8),
           let k = RSAPEM.publicKeyFromPEM(pem) {
            key = k
        } else if let k = await getKey(forUserid: user.id) {
            if let pem = try? RSAPEM.publicKeyToPEM(k) {
                let b64 = Data(pem.utf8).base64EncodedString()
                Database.shared.setEncryptionKey(id: user.id, encryptionKey: b64)
            }
            key = k
        } else {
            key = nil
        }
        guard let k = key else { return false }
        return await publishEncrypted(location: location, recipientID: user.id, key: k)
    }

    func publishLocation(_ location: LocationValue, toLink link: TemporaryLink) async -> Bool {
        // TemporaryLink PQC routing: if link has PQC bundle, publish only to PQC endpoint.
        if pqcAvailable, let b64 = link.pqcPublicKey, let bundle = Data(base64Encoded: b64), !bundle.isEmpty {
            if let ok = await publishEncryptedPqc(location: location, recipientID: link.id, bundle: bundle) {
                return ok
            }
            // fallback to RSA
        }
        return await publishLocationClassic(location, toLink: link)
    }

    private func publishLocationClassic(_ location: LocationValue, toLink link: TemporaryLink) async -> Bool {
        guard let pemData = Data(base64Encoded: link.publicKey),
              let pem = String(data: pemData, encoding: .utf8),
              let key = RSAPEM.publicKeyFromPEM(pem)
        else { return false }
        return await publishEncrypted(location: location, recipientID: link.id, key: key)
    }

    private func publishEncrypted(location: LocationValue, recipientID: Int64, key: SecKey) async -> Bool {
        do {
            let json = try JSONEncoder().encode(location.toCompatible(senderPlatform: Self.platformTag))
            let cipher = try RSAKeyManager.shared.encryptOAEPSHA512(json, publicKey: key)
            let body = encodeJSON([
                "recipientUserID": .uint64(UInt64(bitPattern: recipientID)),
                "encryptedLocation": .string(cipher.base64EncodedString()),
            ])
            return await postBool("/api/location/publish", body: body)
        } catch {
            print("publishEncrypted error: \(error)")
            return false
        }
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

    // MARK: - Receive (drains both classic + PQC for backward compat)

    func receiveLocations() async -> [LocationValue]? {
        // Always try classic first; then PQC if available. Merge for fleet transition.
        let classic = await receiveLocationsClassic()
        let pqc = await receiveLocationsPqc()
        if classic == nil && pqc == nil { return nil }
        let merged = (classic ?? []) + (pqc ?? [])
        print("receiveLocations merged total=\(merged.count) classic=\(classic?.count ?? -1) pqc=\(pqc?.count ?? -1)")
        return merged
    }

    private func receiveLocationsClassic() async -> [LocationValue]? {
        guard let priv = privateKey else { return nil }
        let body = Data(#"{"userid": \#(UInt64(bitPattern: userid))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/location/receive", jsonBody: body)
            networkIsDown = false
            if http.statusCode == 204 || data.isEmpty { return [] }
            guard http.statusCode == 200 else {
                print("receiveLocationsClassic: HTTP \(http.statusCode)")
                return nil
            }
            let arr = try JSONDecoder().decode([String].self, from: data)
            var out: [LocationValue] = []
            for b64 in arr {
                guard let bytes = Data(base64Encoded: b64) else {
                    print("receiveLocationsClassic: skipped non-base64 entry")
                    continue
                }
                do {
                    let plain = try RSAKeyManager.shared.decryptOAEPSHA512(bytes, privateKey: priv)
                    let comp = try JSONDecoder().decode(LocationValueCompatible.self, from: plain)
                    let loc = comp.toLocationValue()
                    out.append(loc)
                    if let platform = comp.senderPlatform,
                       let u = Database.shared.user(id: loc.userid),
                       u.platform != platform {
                        Database.shared.setPlatform(id: loc.userid, platform: platform)
                    }
                } catch {
                    print("receiveLocationsClassic: decrypt/parse failure: \(error.localizedDescription)")
                }
            }
            print("receiveLocationsClassic: \(out.count) location(s) for userid=\(UInt64(bitPattern: userid))")
            return out
        } catch {
            checkNetworkDown(error)
            return nil
        }
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

    // MARK: - UWB session-setup channel (with PQC routing)

    /// Publishes [envelope] to [recipientID]. If peer has PQC bundle, publishes ONLY to PQC endpoint.
    func publishUwbMessage(_ envelope: UwbEnvelope, to recipientID: Int64) async -> Bool {
        // PQC fast-path
        if pqcAvailable {
            var pqcBundle: Data? = nil
            if let user = Database.shared.user(id: recipientID),
               let b64 = user.pqcEncryptionKey,
               let data = Data(base64Encoded: b64), !data.isEmpty {
                pqcBundle = data
            } else if let data = await getPqcBundle(forUserid: recipientID) {
                pqcBundle = data
            }
            if let bundle = pqcBundle {
                if let ok = await publishUwbMessagePqc(envelope, to: recipientID, bundle: bundle) {
                    return ok
                }
                print("publishUwbMessage PQC failed for \(UInt64(bitPattern: recipientID)), fallback RSA")
            }
        }
        // Classic fallback
        return await publishUwbMessageClassic(envelope, to: recipientID)
    }

    private func publishUwbMessageClassic(_ envelope: UwbEnvelope, to recipientID: Int64) async -> Bool {
        let key: SecKey?
        if let user = Database.shared.user(id: recipientID),
           let encKeyB64 = user.encryptionKey,
           let pemData = Data(base64Encoded: encKeyB64),
           let pem = String(data: pemData, encoding: .utf8),
           let k = RSAPEM.publicKeyFromPEM(pem) {
            key = k
        } else if let k = await getKey(forUserid: recipientID) {
            key = k
        } else {
            key = nil
        }
        guard let k = key else { return false }
        do {
            let json = try JSONEncoder().encode(envelope)
            let cipher = try RSAKeyManager.shared.encryptOAEPSHA512(json, publicKey: k)
            let body = encodeJSON([
                "recipientUserID": .uint64(UInt64(bitPattern: recipientID)),
                "encryptedLocation": .string(cipher.base64EncodedString()),
            ])
            return await postBool("/api/uwb/publish", body: body)
        } catch {
            print("publishUwbMessageClassic encrypt error: \(error)")
            return false
        }
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

    /// Drains incoming UWB envelopes from both classic and PQC queues (merged).
    func receiveUwbMessages() async -> [UwbEnvelope]? {
        let classic = await receiveUwbMessagesClassic()
        let pqc = await receiveUwbMessagesPqc()
        if classic == nil && pqc == nil { return nil }
        return (classic ?? []) + (pqc ?? [])
    }

    private func receiveUwbMessagesClassic() async -> [UwbEnvelope]? {
        guard let priv = privateKey else { return nil }
        let body = Data(#"{"userid": \#(UInt64(bitPattern: userid))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/uwb/receive", jsonBody: body)
            networkIsDown = false
            if http.statusCode == 204 || data.isEmpty { return [] }
            guard http.statusCode == 200 else { return nil }
            let arr = try JSONDecoder().decode([String].self, from: data)
            var out: [UwbEnvelope] = []
            for b64 in arr {
                guard let bytes = Data(base64Encoded: b64) else { continue }
                if let plain = try? RSAKeyManager.shared.decryptOAEPSHA512(bytes, privateKey: priv),
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
