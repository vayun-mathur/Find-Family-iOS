import Foundation
import Security

// MARK: - PairAuth (hidden per-peer sender authentication, GHSA-x94x-v6f7-wwpp)
//
// Mirrors Android `domain/PairAuth.kt`. ML-KEM + AES-GCM encrypts *to* the recipient,
// proving nothing about who sent the plaintext — and the `userid` inside is
// self-declared. Instead of a 3,309-byte ML-DSA signature per message, each direction
// of each peer relationship holds a 128-bit secret ("pair ID") that is never
// user-visible and never leaves the ciphertext:
//   - `outboundPairId`: what this device puts in every packet it sends to a peer.
//   - `inboundPairId`: what this device expects from a peer; pinned trust-on-first-use.
//
// Both IDs are opaque strings (base64url, unpadded, 16 random bytes ≈ 22 chars).
// Directional so neither side transmits its expectation.

enum PairAuth {
    /// Random bytes per pair ID (128-bit).
    static let pairIdBytes = 16

    /// How far ahead of the receiver's clock a fix may claim before it is dropped.
    /// Kills the one-message future-pin amplifier (latest ranks on `reportedAt`).
    static let maxFutureSkewSeconds: TimeInterval = 5 * 60

    /// Result of checking one inbound packet's pair ID against the pinned expectation.
    enum InboundVerdict {
        /// No pin yet and packet carries an ID — caller should pin it, then accept.
        case acceptPin
        /// Pinned and matches — accept.
        case acceptMatch
        /// No pin and no ID (legacy peer) — accept without pinning.
        case acceptLegacy
        /// Pinned but packet carries a different ID — drop.
        case dropMismatch
        /// Pinned but packet carries none — drop.
        case dropMissing
    }

    /// Generates a fresh pair ID (16 random bytes, base64url unpadded).
    static func generatePairId() -> String {
        var bytes = [UInt8](repeating: 0, count: pairIdBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Pure check of an inbound `pairId` against the pinned `expected` (nil = unpinned).
    static func checkInbound(expected: String?, incoming: String?) -> InboundVerdict {
        guard let expected else {
            return incoming == nil ? .acceptLegacy : .acceptPin
        }
        guard let incoming else { return .dropMissing }
        return incoming == expected ? .acceptMatch : .dropMismatch
    }

    /// True when a fix claims a time more than `maxFutureSkewSeconds` ahead of `now`.
    /// Both `reportedAt` (send time) and `timestamp` (measure time) are sender-controlled.
    static func isFromTheFuture(reportedAt: Date, timestamp: Date, now: Date) -> Bool {
        reportedAt.timeIntervalSince(now) > maxFutureSkewSeconds ||
            timestamp.timeIntervalSince(now) > maxFutureSkewSeconds
    }

    /// Truncated pair ID for logs — the full value must never be logged.
    static func logPreview(_ pairId: String?) -> String {
        guard let pairId else { return "absent" }
        return "\(pairId.prefix(4))…"
    }
}
