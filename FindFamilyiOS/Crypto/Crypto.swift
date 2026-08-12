import Foundation
import Security
import CryptoKit

// MARK: - Keychain wrapper

enum Keychain {
    private static let service = "cc.findfamily.ios.swift"

    static func setData(_ data: Data, key: String) {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func getData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func setString(_ s: String, key: String) {
        setData(Data(s.utf8), key: key)
    }

    static func getString(key: String) -> String? {
        getData(key: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setInt64(_ v: Int64, key: String) {
        var x = v
        setData(Data(bytes: &x, count: 8), key: key)
    }

    static func getInt64(key: String) -> Int64? {
        guard let data = getData(key: key), data.count == 8 else { return nil }
        return data.withUnsafeBytes { $0.load(as: Int64.self) }
    }
}

// MARK: - Security code formatting (safety numbers)

/// Formats an iterated hash into a 6-group, 5-digit safety number, and runs the shared
/// canonical-order iterated-SHA256 computation. Identical to Kotlin `SecurityCode`.
/// Used by the post-quantum safety number (`PQCSecurityCode`).
enum SecurityCodeFormat {
    static let iterations = 4000

    /// SHA-256(a) and SHA-256(b) are combined in canonical (sorted) order, then hashed
    /// `iterations` times, then formatted. Both peers compute the same code regardless of role.
    static func compute(_ aDigestInput: Data, _ bDigestInput: Data) -> String {
        let a = sha256(aDigestInput)
        let b = sha256(bDigestInput)
        var h = a.lexicographicallyPrecedes(b) ? a + b : b + a
        for _ in 0..<iterations { h = sha256(h) }
        return format(h)
    }

    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    /// 6 groups of 5 bytes → big-endian UInt64 → `% 100000`, zero-padded, space-separated.
    static func format(_ h: Data) -> String {
        var sb = ""
        var idx = 0
        for group in 0..<6 {
            guard idx + 5 <= h.count else { break }
            var v: UInt64 = 0
            for j in 0..<5 { v = (v << 8) | UInt64(h[h.startIndex + idx + j]) }
            if group > 0 { sb.append(" ") }
            sb.append(String(format: "%05d", v % 100000))
            idx += 5
        }
        return sb
    }
}

// MARK: - Base26

/// Encodes a Long id using uppercase A..Z digits. Mirrors `encodeBase26` in the Modern-Apps library.
enum Base26 {
    private static let digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func encode(_ value: Int64) -> String {
        if value == 0 { return "A" }
        let n = UInt64(bitPattern: value)
        var result = ""
        var v = n
        repeat {
            result.append(digits[Int(v % 26)])
            v /= 26
        } while v > 0
        return String(result.reversed())
    }

    static func decode(_ s: String) -> Int64? {
        var v: UInt64 = 0
        for ch in s.uppercased() {
            guard let idx = digits.firstIndex(of: ch) else { return nil }
            v = v &* 26 &+ UInt64(idx)
        }
        return Int64(bitPattern: v)
    }
}

extension Int64 {
    /// Convenience: `myId.base26`.
    var base26: String { Base26.encode(self) }
}
