//
//  CoAPRegistryCode.swift
//  Coala
//
//  Created by Roman on 23/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

public struct CoAPRegistryCode: ExpressibleByFloatLiteral, Equatable, CustomStringConvertible {

    let major: UInt8
    let minor: UInt8

    public init(floatLiteral value: Float) {
        let triple = Int(round(value * 100))
        self.major = UInt8(triple / 100)
        self.minor = UInt8(triple % 100)
    }

    init(integerValue: UInt8) {
        self.major = integerValue >> 5
        self.minor = integerValue & 0b11111
    }

    var integerValue: UInt8 {
        return (major & 0b111) << 5 | minor & 0b11111
    }

    public var description: String {
        return String(format: "%d.%02d", major, minor)
    }
}

public func == (lhs: CoAPRegistryCode, rhs: CoAPRegistryCode) -> Bool {
    return lhs.major == rhs.major && lhs.minor == rhs.minor
}
