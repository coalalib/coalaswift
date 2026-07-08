import Foundation
import XCTest
import Curve25519
@testable import Coala

/// Extracts crypto vectors (pending until Phase 3). Uses FIXED inputs so the
/// fixtures are stable across regeneration. HKDF: HMAC-SHA256, empty salt/info,
/// 40-byte output split 16/16/4/4. AES-GCM: 12-byte truncated tag appended;
/// nonce = IV(4) ‖ LE u16 counter ‖ 6 zero bytes. Handshake: message framing +
/// role-based key/IV mapping from a FIXED shared secret (no ECDH in Phase 1 —
/// see the task's design note; Phase 3 adds the X25519 cross-check).
final class CryptoVectorTests: XCTestCase {

    // MARK: hkdf

    func testExtractHkdfVectors() {
        // Arbitrary but fixed 32-byte shared secrets (HKDF does not require a
        // real X25519 output — only the IKM matters for this transform).
        let secrets: [(String, [UInt8])] = [
            ("all_0x01", Array(repeating: 0x01, count: 32)),
            ("counting", (0..<32).map { UInt8($0) }),
        ]
        let cases: [[String: Any]] = secrets.map { (name, bytes) in
            let hkdf = HKDF(sharedSecret: Data(bytes), salt: Data(), info: Data())
            return ["name": name,
                    "shared_secret_hex": VectorWriter.hex(Data(bytes)),
                    "peer_key_hex": VectorWriter.hex(hkdf.peerKey),
                    "my_key_hex": VectorWriter.hex(hkdf.myKey),
                    "peer_iv_hex": VectorWriter.hex(hkdf.peerIV),
                    "my_iv_hex": VectorWriter.hex(hkdf.myIV)]
        }
        VectorWriter.emit(category: "hkdf",
                          generator: "CoalaTests/VectorExtraction/CryptoVectorTests.swift",
                          cases: cases)
    }

    // MARK: aes_gcm

    func testExtractAesGcmVectors() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data([0xA1, 0xA2, 0xA3, 0xA4])
        // 4-member tuple; the repo's SwiftLint fails the build on 4+ (large_tuple).
        // swiftlint:disable:next large_tuple
        let specs: [(String, UInt16, Data, Data)] = [
            ("counter0_no_aad", 0, Data(), "hello".data(using: .utf8)!),
            ("counter1_with_aad", 1, Data([0xDE, 0xAD]), "world!!".data(using: .utf8)!),
            ("counter_0x1234", 0x1234, Data(), Data([0x00, 0xFF, 0x10])),
        ]
        let cases: [[String: Any]] = try specs.map { (name, counter, aad, plain) in
            let nonce = AEAD.makeNonce(iVector: iv, counter: counter)
            let sealed = try AESGCM(key: key).seal(plainText: plain, nonce: nonce,
                                                   additionalAuthenticatedData: aad)
            return ["name": name,
                    "key_hex": VectorWriter.hex(key),
                    "iv_hex": VectorWriter.hex(iv),
                    "counter": Int(counter),
                    "aad_hex": VectorWriter.hex(aad),
                    "plaintext_hex": VectorWriter.hex(plain),
                    "nonce_hex": VectorWriter.hex(nonce),
                    "ciphertext_and_tag_hex": VectorWriter.hex(sealed)]
        }
        VectorWriter.emit(category: "aes_gcm",
                          generator: "CoalaTests/VectorExtraction/CryptoVectorTests.swift",
                          cases: cases)
    }

    // MARK: handshake

    func testExtractHandshakeVectors() throws {
        // Phase 1 does NOT run X25519 (no way to inject a chosen keypair via
        // this lib, and the ECDH cross-check is a Phase 3 gate). Fix the shared
        // secret as a constant; the REAL Swift HKDF split from it is the oracle.
        let sharedSecret = Data((0..<32).map { UInt8(0x11 &* UInt8($0 &+ 1)) })
        let hkdf = HKDF(sharedSecret: sharedSecret, salt: Data(), info: Data())

        // Role mapping, from SecuredSession.start + AEAD.init:
        //  outgoing (incoming:false): seal key=myKey iv=myIV; open key=peerKey iv=peerIV
        //  incoming (incoming:true):  seal key=peerKey iv=peerIV; open key=myKey iv=myIV
        let outgoing: [String: Any] = [
            "seal_key_hex": VectorWriter.hex(hkdf.myKey),
            "seal_iv_hex": VectorWriter.hex(hkdf.myIV),
            "open_key_hex": VectorWriter.hex(hkdf.peerKey),
            "open_iv_hex": VectorWriter.hex(hkdf.peerIV),
        ]
        let incoming: [String: Any] = [
            "seal_key_hex": VectorWriter.hex(hkdf.peerKey),
            "seal_iv_hex": VectorWriter.hex(hkdf.peerIV),
            "open_key_hex": VectorWriter.hex(hkdf.myKey),
            "open_iv_hex": VectorWriter.hex(hkdf.myIV),
        ]

        // Fixed 32-byte public-key stand-ins (NOT ECDH-derived in Phase 1).
        let pubA = Data((0..<32).map { UInt8($0 &+ 1) })
        let pubB = Data((0..<32).map { UInt8(0x40 &+ UInt8($0)) })

        // Handshake messages: type 1 = CON GET, handshakeType=1, payload=pubA.
        // type 2 = ACK 2.05, handshakeType=2, payload=pubB.
        var type1 = CoAPMessage(type: .confirmable, code: .request(.get), messageId: 0x1111)
        type1.token = CoAPToken(value: Data([0x01, 0x02, 0x03, 0x04]))
        type1.setOption(.handshakeType, value: 1)
        type1.payload = pubA   // CoAPMessagePayload is a protocol; Data conforms
        type1.addChecksumOnSend = false

        var type2 = CoAPMessage(type: .acknowledgement, code: .response(.content), messageId: 0x1111)
        type2.token = CoAPToken(value: Data([0x01, 0x02, 0x03, 0x04]))
        type2.setOption(.handshakeType, value: 2)
        type2.payload = pubB   // CoAPMessagePayload is a protocol; Data conforms
        type2.addChecksumOnSend = false

        let type1Bytes = try CoAPSerializer.dataWithCoAPMessage(type1)
        let type2Bytes = try CoAPSerializer.dataWithCoAPMessage(type2)

        let handshakeCase: [String: Any] = [
            "name": "fixed_shared_secret",
            "shared_secret_hex": VectorWriter.hex(sharedSecret),
            "hkdf": [
                "peer_key_hex": VectorWriter.hex(hkdf.peerKey),
                "my_key_hex": VectorWriter.hex(hkdf.myKey),
                "peer_iv_hex": VectorWriter.hex(hkdf.peerIV),
                "my_iv_hex": VectorWriter.hex(hkdf.myIV),
            ],
            "outgoing": outgoing,
            "incoming": incoming,
            "pub_a_hex": VectorWriter.hex(pubA),
            "pub_b_hex": VectorWriter.hex(pubB),
            "type1_bytes_hex": VectorWriter.hex(type1Bytes),
            "type2_bytes_hex": VectorWriter.hex(type2Bytes),
        ]

        VectorWriter.emit(category: "handshake",
                          generator: "CoalaTests/VectorExtraction/CryptoVectorTests.swift",
                          cases: [handshakeCase])
    }

    // MARK: x25519 (donna ECDH cross-check oracle — deferred from Phase 1)

    func testExtractX25519Vectors() throws {
        let basepoint = Data([9] + [UInt8](repeating: 0, count: 31))

        // Inject a fixed private key via the NSCoding path (public field unused
        // by ECDH — zero placeholder). See the task design note.
        func keyPair(priv: [UInt8]) -> ECKeyPair {
            precondition(priv.count == 32)
            let coder = NSKeyedArchiver(requiringSecureCoding: false)
            var placeholderPublic = [UInt8](repeating: 0, count: 32)
            coder.encodeBytes(&placeholderPublic, length: 32, forKey: "TSECKeyPairPublicKey")
            var scalar = priv
            coder.encodeBytes(&scalar, length: 32, forKey: "TSECKeyPairPrivateKey")
            coder.finishEncoding()
            // ECKeyPair.initWithCoder reads the two byte fields from the *top-level*
            // decode container (Curve25519.m:34-54). ECKeyPair.from(data:) routes
            // through unarchiveObject(with:), which decodes the archive "root" key —
            // absent here — and returns nil. Decode the top-level container directly.
            // swiftlint:disable:next force_try
            let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
            unarchiver.requiresSecureCoding = false
            let pair = ECKeyPair(coder: unarchiver)!
            unarchiver.finishDecoding()
            return pair
        }
        // The instance method generateSharedSecretFromPublicKey: is defined in
        // Curve25519.m but NOT declared in Curve25519.h, so Swift cannot see it.
        // The header-exposed class method forwards to the same donna call
        // (curve25519_donna(out, keyPair->privateKey, peer)) — identical oracle.
        func publicKey(_ priv: [UInt8]) -> Data {
            Curve25519.generateSharedSecret(fromPublicKey: basepoint, andKeyPair: keyPair(priv: priv))
        }
        func ecdh(_ priv: [UInt8], _ peer: Data) -> Data {
            Curve25519.generateSharedSecret(fromPublicKey: peer, andKeyPair: keyPair(priv: priv))
        }

        // Fixed private scalars. A/B properly clamped; X deliberately unclamped
        // (low bit set, canonical clamp bits wrong) to pin clamp-at-use.
        var privA = (0..<32).map { UInt8($0 + 1) }
        privA[0] &= 248; privA[31] &= 127; privA[31] |= 64
        var privB = (0..<32).map { UInt8(0x40 + $0) }
        privB[0] &= 248; privB[31] &= 127; privB[31] |= 64
        let privX = (0..<32).map { _ in UInt8(0xFF) } // all-ones: unclamped

        let pubA = publicKey(privA)
        let pubB = publicKey(privB)

        // High-bit-set peer key (RFC mandates masking bit 255).
        var pubBHigh = [UInt8](pubB); pubBHigh[31] |= 0x80

        // Canonical order-8 low-order point.
        let lowOrder = Data([
            0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f,
            0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16,
            0x5f, 0x49, 0xb8, 0x00,
        ])

        // 4-member tuple; SwiftLint fails on 4+ (large_tuple).
        // swiftlint:disable:next large_tuple
        let cases: [[String: Any]] = [
            ["name": "public_clamped", "kind": "public",
             "private_hex": VectorWriter.hex(Data(privA)),
             "expected_hex": VectorWriter.hex(pubA)],
            ["name": "public_unclamped", "kind": "public",
             "private_hex": VectorWriter.hex(Data(privX)),
             "expected_hex": VectorWriter.hex(publicKey(privX))],
            ["name": "ecdh_ab", "kind": "ecdh",
             "private_hex": VectorWriter.hex(Data(privA)),
             "peer_public_hex": VectorWriter.hex(pubB),
             "expected_hex": VectorWriter.hex(ecdh(privA, pubB))],
            ["name": "ecdh_ba", "kind": "ecdh",
             "private_hex": VectorWriter.hex(Data(privB)),
             "peer_public_hex": VectorWriter.hex(pubA),
             "expected_hex": VectorWriter.hex(ecdh(privB, pubA))],
            ["name": "ecdh_high_bit_peer", "kind": "ecdh",
             "private_hex": VectorWriter.hex(Data(privA)),
             "peer_public_hex": VectorWriter.hex(Data(pubBHigh)),
             "expected_hex": VectorWriter.hex(ecdh(privA, Data(pubBHigh)))],
            ["name": "ecdh_low_order", "kind": "ecdh",
             "private_hex": VectorWriter.hex(Data(privA)),
             "peer_public_hex": VectorWriter.hex(lowOrder),
             "expected_hex": VectorWriter.hex(ecdh(privA, lowOrder))],
        ]

        VectorWriter.emit(category: "x25519",
                          generator: "CoalaTests/VectorExtraction/CryptoVectorTests.swift",
                          cases: cases)
    }
}
