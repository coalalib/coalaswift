//
//  CoAPSerializer.swift
//  Coala
//
//  Created by Roman on 06/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

/*
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |Ver| T |  TKL  |      Code     |          Message ID           |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |   Token (if any, TKL bytes) ...
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |   Options (if any) ...
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |1 1 1 1 1 1 1 1|    Payload (if any) ...
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

 Figure 7: Message Format
 https://tools.ietf.org/html/rfc7252#section-3
*/

/*
 0   1   2   3   4   5   6   7
 +---------------+---------------+
 |               |               |
 |  Option Delta | Option Length |   1 byte
 |               |               |
 +---------------+---------------+
 \                               \
 /         Option Delta          /   0-2 bytes
 \          (extended)           \
 +-------------------------------+
 \                               \
 /         Option Length         /   0-2 bytes
 \          (extended)           \
 +-------------------------------+
 \                               \
 /                               /
 \                               \
 /         Option Value          /   0 or more bytes
 \                               \
 /                               /
 \                               \
 +-------------------------------+

 Figure 8: Option Format
 https://tools.ietf.org/html/rfc7252#section-3.1
*/

final class CoAPSerializer {

    static let CoAPVersion: UInt8 = 0b01

    enum SerializationError: Error {
        case wrongTokenLength, optionValueTooLong
    }

    typealias OptionField = (halfByte: UInt8, extendedData: Data)
    class func optionFieldWithValue(_ value: UInt16) -> OptionField {
        var halfByte: UInt8 = 0
        let extendedData = NSMutableData()
        switch value {
        case 0 ... 12:
            halfByte = UInt8(value)
        case 13 ... 269:
            halfByte = 13
            var numberMinus13 = value - 13
            extendedData.append(&numberMinus13, length: 1)
        default:
            halfByte = 14
            var numberMinus269 = CFSwapInt16HostToBig(value - 269)
            extendedData.append(&numberMinus269, length: 2)
        }
        return (halfByte: halfByte, extendedData: extendedData as Data)
    }

    class func getOptionFieldValue(_ halfByte: UInt8, data: Data, pos: inout Int) throws -> UInt16 {
        let remainingLength = data.count - pos
        switch halfByte {
        case 0 ... 12:
            return UInt16(halfByte)
        case 13:
            guard remainingLength >= 1 else { throw DeserializationError.optionFormat }
            let byte = data.readBytesAt(&pos, length: 1)[0]
            return UInt16(byte) + 13
        case 14:
            guard remainingLength >= 2 else { throw DeserializationError.optionFormat }
            var value = UInt16(0)
            let extendedData = data.readDataAt(&pos, length: 2)
            (extendedData as NSData).getBytes(&value, length: 2)
            // Spec value of "extended (14)" is raw + 269. The sum overflows
            // UInt16 once raw > 65266; treat any out-of-range value as a
            // malformed option rather than letting the addition trap.
            let total = UInt32(CFSwapInt16BigToHost(value)) + 269
            guard total <= UInt32(UInt16.max) else { throw DeserializationError.optionFormat }
            return UInt16(total)
        default:
            throw DeserializationError.optionFormat
        }
    }

    class func dataWithCoAPMessage(_ message: CoAPMessage, addChecksumIfNeeded: Bool = false) throws -> Data {
        var message = message
        if addChecksumIfNeeded && message.addChecksumOnSend {
            let checksum = try checksumForMessage(message)
            message.setOption(.checksum, value: checksum)
        }

        let data = NSMutableData()

        let ver = CoAPSerializer.CoAPVersion
        let t = message.type.rawValue
        let tkl = message.token?.length ?? 0
        if tkl > 8 {
            throw SerializationError.wrongTokenLength
        }
        let byte1 = (ver << 6) | (t << 4) | UInt8(tkl)
        let byte2 = message.code.rawValue
        let byte3 = UInt8(message.messageId >> 8)
        let byte4 = UInt8(message.messageId & 0xFF)
        var firstLine = [byte1, byte2, byte3, byte4]
        data.append(&firstLine, length: 4)

        if let token = message.token {
            data.append(token.value)
        }

        let sortedOptions = message.options.sorted {
            $0.number.rawValue < $1.number.rawValue
        }

        var previousDelta = UInt16(0)
        for option in sortedOptions {
            let size = option.value.data.count
            if size > Int(UInt16.max) {
                throw SerializationError.optionValueTooLong
            }

            let optionLength = UInt16(size)
            let optionDelta = option.number.rawValue - previousDelta
            previousDelta += optionDelta

            let delta = optionFieldWithValue(optionDelta)
            let length = optionFieldWithValue(optionLength)

            var firstByte = delta.halfByte << 4 | length.halfByte
            data.append(&firstByte, length: 1)
            data.append(delta.extendedData)
            data.append(length.extendedData)
            data.append(option.value.data)
        }

        if let payload = message.payload, payload.data.count > 0 {
            var payloadMarker: UInt8 = 0xFF
            data.append(&payloadMarker, length: 1)
            data.append(payload.data)
        }

        return (NSData(data: data as Data) as Data)
    }

    enum DeserializationError: Error {
        case headerTooShort, unknownCode, optionFormat
        case wrongTokenLength, tokenTooShort
        case checksumMismatch
    }

    class func coapMessageWithData(_ data: Data) throws -> CoAPMessage {
        var pos = 0
        guard data.count >= 4 else { throw DeserializationError.headerTooShort }
        let header = data.readBytesAt(&pos, length: 4)
        let t = UInt8(header[0] >> 4 & 0b11)
        guard let
            type = CoAPMessage.Reliability(rawValue: t),
            let code = CoAPMessage.Code(rawValue: header[1])
            else { throw DeserializationError.unknownCode }

        let messageId = UInt16(header[2]) << 8 | UInt16(header[3])
        var message = CoAPMessage(type: type, code: code, messageId: messageId)

        let tkl = Int(header[0] & 0xF)
        // RFC 7252 §3: TKL values 9..15 are reserved and MUST NOT be sent.
        // The decoder must reject them rather than try to read 9..15 token
        // bytes from an attacker-supplied frame.
        guard tkl <= 8 else { throw DeserializationError.wrongTokenLength }
        // Bounds-check the token read explicitly: readDataAt traps via
        // subdata(in:) when the buffer is shorter than 4 + tkl.
        guard pos + tkl <= data.count else { throw DeserializationError.tokenTooShort }
        message.token = tkl > 0 ? CoAPToken(value: data.readDataAt(&pos, length: tkl)) : nil

        var previousDelta: UInt16 = 0
        var payloadData: Data?
        while pos < data.count {
            let firstByte = data.readBytesAt(&pos, length: 1)[0]
            guard firstByte != 0xFF else {
                payloadData = data.remainingData(since: pos)
                break
            }
            let deltaHalfByte = firstByte >> 4
            let lengthHalfByte = firstByte & 0b1111
            let delta = try getOptionFieldValue(deltaHalfByte, data: data, pos: &pos)
            let length = try Int(getOptionFieldValue(lengthHalfByte, data: data, pos: &pos))

            guard pos + length <= data.count else {
              throw DeserializationError.optionFormat
            }

            let optionValue = data.readDataAt(&pos, length: length)
            // Cumulative delta is also a UInt16 sum that must not trap.
            let (cumulativeDelta, overflow) = previousDelta.addingReportingOverflow(delta)
            guard !overflow else { throw DeserializationError.optionFormat }
            if let optionNumber = CoAPMessageOption.Number(rawValue: cumulativeDelta) {
                message.setOption(optionNumber, value: optionValue)
            }
            previousDelta = cumulativeDelta
        }

        message.payload = payloadData
        try verifyChecksumIfPresent(in: message)
        return message
    }

    class func checksumForMessage(_ message: CoAPMessage) throws -> String {
        var checksumMessage = message
        checksumMessage.removeOption(.checksum)
        let data = try dataWithCoAPMessage(checksumMessage)
        return String(format: "%08x", data.crc32IEEE)
    }

    private class func verifyChecksumIfPresent(in message: CoAPMessage) throws {
        guard let expected = message.getStringOptions(.checksum).first else { return }
        let computed = try checksumForMessage(message)
        guard expected.lowercased() == computed else {
            throw DeserializationError.checksumMismatch
        }
    }

}

extension Data {
    func readDataAt(_ pos: inout Int, length: Int) -> Data {
        let data = subdata(in: pos ..< pos + length)
        pos += length
        return data
    }

    func readBytesAt(_ pos: inout Int, length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        (data as NSData).getBytes(&bytes, range: NSRange(location: pos, length: length))
        pos += length
        return bytes
    }

    func readBytesIfPossible(pos: inout Int, length: Int) -> [UInt8]? {
        guard pos + length < count else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        (data as NSData).getBytes(&bytes, range: NSRange(location: pos, length: length))
        pos += length
        return bytes
    }

    func remainingData(since pos: Int, noLongerThan limit: Int? = nil) -> Data {
        var length = data.count - pos
        if let limit = limit, limit < length {
            length = limit
        }
        return data.subdata(in: pos ..< pos + length)
    }

    var crc32IEEE: UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }
}
