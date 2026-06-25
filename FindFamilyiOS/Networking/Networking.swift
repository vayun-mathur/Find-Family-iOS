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

/// Mirrors `Networking.kt` from Modern-Apps. Owns identity (userid, RSA key pair),
/// registration with the server, and the encrypted publish/receive flows.
@MainActor
final class Networking: ObservableObject {
    static let shared = Networking()

    private let client = NetworkClient()
    private(set) var userid: Int64 = 0
    private var publicKey: SecKey?
    private var privateKey: SecKey?
    private var publicKeyPEMBase64: String = ""
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
            let (pri, pub) = try RSAKeyManager.shared.keyPair()
            privateKey = pri
            publicKey = pub
            let pem = try RSAPEM.publicKeyToPEM(pub)
            publicKeyPEMBase64 = Data(pem.utf8).base64EncodedString()
            isReady = true
            ensureMeUserExists()
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
                encryptionKey: nil
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

    func ensureUserExists() async -> Bool {
        if await getKey(forUserid: userid) == nil {
            return await register()
        }
        return true
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

    func publishLocation(_ location: LocationValue, toUser user: User) async -> Bool {
        let key: SecKey?
        if let encKeyB64 = user.encryptionKey,
           let pemData = Data(base64Encoded: encKeyB64),
           let pem = String(data: pemData, encoding: .utf8),
           let k = RSAPEM.publicKeyFromPEM(pem) {
            key = k
        } else if let k = await getKey(forUserid: user.id) {
            // Cache for next time.
            do {
                let pem = try RSAPEM.publicKeyToPEM(k)
                let b64 = Data(pem.utf8).base64EncodedString()
                var copy = user
                copy.encryptionKey = b64
                Database.shared.upsertUser(copy)
            } catch {}
            key = k
        } else {
            key = nil
        }
        guard let k = key else { return false }
        return await publishEncrypted(location: location, recipientID: user.id, key: k)
    }

    func publishLocation(_ location: LocationValue, toLink link: TemporaryLink) async -> Bool {
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

    func receiveLocations() async -> [LocationValue]? {
        guard let priv = privateKey else { return nil }
        let body = Data(#"{"userid": \#(UInt64(bitPattern: userid))}"#.utf8)
        do {
            let (data, http) = try await client.postJSON(path: "/api/location/receive", jsonBody: body)
            networkIsDown = false
            // 204 means "no incoming locations for this user" — treat as success-empty.
            if http.statusCode == 204 || data.isEmpty {
                return []
            }
            guard http.statusCode == 200 else {
                print("receiveLocations: HTTP \(http.statusCode)")
                return nil
            }
            let arr = try JSONDecoder().decode([String].self, from: data)
            var out: [LocationValue] = []
            for b64 in arr {
                guard let bytes = Data(base64Encoded: b64) else {
                    print("receiveLocations: skipped non-base64 entry")
                    continue
                }
                do {
                    let plain = try RSAKeyManager.shared.decryptOAEPSHA512(bytes, privateKey: priv)
                    let comp = try JSONDecoder().decode(LocationValueCompatible.self, from: plain)
                    let loc = comp.toLocationValue()
                    out.append(loc)
                    // Opportunistically capture peer platform tag from the encrypted payload.
                    if let platform = comp.senderPlatform,
                       var u = Database.shared.user(id: loc.userid),
                       u.platform != platform {
                        u.platform = platform
                        Database.shared.upsertUser(u)
                    }
                } catch {
                    print("receiveLocations: decrypt/parse failure: \(error.localizedDescription)")
                }
            }
            print("receiveLocations: \(out.count) location(s) for userid=\(UInt64(bitPattern: userid))")
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

    // MARK: - UWB session-setup channel
    //
    // Mirrors the location publish/receive flow but carries the small UWB
    // handshake envelopes (request / ack / config / cancel) end-to-end
    // encrypted. Each payload is at most a few hundred bytes; ranging samples
    // themselves never touch the server.

    /// Publishes [envelope] to [recipientID]. Resolves the recipient's public
    /// key from the cached `User.encryptionKey` first, then falls back to a
    /// `/api/getkey` lookup. Encrypts with RSA-OAEP/SHA-512.
    func publishUwbMessage(_ envelope: UwbEnvelope, to recipientID: Int64) async -> Bool {
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
            print("publishUwbMessage encrypt error: \(error)")
            return false
        }
    }

    /// Drains incoming UWB envelopes addressed to this user. The server queue
    /// is cleared on receive (same semantics as `/api/location/receive`).
    func receiveUwbMessages() async -> [UwbEnvelope]? {
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
