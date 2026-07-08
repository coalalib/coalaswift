import Foundation
import XCTest
@testable import Coala

/// Extracts UDP serializer vectors: header/type/code permutations, token
/// lengths, option encodings across the registry, payload marker. Each case
/// records the structured message plus the exact bytes CoAPSerializer emits.
final class UDPCodecVectorTests: XCTestCase {

    private struct Spec {
        let name: String
        let description: String
        let type: CoAPMessage.Reliability
        let code: CoAPMessage.Code
        let messageId: UInt16
        let token: [UInt8]
        let options: [(CoAPMessageOption.Number, Data)]
        let payload: Data
    }

    func testExtractUDPCodecVectors() throws {
        let specs: [Spec] = [
            Spec(name: "con_get_uri_path",
                 description: "CON GET /test, token AABBCCDD, id 0x1234",
                 type: .confirmable, code: .request(.get), messageId: 0x1234,
                 token: [0xAA, 0xBB, 0xCC, 0xDD],
                 options: [(.uriPath, "test".data(using: .utf8)!)],
                 payload: Data()),
            Spec(name: "ack_content_payload",
                 description: "ACK 2.05, token AABBCCDD, payload 'hi'",
                 type: .acknowledgement, code: .response(.content), messageId: 0x1234,
                 token: [0xAA, 0xBB, 0xCC, 0xDD],
                 options: [],
                 payload: "hi".data(using: .utf8)!),
            Spec(name: "non_empty_token",
                 description: "NON GET, zero-length token",
                 type: .nonConfirmable, code: .request(.get), messageId: 0x0001,
                 token: [],
                 options: [(.uriPath, "a".data(using: .utf8)!)],
                 payload: Data()),
            Spec(name: "extended_delta_and_length",
                 description: "option 60 (Size1) forces delta-13; 300-byte value forces length-14",
                 type: .nonConfirmable, code: .response(.content), messageId: 7,
                 token: [0x01],
                 options: [(.uriPath, "a".data(using: .utf8)!),
                           (.size1, Data(repeating: 0x5A, count: 300))],
                 payload: "x".data(using: .utf8)!),
            Spec(name: "repeated_uri_path",
                 description: "multi-segment path: two Uri-Path (11) options, order load-bearing",
                 type: .confirmable, code: .request(.get), messageId: 42,
                 token: [0x01, 0x02],
                 options: [(.uriPath, "first".data(using: .utf8)!),
                           (.uriPath, "second".data(using: .utf8)!)],
                 payload: Data()),
            Spec(name: "custom_option_uri_scheme",
                 description: "NDM custom option uriScheme (2111) = coapSecure raw value",
                 type: .confirmable, code: .request(.post), messageId: 0x00FF,
                 token: [0x09],
                 options: [(.uriScheme, UInt(1).data)],
                 payload: Data()),
        ]

        let cases: [[String: Any]] = try specs.map { spec in
            var message = CoAPMessage(type: spec.type, code: spec.code, messageId: spec.messageId)
            message.addChecksumOnSend = false
            if !spec.token.isEmpty {
                message.token = CoAPToken(value: Data(spec.token))
            }
            for (number, value) in spec.options {
                message.setOption(number, value: value)
            }
            if !spec.payload.isEmpty {
                message.payload = spec.payload
            }
            let bytes = try CoAPSerializer.dataWithCoAPMessage(message)

            let optionJSON: [[String: Any]] = spec.options.map {
                ["number": Int($0.0.rawValue), "value_hex": VectorWriter.hex($0.1)]
            }
            return [
                "name": spec.name,
                "description": spec.description,
                "message": [
                    "type": spec.type.description,          // CON/NON/ACK/RST
                    "code": Int(spec.code.rawValue),        // raw u8
                    "message_id": Int(spec.messageId),
                    "token": VectorWriter.hex(Data(spec.token)),
                    "options": optionJSON,
                    "payload_hex": VectorWriter.hex(spec.payload),
                ],
                "bytes_hex": VectorWriter.hex(bytes),
            ]
        }

        VectorWriter.emit(category: "udp_codec",
                          generator: "CoalaTests/VectorExtraction/UDPCodecVectorTests.swift",
                          cases: cases)
    }
}
