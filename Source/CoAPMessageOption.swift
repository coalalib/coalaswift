//
//  CoAPMessageOption.swift
//  Coala
//
//  Created by Roman on 06/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

public protocol CoAPOptionValue {
    init(data: Data)
    var data: Data { get }
}

/// CoAP message option
/// as specified in [CoAP RFC](https://tools.ietf.org/html/rfc7252#section-5.10)
public struct CoAPMessageOption {

    /// CoAP message option number
    /// (see table in [CoAP RFC](https://tools.ietf.org/html/rfc7252#section-5.10))
    public enum Number: UInt16 {
        case ifMatch        = 1
        case uriHost        = 3
        case eTag           = 4
        case ifNoneMatch    = 5
        case observe        = 6
        case uriPort        = 7
        case locationPath   = 8
        case uriPath        = 11
        case contentFormat  = 12
        case maxAge         = 14
        case uriQuery       = 15
        case accept         = 17
        case locationQuery  = 20
        case block2         = 23
        case block1         = 27
        case proxyUri       = 35
        case proxyScheme    = 39
        case size1          = 60

        /// URI scheme options specifies scheme to be used for message transmission
        /// See `CoAPMessage.Scheme`. Scheme is stored using it's raw value
        case uriScheme      = 2111

        /// Handshake option is used by Coala library to detect handshake CoAP messages
        case handshakeType  = 3999

        /// Session Not Found option indicates to sender that peer has no active coaps:// session.
        /// Upon receiving the message with this option sender must restart the session
        case sessionNotFound = 4001

        /// Session expired option indicates that peer's coaps:// session expired
        /// Upon receiving the message with this option sender must restart the session
        case sessionExpired = 4003

        /// URI is stored in this option for coaps://
        case coapsUri = 4005

        /// Selective repeat option indicates that client knows how to handle ARQ algorithm with multiple blockise
        /// messages sent at once. Initiator of ARQ transfer passes selected sliding window size to the reciever
        case selectiveRepeatWindowSize = 3001
    }

    let number: Number
    let value: CoAPOptionValue

    var repeatable: Bool {
        switch self.number {
        case .ifMatch, .eTag, .locationPath, .uriPath, .uriQuery, .locationQuery:
            return true
        default:
            return false
        }
    }

    var critical: Bool {
        return CoAPMessageOption.isCritical(number: number.rawValue)
    }

    static func isCritical(number: UInt16) -> Bool {
        return number % 2 == 1
    }
}

extension UInt: CoAPOptionValue {
    public var data: Data {
        var integer = self.bigEndian
        let data =  Data(bytes: &integer, count: MemoryLayout<UInt>.size)
        let index = data.firstIndex(where: { $0 != 0 }) ?? data.endIndex
        return data.subdata(in: index..<data.endIndex)
    }

    public init(data: Data) {
        let zerosCount = MemoryLayout<UInt>.size - data.count
        guard zerosCount >= 0 else {
            self = UInt.max
            return
        }
        let zeros = Data(repeating: 0, count: zerosCount)
        var integer: UInt = 0
        let ptr = UnsafeMutableBufferPointer<UInt>(start: &integer, count: 1)
        _ = (zeros + data).copyBytes(to: ptr)
        self = integer.bigEndian
    }
}

extension String: CoAPOptionValue {
    public var data: Data {
        return self.data(using: .utf8) ?? Data()
    }

    public init(data: Data) {
        self = String(data: data, encoding: .utf8) ?? ""
    }
}

extension Data: CoAPOptionValue {
    public var data: Data {
        return self
    }

    public init(data: Data) {
        self = data
    }
}

extension Int: CoAPOptionValue {

    public var data: Data {
        return UInt(self).data
    }

    public init(data: Data) {
        self = Int(UInt(data: data))
    }
}

extension CoAPMessageOption: CustomStringConvertible {

    public var description: String {
        var description = "\(number)".components(separatedBy: ".").last!.capitalized
        if let string = String(data: value.data, encoding: .utf8), !string.isEmpty {
            description += " S:" + string
        }
        let uint = UInt(data: value.data)
        if uint != UInt.max {
            description += " U:\(uint)"
        }
        return description
    }
}
