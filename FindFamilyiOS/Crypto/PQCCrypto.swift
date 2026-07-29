import Foundation
import CryptoKit

// MARK: - PQC Bundle framing (identical to Kotlin Pqc.kt)
//
// Public bundle:  [4B kemPubLen BE][kemPub SPKI DER][dsaPub SPKI DER]
// Private bundle: [4B kemPrivLen BE][kemPriv PKCS#8 DER][dsaPriv PKCS#8 DER]
// Sealed blob:     [4B encapLen BE][encap(1088)][aes] where aes = [12B iv][ciphertext||tag]
// Shared secret: SHA256(BE32(1) || rawSS) — same KDF as Office / Bouncy Castle's default.

enum PQCBundle {
    // MARK: - Length-prefix framing

    static func lenPrefix(_ a: Data, _ b: Data) -> Data {
        var out = Data()
        out.reserveCapacity(4 + a.count + b.count)
        let alen = UInt32(a.count).bigEndian
        withUnsafeBytes(of: alen) { out.append(contentsOf: $0) }
        out.append(a)
        out.append(b)
        return out
    }

    static func lenPrefixSingle(_ a: Data) -> Data {
        // Same as above but second piece empty — not used but kept for symmetry.
        var out = Data()
        out.reserveCapacity(4 + a.count)
        let alen = UInt32(a.count).bigEndian
        withUnsafeBytes(of: alen) { out.append(contentsOf: $0) }
        out.append(a)
        return out
    }

    static func unLenPrefix(_ x: Data) -> (Data, Data)? {
        guard x.count >= 4 else { return nil }
        let len = x.withUnsafeBytes { ptr -> UInt32 in
            var v: UInt32 = 0
            withUnsafeMutableBytes(of: &v) { dest in
                dest.copyMemory(from: UnsafeRawBufferPointer(start: ptr.baseAddress, count: 4))
            }
            return UInt32(bigEndian: v)
        }
        let lenI = Int(len)
        guard 4 + lenI <= x.count else { return nil }
        let first = x.subdata(in: 4..<(4 + lenI))
        let second = x.subdata(in: (4 + lenI)..<x.count)
        return (first, second)
    }

    // MARK: - Public/Private bundle builders

    static func buildPublic(kemPub: Data, dsaPub: Data) -> Data {
        // Same layout Office uses for directory: [4B kemLen][kem][dsa]
        lenPrefix(kemPub, dsaPub)
    }

    static func buildPrivate(kemPriv: Data, dsaPriv: Data) -> Data {
        // Ephemeral links store private as same framing: [4B kemPrivLen][kemPriv][dsaPriv]
        lenPrefix(kemPriv, dsaPriv)
    }

    static func splitPublic(_ bundle: Data) -> (kemPub: Data, dsaPub: Data)? {
        guard let (k, d) = unLenPrefix(bundle) else { return nil }
        return (k, d)
    }

    static func splitPrivate(_ bundle: Data) -> (kemPriv: Data, dsaPriv: Data)? {
        guard let (k, d) = unLenPrefix(bundle) else { return nil }
        return (k, d)
    }

    // MARK: - Sealed blob helpers [4B encapLen][encap][aes] where aes = [12B iv][ct||tag]

    static func buildSealed(encap: Data, aes: Data) -> Data {
        lenPrefix(encap, aes)
    }

    static func splitSealed(_ blob: Data) -> (encap: Data, aes: Data)? {
        guard let (e, a) = unLenPrefix(blob) else { return nil }
        return (e, a)
    }
}

// MARK: - AES-256-GCM helpers (mirrors E2ee.aesEncrypt / aesDecrypt in Kotlin)
//
// Layout: E2ee.aesEncrypt produces iv(12) + ct||tag (16) with random IV prepended.
// We reproduce that via CryptoKit AES.GCM.

enum PQCAES {
    static let ivLen = 12

    /// Encrypts with `key` (32 bytes), returns `iv(12) + ciphertext||tag`.
    static func seal(key: Data, plaintext: Data) throws -> Data {
        // CryptoKit expects 32-byte key for AES256.
        guard key.count == 32 else { throw NSError(domain: "pqc_aes", code: -1, userInfo: [NSLocalizedDescriptionKey: "key must be 32 bytes"]) }
        let symKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce() // random 12 bytes
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)
        // sealed.ciphertext + sealed.tag (16). We manually prepend iv (nonce) to mimic Kotlin's E2ee.aesEncrypt.
        var out = Data()
        out.reserveCapacity(12 + sealed.ciphertext.count + sealed.tag.count)
        out.append(Data(nonce))
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Reverses `seal`: input `iv(12) + ct||tag`, key 32 bytes.
    static func open(key: Data, sealed: Data) throws -> Data {
        guard key.count == 32 else { throw NSError(domain: "pqc_aes", code: -1, userInfo: [NSLocalizedDescriptionKey: "key must be 32 bytes"]) }
        guard sealed.count >= ivLen + 16 else { throw NSError(domain: "pqc_aes", code: -2, userInfo: [NSLocalizedDescriptionKey: "sealed too short"]) }
        let iv = sealed.subdata(in: 0..<ivLen)
        let ctAndTag = sealed.subdata(in: ivLen..<sealed.count)
        // AES.GCM last 16 bytes = tag
        guard ctAndTag.count >= 16 else { throw NSError(domain: "pqc_aes", code: -3) }
        let tag = ctAndTag.subdata(in: (ctAndTag.count - 16)..<ctAndTag.count)
        let ct = ctAndTag.subdata(in: 0..<(ctAndTag.count - 16))
        let symKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let plain = try AES.GCM.open(sealedBox, using: symKey)
        return plain
    }
}

// MARK: - Security code (same as Kotlin SecurityCode.compute)

enum PQCSecurityCode {
    private static let iterations = 4000

    /// Computes a 6-group 5-digit safety number from two public bundles, identical both sides.
    static func compute(myBundle: Data, theirBundle: Data) -> String {
        let a = sha256(myBundle)
        let b = sha256(theirBundle)
        // canonical order
        var h: Data
        if a.lexicographicallyPrecedes(b) { h = a + b } else { h = b + a }
        for _ in 0..<iterations { h = sha256(h) }
        return format(h)
    }

    private static func sha256(_ d: Data) -> Data {
        Data(SHA256.hash(data: d))
    }

    private static func format(_ h: Data) -> String {
        var sb = ""
        var idx = 0
        for group in 0..<6 {
            guard idx + 5 <= h.count else { break }
            var v: UInt64 = 0
            for j in 0..<5 {
                v = (v << 8) | UInt64(h[idx + j])
            }
            if group > 0 { sb.append(" ") }
            sb.append(String(format: "%05d", v % 100000))
            idx += 5
        }
        return sb
    }
}

// MARK: - PQC Rust bridge (C exports)
//
// If the Rust lib `libe2ee_pqc.a` is linked as an XCFramework, these symbols exist.
// If not linked (simulator without framework), calls return 0 and the Swift layer
// treats PQC as unavailable (graceful fallback to RSA).

// C functions exported from e2ee_pqc/src/c_bridge.rs
@_silgen_name("pqc_free")
func pqc_free(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int)

@_silgen_name("pqc_secure_zero")
func pqc_secure_zero(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int)

@_silgen_name("pqc_kem_keygen")
func pqc_kem_keygen(
    _ pub_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ pub_len_out: UnsafeMutablePointer<Int>,
    _ priv_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ priv_len_out: UnsafeMutablePointer<Int>
) -> Int32

@_silgen_name("pqc_dsa_keygen")
func pqc_dsa_keygen(
    _ pub_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ pub_len_out: UnsafeMutablePointer<Int>,
    _ priv_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ priv_len_out: UnsafeMutablePointer<Int>
) -> Int32

@_silgen_name("pqc_identity_keygen")
func pqc_identity_keygen(
    _ pub_bundle_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ pub_bundle_len_out: UnsafeMutablePointer<Int>,
    _ priv_bundle_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ priv_bundle_len_out: UnsafeMutablePointer<Int>
) -> Int32

@_silgen_name("pqc_kem_encaps")
func pqc_kem_encaps(
    _ kem_pub: UnsafePointer<UInt8>?, _ kem_pub_len: Int,
    _ ct_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ ct_len_out: UnsafeMutablePointer<Int>,
    _ ss_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ ss_len_out: UnsafeMutablePointer<Int>
) -> Int32

@_silgen_name("pqc_kem_decaps")
func pqc_kem_decaps(
    _ kem_priv: UnsafePointer<UInt8>?, _ kem_priv_len: Int,
    _ ct: UnsafePointer<UInt8>?, _ ct_len: Int,
    _ ss_out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ ss_len_out: UnsafeMutablePointer<Int>
) -> Int32

@_silgen_name("pqc_security_code")
func pqc_security_code_c(
    _ my_bundle: UnsafePointer<UInt8>?, _ my_bundle_len: Int,
    _ their_bundle: UnsafePointer<UInt8>?, _ their_bundle_len: Int,
    _ out: UnsafeMutablePointer<UInt8>?, _ out_len: Int
) -> Int32

// MARK: - High-level PQC ops that mirror Kotlin Pqc.encryptTo / decrypt

enum PQCCrypto {
    /// Encrypts `plaintext` to a recipient's public PQC bundle (from PQCBundle.buildPublic).
    /// Layout sealed = [4B encapLen BE][encap(1088)][aes] where aes = [12B iv][ct||tag],
    /// identical to Kotlin's Pqc.encryptTo (which does encaps + E2ee.aesEncrypt).
    static func encryptTo(bundle: Data, plaintext: Data) throws -> Data {
        guard let (kemPub, _) = PQCBundle.splitPublic(bundle) else {
            throw NSError(domain: "pqc", code: -1, userInfo: [NSLocalizedDescriptionKey: "invalid PQC bundle"])
        }
        // Use C bridge if available, otherwise throw to signal PQC unavailable.
        // The Rust lib may not be linked on simulator — try and fall back.
        if let sealed = try? encryptToViaNative(kemPub: kemPub, plaintext: plaintext) {
            return sealed
        }
        // If native not linked, throw — caller treats as PQC unavailable.
        throw NSError(domain: "pqc", code: -10, userInfo: [NSLocalizedDescriptionKey: "PQC native not available"])
    }

    /// Decrypts sealed blob produced by `encryptTo` using our KEM private DER.
    static func decrypt(kemPrivateDer: Data, sealed: Data) throws -> Data {
        guard let (encap, aes) = PQCBundle.splitSealed(sealed) else {
            throw NSError(domain: "pqc", code: -2, userInfo: [NSLocalizedDescriptionKey: "invalid sealed blob"])
        }
        // Native decaps
        let ss: Data
        if let s = try? decapsViaNative(kemPrivateDer: kemPrivateDer, encap: encap) {
            ss = s
        } else {
            throw NSError(domain: "pqc", code: -11, userInfo: [NSLocalizedDescriptionKey: "PQC native decaps not available"])
        }
        return try PQCAES.open(key: ss, sealed: aes)
    }

    // Convenience: decrypt using private bundle [4B kemPrivLen][kemPriv][dsaPriv]
    // (mirrors how ephemeral links store private bundle).
    static func decryptWithPrivateBundle(privateBundle: Data, sealed: Data) throws -> Data {
        guard let (kemPriv, _) = PQCBundle.splitPrivate(privateBundle) else {
            throw NSError(domain: "pqc", code: -3, userInfo: [NSLocalizedDescriptionKey: "invalid private bundle"])
        }
        return try decrypt(kemPrivateDer: kemPriv, sealed: sealed)
    }

    // MARK: - Native wrappers

    private static func encryptToViaNative(kemPub: Data, plaintext: Data) throws -> Data {
        var ctPtr: UnsafeMutablePointer<UInt8>? = nil
        var ctLen: Int = 0
        var ssPtr: UnsafeMutablePointer<UInt8>? = nil
        var ssLen: Int = 0

        let ok: Int32 = kemPub.withUnsafeBytes { pubBuf in
            pqc_kem_encaps(
                pubBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), pubBuf.count,
                &ctPtr, &ctLen,
                &ssPtr, &ssLen
            )
        }
        guard ok == 1, let cPtr = ctPtr, let sPtr = ssPtr else {
            throw NSError(domain: "pqc", code: -4, userInfo: [NSLocalizedDescriptionKey: "encaps failed (native not linked?)"])
        }
        // Ensure free even on throw
        defer {
            pqc_free(cPtr, ctLen)
            pqc_secure_zero(sPtr, ssLen)
            pqc_free(sPtr, ssLen)
        }
        let encap = Data(bytes: cPtr, count: ctLen)
        let ss = Data(bytes: sPtr, count: ssLen)
        let aes = try PQCAES.seal(key: ss, plaintext: plaintext)
        return PQCBundle.buildSealed(encap: encap, aes: aes)
    }

    private static func decapsViaNative(kemPrivateDer: Data, encap: Data) throws -> Data {
        var ssPtr: UnsafeMutablePointer<UInt8>? = nil
        var ssLen: Int = 0
        let ok: Int32 = kemPrivateDer.withUnsafeBytes { privBuf in
            encap.withUnsafeBytes { ctBuf in
                pqc_kem_decaps(
                    privBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), privBuf.count,
                    ctBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), ctBuf.count,
                    &ssPtr, &ssLen
                )
            }
        }
        guard ok == 1, let sPtr = ssPtr else {
            throw NSError(domain: "pqc", code: -5, userInfo: [NSLocalizedDescriptionKey: "decaps failed"])
        }
        defer {
            pqc_secure_zero(sPtr, ssLen)
            pqc_free(sPtr, ssLen)
        }
        return Data(bytes: sPtr, count: ssLen)
    }

    /// Generates a full identity (public bundle + private bundle) via Rust. Falls back to error if native not linked.
    static func generateIdentity() throws -> (publicBundle: Data, privateBundle: Data) {
        var pubPtr: UnsafeMutablePointer<UInt8>? = nil
        var pubLen: Int = 0
        var privPtr: UnsafeMutablePointer<UInt8>? = nil
        var privLen: Int = 0
        let ok = pqc_identity_keygen(&pubPtr, &pubLen, &privPtr, &privLen)
        guard ok == 1, let pb = pubPtr, let pr = privPtr else {
            throw NSError(domain: "pqc", code: -6, userInfo: [NSLocalizedDescriptionKey: "identity keygen failed (native not linked?)"])
        }
        defer {
            // Don't free bundle here — copy first, free after.
            // Private bundle contains secrets: zero then free.
            // Public bundle freed after copy.
            // Caller's Data owns copy.
        }
        let pubData = Data(bytes: pb, count: pubLen)
        let privData = Data(bytes: pr, count: privLen)
        pqc_free(pb, pubLen)
        pqc_secure_zero(pr, privLen)
        pqc_free(pr, privLen)
        return (pubData, privData)
    }
}
