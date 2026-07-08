import Foundation
import XCTest
@testable import Coala

/// Extracts the serializer-family vector categories (all pending until their
/// consuming phase): malformed-datagram rejection, TCP framing, the CRC32
/// checksum option, and block-option packing.
final class SerializerFamilyVectorTests: XCTestCase {

    // MARK: udp_codec_invalid

    func testExtractInvalidDatagramVectors() {
        // Each byte string MUST be rejected by coapMessageWithData. We record
        // the bytes + a rejection marker; the harness asserts Swift rejects.
        let invalids: [(String, String, [UInt8])] = [
            ("truncated_header", "3-byte datagram (< 4-byte header)", [0x44, 0x01, 0x12]),
            ("reserved_token_length", "TKL=9 is reserved and MUST be rejected",
             [0x49, 0x01, 0x12, 0x34, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
            ("token_beyond_buffer", "TKL=4 but only 2 token bytes present",
             [0x44, 0x01, 0x12, 0x34, 0xAA, 0xBB]),
            ("option_length_beyond_buffer", "option claims 5-byte value, buffer has 1",
             [0x40, 0x01, 0x12, 0x34, 0x05, 0xAA]),
            ("unknown_code", "code byte 0xE0 (7.00) has no registry case",
             [0x50, 0xE0, 0x00, 0x01]),
            ("delta_nibble_15", "option delta nibble 0xF is reserved",
             [0x50, 0x01, 0x00, 0x01, 0xF1, 0x61]),
            ("ext14_overflow", "ext-14 delta 0xFFFF + 269 exceeds UInt16",
             [0x50, 0x01, 0x00, 0x01, 0xE1, 0xFF, 0xFF, 0xAA]),
        ]
        // Confirm Swift actually rejects each — the vector is only valid if it
        // does. Asserted in its own loop: a `try` inside XCTAssertThrowsError
        // within a `rethrows` map closure makes the closure infer as throwing.
        for (name, _, bytes) in invalids {
            XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(Data(bytes)),
                                 "\(name) should be rejected by Swift")
        }
        let cases: [[String: Any]] = invalids.map { (name, desc, bytes) in
            let data = Data(bytes)
            return ["name": name, "description": desc,
                    "bytes_hex": VectorWriter.hex(data), "expect": "reject"]
        }
        VectorWriter.emit(category: "udp_codec_invalid",
                          generator: "CoalaTests/VectorExtraction/SerializerFamilyVectorTests.swift",
                          cases: cases)
    }

    // MARK: tcp_framing

    func testExtractTcpFramingVectors() {
        let serializer = CoAPTcpSerializer()
        // swiftlint:disable:next large_tuple
        let specs: [(String, String, String, UInt16, [UInt8])] = [
            ("dotted_quad_small", "1.2.3.4:5683, 3-byte payload", "1.2.3.4", 5683, [0x01, 0x02, 0x03]),
            ("non_dotted_host_falls_back", "host 'localhost' → 0.0.0.0 IP field", "localhost", 1234, [0xFF]),
            ("empty_payload", "zero-length CoAP payload", "10.0.0.1", 80, []),
            ("unparseable_octets_dropped", "'999.1.2.3.4' → compactMap keeps 1.2.3.4",
             "999.1.2.3.4", 7000, [0x01]),
        ]
        let cases: [[String: Any]] = specs.map { (name, desc, host, port, payload) in
            let address = Address(host: host, port: port)
            let data = Data(payload)
            let frame = serializer.encodeTcpFrame(with: address, data: data)
            return ["name": name, "description": desc,
                    "address": ["host": host, "port": Int(port)],
                    "coap_bytes_hex": VectorWriter.hex(data),
                    "frame_hex": VectorWriter.hex(frame)]
        }
        VectorWriter.emit(category: "tcp_framing",
                          generator: "CoalaTests/VectorExtraction/SerializerFamilyVectorTests.swift",
                          cases: cases)
    }

    // MARK: checksum_option

    func testExtractChecksumVectors() throws {
        // checksumForMessage serializes the message with .checksum removed and
        // addChecksumOnSend=false, then formats crc32IEEE as 8-char lowercase
        // hex. The option value is the ASCII of that hex string, not raw bytes.
        let specs: [(String, String, () throws -> CoAPMessage)] = [
            ("get_uri_path", "CON GET /test", {
                var m = CoAPMessage(type: .confirmable, code: .request(.get), messageId: 0x1234)
                m.token = CoAPToken(value: Data([0xAA, 0xBB, 0xCC, 0xDD]))
                m.setOption(.uriPath, value: "test")
                return m
            }),
            ("content_payload", "ACK 2.05 payload 'hi'", {
                var m = CoAPMessage(type: .acknowledgement, code: .response(.content), messageId: 0x1234)
                // CoAPMessagePayload is a protocol; Data conforms — assign directly.
                m.payload = "hi".data(using: .utf8)!
                return m
            }),
        ]
        let cases: [[String: Any]] = try specs.map { (name, desc, make) in
            var message = try make()
            message.addChecksumOnSend = false
            let checksum = try CoAPSerializer.checksumForMessage(message)
            let messageBytes = try CoAPSerializer.dataWithCoAPMessage(message)
            return ["name": name, "description": desc,
                    "message_bytes_hex": VectorWriter.hex(messageBytes),
                    "checksum_hex_string": checksum]
        }

        // Embedded-checksum accept/reject cases, incl. the pair that pins
        // divergence item 1 (unknown options are dropped BEFORE the checksum
        // is re-verified against a re-serialization).
        var base = CoAPMessage(type: .nonConfirmable, code: .request(.get), messageId: 0x0001)
        base.setOption(.uriPath, value: "a")

        var withChecksum = base
        withChecksum.addChecksumOnSend = true
        let validBytes = try CoAPSerializer.dataWithCoAPMessage(withChecksum)
        XCTAssertNoThrow(try CoAPSerializer.coapMessageWithData(validBytes))

        var corrupted = validBytes
        corrupted[corrupted.count - 1] ^= 0x01 // last ASCII char of the checksum value
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(corrupted))

        // Unknown option 5000 appended after the checksum option (ascending
        // wire order; delta 4006→5000 = 994 = ext14 0x02D5, length 1).
        let unknownAfterChecksum = Data([0xE1, 0x02, 0xD5, 0xAA])
        // ACCEPT: checksum was computed WITHOUT the unknown option, which is
        // exactly what Swift re-serializes after dropping it.
        let postdropBytes = validBytes + unknownAfterChecksum
        XCTAssertNoThrow(try CoAPSerializer.coapMessageWithData(postdropBytes))

        // REJECT: checksum computed over the FULL bytes including the
        // unknown option (11→5000 delta 4989 = ext14 0x1270); after the
        // drop, Swift's recomputation no longer matches.
        let baseBytes = try CoAPSerializer.dataWithCoAPMessage(base)
        let fullBytes = baseBytes + Data([0xE1, 0x12, 0x70, 0xAA])
        let fullChecksum = String(format: "%08x", fullBytes.crc32IEEE)
        // Assemble: header+uriPath, checksum option (11→4006 delta 3995 =
        // ext14 0x0E8E, length 8), then unknown 5000.
        var rejectBytes = baseBytes
        rejectBytes.append(Data([0xE8, 0x0E, 0x8E]))
        rejectBytes.append(fullChecksum.data(using: .utf8)!)
        rejectBytes.append(unknownAfterChecksum)
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(rejectBytes))

        let embedded: [[String: Any]] = [
            ["name": "valid_checksum_accepted",
             "description": "NON GET /a with addChecksumOnSend bytes decode OK",
             "bytes_hex": VectorWriter.hex(validBytes), "expect": "accept"],
            ["name": "corrupted_checksum_rejected",
             "description": "last checksum ASCII char flipped → checksumMismatch",
             "bytes_hex": VectorWriter.hex(corrupted), "expect": "reject"],
            ["name": "unknown_option_postdrop_checksum_accepted",
             "description": "unknown opt 5000 + checksum over post-drop bytes → accept",
             "bytes_hex": VectorWriter.hex(postdropBytes), "expect": "accept"],
            ["name": "unknown_option_full_bytes_checksum_rejected",
             "description": "unknown opt 5000 + checksum over full bytes → reject after drop",
             "bytes_hex": VectorWriter.hex(rejectBytes), "expect": "reject"],
        ]

        VectorWriter.emit(category: "checksum_option",
                          generator: "CoalaTests/VectorExtraction/SerializerFamilyVectorTests.swift",
                          cases: cases + embedded)
    }

    // MARK: block_option

    func testExtractBlockOptionVectors() {
        // swiftlint:disable:next large_tuple
        let specs: [(String, UInt, Bool, CoAPBlockOption.BlockSize)] = [
            ("num0_more_szx0", 0, true, .size16),
            ("num5_last_szx6", 5, false, .size1024),
            ("num15_more_szx3", 15, true, .size128),
            ("num2048_last_szx2", 2048, false, .size64),
        ]
        let cases: [[String: Any]] = specs.map { (name, num, m, szx) in
            let option = CoAPBlockOption(num: num, mFlag: m, szx: szx)
            return ["name": name,
                    "description": "num=\(num) m=\(m) szx=\(szx.value)",
                    "num": Int(num), "m": m, "szx": Int(szx.rawValue),
                    "value_hex": VectorWriter.hex(option.value.data)]
        }
        VectorWriter.emit(category: "block_option",
                          generator: "CoalaTests/VectorExtraction/SerializerFamilyVectorTests.swift",
                          cases: cases)
    }

    // MARK: udp_codec_lenient

    /// Decode-only acceptance cases (no idempotency guarantee): behaviors
    /// where Swift is more lenient than RFC 7252 or silently lossy.
    func testExtractLenientDecodeVectors() throws {
        let specs: [(String, String, [UInt8])] = [
            ("wrong_version_accepted", "version bits 0b10 are not validated",
             [0x84, 0x01, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0xDD, 0xB4, 0x74, 0x65, 0x73, 0x74]),
            ("trailing_ff_empty_payload", "0xFF marker with no payload bytes accepted",
             [0x40, 0x45, 0x00, 0x01, 0xFF]),
            ("unknown_option_dropped", "option 5000 silently dropped on decode",
             [0x50, 0x01, 0x00, 0x01, 0xB1, 0x61, 0xE1, 0x12, 0x70, 0xAA]),
        ]
        let cases: [[String: Any]] = try specs.map { (name, desc, bytes) in
            let message = try CoAPSerializer.coapMessageWithData(Data(bytes))
            return ["name": name, "description": desc,
                    "bytes_hex": VectorWriter.hex(Data(bytes)),
                    "message": [
                        "type": "\(message.type)",
                        "code": Int(message.code.rawValue),
                        "message_id": Int(message.messageId),
                        "token": VectorWriter.hex(message.token?.value ?? Data()),
                        "options": message.options.map {
                            ["number": Int($0.number.rawValue),
                             "value_hex": VectorWriter.hex($0.value.data)]
                        },
                        "payload_hex": VectorWriter.hex(message.payload?.data ?? Data()),
                    ] as [String: Any]]
        }
        VectorWriter.emit(category: "udp_codec_lenient",
                          generator: "CoalaTests/VectorExtraction/SerializerFamilyVectorTests.swift",
                          cases: cases)
    }

    // MARK: tcp_framing_stream

    /// Chunked-push sequences through the real stream decoder, recording the
    /// frames emitted after every push (resync, partial frames, multi-frame).
    func testExtractTcpStreamVectors() {
        let encoder = CoAPTcpSerializer()
        let frameA = encoder.encodeTcpFrame(with: Address(host: "1.2.3.4", port: 5683),
                                            data: Data([0x01, 0x02, 0x03]))
        let frameB = encoder.encodeTcpFrame(with: Address(host: "10.0.0.1", port: 80),
                                            data: Data())
        let frameC = encoder.encodeTcpFrame(with: Address(host: "1.2.3.4", port: 1),
                                            data: Data([0x4D, 0x02]))
        let specs: [(String, String, [Data])] = [
            ("garbage_then_frame", "3 non-delimiter bytes then a frame",
             [Data([0xDE, 0xAD, 0xBE]) + frameA]),
            ("frame_split_across_pushes", "split mid-header then mid-body",
             [Data(frameA.prefix(6)), frameA.subdata(in: 6..<10), Data(frameA.suffix(from: 10))]),
            ("garbage_without_delimiter_discarded", "delimiter-free push discarded, next frame OK",
             [Data([0x00, 0x11, 0x22]), frameA]),
            ("two_frames_one_push", "two back-to-back frames in one push",
             [frameA + frameB]),
            ("delimiter_byte_inside_body", "0x4D inside a body does not desync",
             [frameC + frameA]),
        ]
        let cases: [[String: Any]] = specs.map { (name, desc, chunks) in
            let decoder = CoAPTcpSerializer() // fresh state per case
            let framesPerPush: [[[String: Any]]] = chunks.map { chunk in
                decoder.decodeTcpFrame(with: chunk).map { frame in
                    ["host": frame.address.host, "port": Int(frame.address.port),
                     "message_hex": VectorWriter.hex(frame.data)]
                }
            }
            return ["name": name, "description": desc,
                    "chunks": chunks.map { VectorWriter.hex($0) },
                    "frames_after_each_push": framesPerPush]
        }
        VectorWriter.emit(category: "tcp_framing_stream",
                          generator: "CoalaTests/VectorExtraction/SerializerFamilyVectorTests.swift",
                          cases: cases)
    }
}
