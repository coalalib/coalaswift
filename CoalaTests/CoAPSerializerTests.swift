//
//  CoAPSerializerTests.swift
//  Coala
//
//  Created by Roman on 07/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

// swiftlint:disable type_body_length
class CoAPSerializerTests: XCTestCase {

    private func roundTripMessage(payload: CoAPMessagePayload) throws -> CoAPMessage {
        var message = CoAPMessage(type: .confirmable, method: .post)
        message.payload = payload
        let serializedData = try CoAPSerializer.dataWithCoAPMessage(message)
        return try CoAPSerializer.coapMessageWithData(serializedData)
    }

    private func assertStringPayloadRoundTrips(_ payload: String,
                                               _ description: String,
                                               file: StaticString = #file,
                                               line: UInt = #line) {
        do {
            let deserializedMessage = try roundTripMessage(payload: payload)
            XCTAssertEqual(payload.data(using: .utf8), deserializedMessage.payload?.data, description, file: file, line: line)
            XCTAssertEqual(payload, deserializedMessage.payload?.string, description, file: file, line: line)
        } catch {
            XCTFail("\(description): \(error)", file: file, line: line)
        }
    }

    private func assertDataPayloadRoundTrips(_ payload: Data,
                                             _ description: String,
                                             file: StaticString = #file,
                                             line: UInt = #line) {
        do {
            let deserializedMessage = try roundTripMessage(payload: payload)
            XCTAssertEqual(payload, deserializedMessage.payload?.data, description, file: file, line: line)
        } catch {
            XCTFail("\(description): \(error)", file: file, line: line)
        }
    }

    func testConPostSerialization() {
        let message = CoAPMessage(type: .confirmable, method: .post)
        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testNonGetSerialization() {
        let message = CoAPMessage(type: .nonConfirmable, method: .get)
        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testAckContentSerialization() {
        let message = CoAPMessage(type: .acknowledgement, code: .response(.content))
        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testOptionFieldConversion() {
        for number in [UInt16]([0, 9, 13, 268, 270, 1024, 65535]) {
            let optionField = CoAPSerializer.optionFieldWithValue(number)
            var pos = 0
            let value = try? CoAPSerializer.getOptionFieldValue(optionField.halfByte,
                                                                data: optionField.extendedData,
                                                                pos: &pos)
            XCTAssertEqual(number, value)
        }
    }

    func testLongOptionOverflow() {
        var message = CoAPMessage(type: .nonConfirmable, method: .get)
        let overflowString = String(repeating: "#", count: 65536)
        message.setOption(.contentFormat, value: overflowString)
        do {
            _ = try CoAPSerializer.dataWithCoAPMessage(message)
        } catch let error {
            let serializationError = error as? CoAPSerializer.SerializationError
            XCTAssertEqual(serializationError, .optionValueTooLong)
            return
        }
        XCTAssert(false)
    }

    func testChecksumOptionIsVerifiedWhenValid() {
        var message = CoAPMessage(type: .confirmable, method: .post)
        message.token = CoAPToken(value: Data([0x01, 0x02, 0x03]))
        message.payload = "checksum payload"

        guard let checksum = try? CoAPSerializer.checksumForMessage(message) else {
            XCTFail("Failed to calculate checksum")
            return
        }
        message.setOption(.checksum, value: checksum)

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(deserializedMessage.getStringOptions(.checksum), [checksum])
        XCTAssertEqual(deserializedMessage.payload?.string, "checksum payload")
    }

    func testChecksumOptionMismatchIsRejected() {
        var message = CoAPMessage(type: .confirmable, method: .post)
        message.payload = "checksum payload"
        message.setOption(.checksum, value: "00000000")

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message) else {
            XCTFail("Failed to serialize message")
            return
        }

        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(serializedData)) { error in
            let deserializationError = error as? CoAPSerializer.DeserializationError
            XCTAssertEqual(deserializationError, .checksumMismatch)
        }
    }

    func testChecksumOptionIsAddedWhenSendFlagIsEnabled() {
        var message = CoAPMessage(type: .confirmable, method: .post)
        message.token = CoAPToken(value: Data([0x01, 0x02, 0x03]))
        message.payload = "checksum payload"
        message.addChecksumOnSend = true

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }

        let checksums = deserializedMessage.getStringOptions(.checksum)
        XCTAssertEqual(checksums.count, 1)
        XCTAssertEqual(checksums.first, try? CoAPSerializer.checksumForMessage(deserializedMessage))
        XCTAssertEqual(deserializedMessage.payload?.string, "checksum payload")
    }

    func testUrlSerialization() {
        let url = URL(string: "coap://10.70.10.70:5544/method?query=2")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            var deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        deserializedMessage.address = message.address
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
        XCTAssertEqual(message.url, deserializedMessage.url)
    }

    func testUrlQuerySerialization() {
        let url = URL(string: "coap://10.70.10.70:5544/method/submethod?query1=2&query2=abc")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            var deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        deserializedMessage.address = message.address
        XCTAssertEqual(message.url, deserializedMessage.url)
        XCTAssertEqual(deserializedMessage.getOptions(.uriPath).count, 2)
        XCTAssertEqual(deserializedMessage.getOptions(.uriPath)[0].data.string, "method")
        XCTAssertEqual(deserializedMessage.getOptions(.uriPath)[1].data.string, "submethod")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery).count, 2)
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[0].data.string, "query1=2")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[1].data.string, "query2=abc")
    }

    func testToken() {
        let url = URL(string: "coap://10.70.10.70:5544/method?query=2")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        message.token = CoAPToken(value: "123".data)
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testTooLongToken() {
        let url = URL(string: "coap://10.70.10.70:5544/method?query=2")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        message.token = CoAPToken(value: "veryverylongtoken".data)
        do {
            _ = try CoAPSerializer.dataWithCoAPMessage(message)
        } catch let error {
            let serializeError = error as? CoAPSerializer.SerializationError
            XCTAssertEqual(serializeError, .wrongTokenLength)
            return
        }
        XCTAssert(false)
    }

    func testSpecialChars() {
        let url = URL(string: "coap://10.70.10.70:5544/method/submethod")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        message.query = [
            URLQueryItem(name: "at", value: "@"),
            URLQueryItem(name: "quest", value: "?"),
            URLQueryItem(name: "amp", value: "&"),
            URLQueryItem(name: "perc", value: "%"),
            URLQueryItem(name: "plus", value: "+")
        ]
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            var deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        deserializedMessage.address = message.address
        let expectedURL = "coap://10.70.10.70:5544/method/submethod?at=@&quest=?&amp=%26&perc=%25&plus=%2b"
        XCTAssertEqual(message.url?.absoluteString, expectedURL)
        XCTAssertEqual(message.url, deserializedMessage.url)
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery).count, 5)
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[0].data.string, "at=@")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[1].data.string, "quest=?")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[2].data.string, "amp=&")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[3].data.string, "perc=%")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[4].data.string, "plus=+")
    }

    func testPayloadSpecialCharsSerialization() {
        var message = CoAPMessage(type: .confirmable, method: .post)
        message.payload = "line1\nline2\t!@#$%^&*()_+-=[]{}|;':\",./<>?~"

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }

        XCTAssertEqual(message.payload?.data, deserializedMessage.payload?.data)
        XCTAssertEqual(message.payload?.string, deserializedMessage.payload?.string)
    }

    func testPayloadUnicodeAndControlCharsSerialization() {
        let payload = "Привет\nこんにちは\temoji: 😀\u{0}combining: e\u{301}"
        var message = CoAPMessage(type: .confirmable, method: .post)
        message.payload = payload

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }

        let expectedData = payload.data(using: .utf8)
        XCTAssertEqual(expectedData, deserializedMessage.payload?.data)
        XCTAssertEqual(payload, deserializedMessage.payload?.string)
    }

    func testPayloadJSONLikeSpecialCharsSerialization() {
        let payload = "{\"text\":\"quotes: \\\" slash: \\\\ newline: \\n tab: \\t percent: % amp: & plus: + question: ?\"}"
        var message = CoAPMessage(type: .nonConfirmable, method: .post)
        message.payload = payload

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }

        XCTAssertEqual(payload.data(using: .utf8), deserializedMessage.payload?.data)
        XCTAssertEqual(payload, deserializedMessage.payload?.string)
    }

    func testPayloadCanContainPayloadMarkerByte() {
        var message = CoAPMessage(type: .nonConfirmable, method: .post)
        message.payload = Data([0xFF, 0x00, 0x41, 0xFF, 0x42])

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }

        XCTAssertEqual(message.payload?.data, deserializedMessage.payload?.data)
    }

    func testPayloadAllByteValuesSerialization() {
        let payload = Data((0...255).map { UInt8($0) })
        assertDataPayloadRoundTrips(payload, "all byte values 0x00...0xFF")
    }

    func testPayloadAllASCIICharactersSerialization() {
        let payload = (0...127).reduce("") { result, value in
            result + String(UnicodeScalar(value)!)
        }
        assertStringPayloadRoundTrips(payload, "all ASCII scalars U+0000...U+007F")
    }

    func testPayloadASCIIControlCharactersIndividually() {
        let controlScalars = Array(0...31) + [127]
        for value in controlScalars {
            let payload = String(UnicodeScalar(value)!)
            let hex = String(format: "U+%04X", value)
            assertStringPayloadRoundTrips(payload, "ASCII control scalar \(hex)")
        }
    }

    func testPayloadPrintableSpecialCharactersIndividually() {
        let payloads = [
            " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
            ":", ";", "<", "=", ">", "?", "@", "[", "\\", "]", "^", "_", "`", "{", "|", "}", "~"
        ]

        for payload in payloads {
            let scalarValue = payload.unicodeScalars.first!.value
            let hex = String(format: "U+%04X", scalarValue)
            assertStringPayloadRoundTrips(payload, "printable special scalar \(hex)")
        }
    }

    func testPayloadUnicodeSpecialCharactersIndividually() {
        let payloads = [
            "\u{00A0}", // no-break space
            "\u{00AD}", // soft hyphen
            "\u{034F}", // combining grapheme joiner
            "\u{061C}", // Arabic letter mark
            "\u{1680}", // ogham space mark
            "\u{180E}", // Mongolian vowel separator
            "\u{2000}", // en quad
            "\u{2001}", // em quad
            "\u{2002}", // en space
            "\u{2003}", // em space
            "\u{2004}", // three-per-em space
            "\u{2005}", // four-per-em space
            "\u{2006}", // six-per-em space
            "\u{2007}", // figure space
            "\u{2008}", // punctuation space
            "\u{2009}", // thin space
            "\u{200A}", // hair space
            "\u{200B}", // zero width space
            "\u{200C}", // zero width non-joiner
            "\u{200D}", // zero width joiner
            "\u{200E}", // left-to-right mark
            "\u{200F}", // right-to-left mark
            "\u{2028}", // line separator
            "\u{2029}", // paragraph separator
            "\u{202A}", // left-to-right embedding
            "\u{202B}", // right-to-left embedding
            "\u{202C}", // pop directional formatting
            "\u{202D}", // left-to-right override
            "\u{202E}", // right-to-left override
            "\u{202F}", // narrow no-break space
            "\u{205F}", // medium mathematical space
            "\u{2060}", // word joiner
            "\u{2066}", // left-to-right isolate
            "\u{2067}", // right-to-left isolate
            "\u{2068}", // first strong isolate
            "\u{2069}", // pop directional isolate
            "\u{3000}", // ideographic space
            "\u{FEFF}", // byte order mark
            "\u{FFFD}"  // replacement character
        ]

        for payload in payloads {
            let scalarValue = payload.unicodeScalars.first!.value
            let hex = String(format: "U+%04X", scalarValue)
            assertStringPayloadRoundTrips(payload, "Unicode special scalar \(hex)")
        }
    }

    func testPayloadComplexUnicodeSequencesSerialization() {
        let payloads = [
            "e\u{301}",
            "👨‍👩‍👧‍👦",
            "🏳️‍🌈",
            "🇺🇸",
            "क्‍ष",
            "עברית بالعربية",
            "quotes “ ” ‘ ’ guillemets « »",
            "math ∑ ∆ √ ∞ ≈ ≠ ≤ ≥",
            "currency ₽ € ¥ £ ₿",
            "emoji 😀😈🤷🏽‍♂️"
        ]

        for payload in payloads {
            assertStringPayloadRoundTrips(payload, "complex Unicode payload \(payload)")
        }
    }

    func testBinaryPayloadSerialization() {
        var message = CoAPMessage(type: .nonConfirmable, method: .post)
        message.payload = Data([0x00, 0x0A, 0xFF, 0x41, 0x7F])

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }

        XCTAssertEqual(message.payload?.data, deserializedMessage.payload?.data)
    }

    func testTruncatedOptionValueDeserialization() {
        let malformedPacket = Data([
            0x50, // ver=1, non-confirmable, no token
            0x01, // GET
            0x00, 0x01,
            0xB5, // delta=11 (uriPath), length=5
            0x61, 0x62, 0x63 // only 3 bytes instead of 5
        ])

        do {
            _ = try CoAPSerializer.coapMessageWithData(malformedPacket)
        } catch let error {
            let deserializationError = error as? CoAPSerializer.DeserializationError
            XCTAssertEqual(deserializationError, .optionFormat)
            return
        }

        XCTAssert(false)
    }

    // MARK: - Malformed-input safety (KMA crash regression suite)
    // These packets reproduce crashes seen in production via
    // CoAPSerializer.coapMessageWithData. Each crafted packet must be
    // *rejected*, never trap the process.

    func testMalformedPacketWithTKL1ButNoTokenIsRejected() {
        // ver=1, T=0, TKL=1, code=GET, mid=0x0001 — total 4 bytes
        // Bug 1 reproducer: header advertises a 1-byte token, none is present.
        let malformedPacket = Data([0x41, 0x01, 0x00, 0x01])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(malformedPacket))
    }

    func testMalformedPacketWithTKL8ButMissingBytesIsRejected() {
        // ver=1, T=0, TKL=8 (max legal), code=GET, mid=0x0002, only 4 token bytes
        let malformedPacket = Data([
            0x48, 0x01, 0x00, 0x02,
            0xAA, 0xBB, 0xCC, 0xDD
        ])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(malformedPacket))
    }

    func testReservedTokenLength9IsRejected() {
        // ver=1, T=0, TKL=9 — RFC 7252 §3 reserved range (9..15 illegal).
        // Includes 9 trailing bytes so the bounds guard alone is satisfied;
        // rejection must come from validating the reserved TKL value itself.
        let malformedPacket = Data([
            0x49, 0x01, 0x00, 0x03,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09
        ])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(malformedPacket))
    }

    func testReservedTokenLength15IsRejected() {
        // ver=1, T=0, TKL=15 (worst reserved value), 15 trailing bytes provided.
        let malformedPacket = Data([
            0x4F, 0x01, 0x00, 0x04,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
        ])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(malformedPacket))
    }

    func testValidTokenLength8RoundTrips() {
        // Regression guard for the TKL guard: maximum legal TKL must still work.
        let url = URL(string: "coap://10.70.10.70:5544/")
        var message = CoAPMessage(type: .confirmable, method: .get, url: url)
        message.token = CoAPToken(value: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))

        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
              let deserialized = try? CoAPSerializer.coapMessageWithData(serializedData)
        else {
            XCTFail("TKL=8 round trip failed to serialize/deserialize")
            return
        }
        XCTAssertEqual(message.token, deserialized.token)
        XCTAssertEqual(message.token?.length, 8)
    }

    func testMalformedOptionLengthExtendedOverflowIsRejected() {
        // Bug 2 reproducer: option length nibble = 14 (extended 16-bit),
        // raw extended value 0xFFFF → 0xFFFF + 269 overflows UInt16 → trap on
        // unfixed code. Trailing bytes intentionally insufficient.
        // ver=1, T=0, TKL=0, code=GET, mid=0x0005
        // option byte: delta=0 (low option number), length=14 → 0x0E
        // length extension: 0xFF 0xFF
        // (no option value bytes — length 65804 is unsatisfiable anyway)
        let malformedPacket = Data([
            0x40, 0x01, 0x00, 0x05,
            0x0E, 0xFF, 0xFF
        ])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(malformedPacket))
    }

    func testMalformedOptionDeltaExtendedOverflowIsRejected() {
        // Symmetric to length-overflow but on the delta nibble.
        // delta nibble = 14, raw extended value 0xFFFF, length nibble = 0.
        let malformedPacket = Data([
            0x40, 0x01, 0x00, 0x06,
            0xE0, 0xFF, 0xFF
        ])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(malformedPacket))
    }

    func testMalformedCumulativeOptionDeltaOverflowIsRejected() {
        // Two options each with extended delta = 0x8000 + 269 = 33037.
        // Cumulative delta after two iterations = 66074 > UInt16.max → trap on
        // unfixed code at `previousDelta += delta`.
        // Each option uses delta-nibble=14, length-nibble=0, two 0x80 0x00 bytes.
        // ver=1, T=0, TKL=0, code=GET, mid=0x0007
        let malformedPacket = Data([
            0x40, 0x01, 0x00, 0x07,
            0xE0, 0x80, 0x00,
            0xE0, 0x80, 0x00
        ])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(malformedPacket))
    }

    func testMinimalEmptyMessageDeserializes() {
        // Sanity: 4-byte minimal valid packet (no token, no options, no payload)
        // must continue to parse cleanly after the fix.
        let validPacket = Data([0x40, 0x01, 0x00, 0x08])
        XCTAssertNoThrow(try CoAPSerializer.coapMessageWithData(validPacket))
    }

    func testEmptyPacketIsRejected() {
        // Below the 4-byte header minimum — must throw, never trap.
        let emptyPacket = Data()
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(emptyPacket))
    }

    func testShortPacketBelowHeaderIsRejected() {
        // 3 bytes — header is 4 bytes minimum.
        let shortPacket = Data([0x40, 0x01, 0x00])
        XCTAssertThrowsError(try CoAPSerializer.coapMessageWithData(shortPacket))
    }
}
// swiftlint:enable type_body_length
