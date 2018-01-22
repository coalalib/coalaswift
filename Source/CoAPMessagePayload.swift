//
//  CoAPMessagePayload.swift
//  Coala
//
//  Created by Roman on 06/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

/// CoAP message payload, can be represented either as a `Data` or a `String`
public protocol CoAPMessagePayload {
    var data: Data { get }
    var string: String { get }
}

extension Data: CoAPMessagePayload {
    public var string: String {
        return String(data: self)
    }
}

extension String: CoAPMessagePayload {
    public var string: String {
        return self
    }
}
