//
//  CoAPToken.swift
//  Coala
//
//  Created by Roman on 21/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

struct CoAPToken {

    let value: Data
    static let maxLength = 8

    static func generate(length: Int = 4) -> CoAPToken {
        assert((1...CoAPToken.maxLength).contains(length))
        var rnd: UInt64 = 0
        arc4random_buf(&rnd, maxLength)
        let data = Data(bytes: &rnd, count: length)
        return CoAPToken(value: data)
    }

    var length: Int {
        return value.count
    }
}

extension CoAPToken: Equatable { }

func == (lhs: CoAPToken, rhs: CoAPToken) -> Bool {
    return lhs.value == rhs.value
}

extension CoAPToken: Hashable {

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }

}

extension CoAPToken: CustomStringConvertible {
    var description: String {
        return value.hexDescription
    }
}
