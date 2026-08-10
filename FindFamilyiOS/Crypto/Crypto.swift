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

// MARK: - RSA Key Manager

/// Manages a single device-wide RSA-OAEP-SHA512 key pair. 4096-bit keys to match the
/// Android implementation's effective payload limits (LocationValue JSON > 126 bytes).
final class RSAKeyManager {
    static let shared = RSAKeyManager()

    private let keySize = 4096
    private var _privateKey: SecKey?
    private var _publicKey: SecKey?

    private init() {}

    /// Returns the device key pair, generating + persisting it on first use.
    func keyPair() throws -> (privateKey: SecKey, publicKey: SecKey) {
        if let pri = _privateKey, let pub = _publicKey {
            return (pri, pub)
        }
        // Try to restore from keychain.
        if let priDER = Keychain.getData(key: "rsaPrivateDER"),
           let pri = importPrivateKey(der: priDER),
           let pub = SecKeyCopyPublicKey(pri) {
            _privateKey = pri
            _publicKey = pub
            return (pri, pub)
        }
        // Generate new.
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySize,
        ]
        var error: Unmanaged<CFError>?
        guard let pri = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(pri) else {
            throw error?.takeRetainedValue() as Error? ?? NSError(domain: "rsa", code: -1)
        }
        // Persist private key DER (PKCS#1 RSAPrivateKey format that SecKey returns natively).
        var error2: Unmanaged<CFError>?
        guard let priData = SecKeyCopyExternalRepresentation(pri, &error2) as Data? else {
            throw error2?.takeRetainedValue() as Error? ?? NSError(domain: "rsa", code: -2)
        }
        Keychain.setData(priData, key: "rsaPrivateDER")
        _privateKey = pri
        _publicKey = pub
        return (pri, pub)
    }

    /// Generate a fresh, ephemeral key pair (used for TemporaryLink share URLs).
    func generateEphemeralKeyPair() throws -> (privateKey: SecKey, publicKey: SecKey) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySize,
        ]
        var error: Unmanaged<CFError>?
        guard let pri = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(pri) else {
            throw error?.takeRetainedValue() as Error? ?? NSError(domain: "rsa", code: -1)
        }
        return (pri, pub)
    }

    private func importPrivateKey(der: Data) -> SecKey? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: keySize,
        ]
        var err: Unmanaged<CFError>?
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err)
    }

    func importPublicKey(der: Data) -> SecKey? {
        // Parse the modulus length from PKCS#1 so we don't have to assume the size
        // matches our own key — peers (e.g. Android) may use a different bit length.
        let bits = RSAPEM.rsaModulusBits(pkcs1DER: der) ?? 2048
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: bits,
        ]
        var err: Unmanaged<CFError>?
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err)
    }

    func encryptOAEPSHA512(_ data: Data, publicKey: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let out = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA512, data as CFData, &err) as Data? else {
            throw err?.takeRetainedValue() as Error? ?? NSError(domain: "rsa", code: -3)
        }
        return out
    }

    func decryptOAEPSHA512(_ data: Data, privateKey: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA512, data as CFData, &err) as Data? else {
            throw err?.takeRetainedValue() as Error? ?? NSError(domain: "rsa", code: -4)
        }
        return out
    }
}

// MARK: - PEM ↔ DER ↔ SecKey conversions

/// SecKey for RSA returns/accepts PKCS#1 DER. Most PEM PUBLIC KEY blocks use X.509
/// SubjectPublicKeyInfo, and PEM PRIVATE KEY blocks use PKCS#8. We wrap/unwrap here.
enum RSAPEM {

    static let rsaOID: [UInt8] = [
        0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01  // 1.2.840.113549.1.1.1
    ]

    // MARK: - Public key

    /// Wrap PKCS#1 RSAPublicKey into X.509 SubjectPublicKeyInfo PEM.
    static func publicKeyToPEM(_ key: SecKey) throws -> String {
        var err: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw err?.takeRetainedValue() as Error? ?? NSError(domain: "pem", code: -1)
        }
        let der = wrapX509SPKI(pkcs1: pkcs1)
        return wrapPEM(label: "PUBLIC KEY", der: der)
    }

    /// Parse a PEM PUBLIC KEY (X.509 SPKI or PKCS#1) into SecKey.
    static func publicKeyFromPEM(_ pem: String) -> SecKey? {
        guard let der = unwrapPEM(pem) else { return nil }
        let pkcs1 = stripX509SPKI(der: der) ?? der
        return RSAKeyManager.shared.importPublicKey(der: pkcs1)
    }

    // MARK: - Private key

    /// Wrap PKCS#1 RSAPrivateKey into PKCS#8 PrivateKeyInfo PEM.
    static func privateKeyToPEM(_ key: SecKey) throws -> String {
        var err: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw err?.takeRetainedValue() as Error? ?? NSError(domain: "pem", code: -1)
        }
        let der = wrapPKCS8(pkcs1: pkcs1)
        return wrapPEM(label: "PRIVATE KEY", der: der)
    }

    // MARK: - PEM framing helpers

    static func wrapPEM(label: String, der: Data) -> String {
        let b64 = der.base64EncodedString()
        // 64-char lines per RFC 7468.
        var lines: [String] = []
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[idx..<end]))
            idx = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    static func unwrapPEM(_ pem: String) -> Data? {
        let lines = pem.split(separator: "\n").map(String.init)
        let body = lines
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: body)
    }

    // MARK: - ASN.1 helpers

    /// Wrap a PKCS#1 RSAPublicKey into X.509 SubjectPublicKeyInfo.
    static func wrapX509SPKI(pkcs1: Data) -> Data {
        // AlgorithmIdentifier ::= SEQUENCE { OID rsaEncryption, NULL }
        let alg = asn1Sequence(asn1OID(rsaOID) + asn1Null())
        // BIT STRING with 0 unused bits + PKCS#1 RSAPublicKey
        let bitString = asn1BitString(content: pkcs1)
        return asn1Sequence(alg + bitString)
    }

    /// Strip the X.509 wrapping (if present) and return the inner PKCS#1 bytes. Best-effort.
    static func stripX509SPKI(der: Data) -> Data? {
        var p = ASN1Parser(data: der)
        guard let outerSeq = p.readSequence() else { return nil }
        var inner = ASN1Parser(data: outerSeq)
        guard inner.skipSequence() else { return nil }  // AlgorithmIdentifier
        guard let bits = inner.readBitString() else { return nil }
        return bits
    }

    /// Parse the modulus bit length from a PKCS#1 RSAPublicKey or RSAPrivateKey DER.
    /// PKCS#1: SEQUENCE { INTEGER modulus, INTEGER exponent, ... }
    /// For PKCS#1 private keys: SEQUENCE { INTEGER version=0, INTEGER modulus, INTEGER exponent, ... }
    static func rsaModulusBits(pkcs1DER: Data) -> Int? {
        var parser = ASN1Parser(data: pkcs1DER)
        guard let seq = parser.readSequence() else { return nil }
        var inner = ASN1Parser(data: seq)
        // First INTEGER might be a version (private keys) or the modulus (public keys).
        guard var firstInt = inner.readTag(0x02) else { return nil }
        // Heuristic: if it's a single byte (version), the next INTEGER is the modulus.
        if firstInt.count <= 4 {
            guard let modulus = inner.readTag(0x02) else { return nil }
            firstInt = modulus
        }
        // Strip leading 0x00 if present (DER INTEGER sign byte).
        var bytes = firstInt
        if let f = bytes.first, f == 0 { bytes = bytes.dropFirst() }
        return bytes.count * 8
    }

    /// Wrap a PKCS#1 RSAPrivateKey into PKCS#8 PrivateKeyInfo.
    static func wrapPKCS8(pkcs1: Data) -> Data {
        let version = asn1Integer(value: 0)
        let alg = asn1Sequence(asn1OID(rsaOID) + asn1Null())
        let octet = asn1OctetString(content: pkcs1)
        return asn1Sequence(version + alg + octet)
    }

    static func asn1Sequence(_ content: Data) -> Data {
        Data([0x30]) + asn1Length(content.count) + content
    }
    static func asn1OctetString(content: Data) -> Data {
        Data([0x04]) + asn1Length(content.count) + content
    }
    static func asn1BitString(content: Data) -> Data {
        // 0 unused bits.
        Data([0x03]) + asn1Length(content.count + 1) + Data([0x00]) + content
    }
    static func asn1Null() -> Data { Data([0x05, 0x00]) }
    static func asn1OID(_ bytes: [UInt8]) -> Data {
        Data([0x06]) + asn1Length(bytes.count) + Data(bytes)
    }
    static func asn1Integer(value: UInt8) -> Data {
        Data([0x02, 0x01, value])
    }

    static func asn1Length(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var len = length
        var bytes: [UInt8] = []
        while len > 0 {
            bytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}

/// Minimal ASN.1 parser sufficient for unwrapping X.509 SPKI.
private struct ASN1Parser {
    let data: Data
    var offset: Int = 0

    init(data: Data) { self.data = data }

    mutating func readByte() -> UInt8? {
        guard offset < data.count else { return nil }
        let b = data[data.startIndex + offset]
        offset += 1
        return b
    }

    mutating func readLength() -> Int? {
        guard let first = readByte() else { return nil }
        if first < 0x80 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 8 else { return nil }
        var len = 0
        for _ in 0..<count {
            guard let b = readByte() else { return nil }
            len = (len << 8) | Int(b)
        }
        return len
    }

    mutating func readTag(_ tag: UInt8) -> Data? {
        guard let t = readByte(), t == tag else { return nil }
        guard let len = readLength() else { return nil }
        let start = data.startIndex + offset
        guard offset + len <= data.count else { return nil }
        let bytes = data.subdata(in: start..<(start + len))
        offset += len
        return bytes
    }

    mutating func readSequence() -> Data? { readTag(0x30) }

    mutating func skipSequence() -> Bool { readSequence() != nil }

    mutating func readBitString() -> Data? {
        guard let bs = readTag(0x03) else { return nil }
        guard let first = bs.first, first == 0 else { return nil }
        return bs.dropFirst()
    }
}

// MARK: - Security code formatting (shared by PQC + RSA safety numbers)

/// Formats an iterated hash into a 6-group, 5-digit safety number, and runs the shared
/// canonical-order iterated-SHA256 computation. Identical to Kotlin `SecurityCode`.
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

// MARK: - RSA security code (safety number over canonical X.509 SPKI DER)

/// Computes the RSA safety number matching Android's `E2ee.securityCode`, which hashes the
/// **canonical DER** (X.509 SubjectPublicKeyInfo) of each RSA public key. iOS `SecKey` gives
/// PKCS#1, so we wrap to SPKI first to match the Android encoding byte-for-byte. Callers pass
/// the two canonical DERs to `SecurityCodeFormat.compute` (run off the main actor).
enum RSASecurityCode {
    /// Canonical X.509 SPKI DER for an RSA public SecKey (PKCS#1 → SPKI), matching Android.
    static func canonicalDER(_ key: SecKey) -> Data? {
        var err: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &err) as Data? else { return nil }
        return RSAPEM.wrapX509SPKI(pkcs1: pkcs1)
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
