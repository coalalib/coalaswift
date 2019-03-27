//
//  Address.swift
//  Coala
//
//  Created by Roman on 21/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

/// Represents endpoint address as a host:port
public struct Address {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    init?(addressData: Data) {
        let port = GCDAsyncUdpSocket.port(fromAddress: addressData)
        guard let host = GCDAsyncUdpSocket.host(fromAddress: addressData), port != 0
            else { return nil }
        self.host = host
        self.port = port
    }

    public init?(string: String) {
        let addressComps = string.components(separatedBy: ":")
        guard addressComps.count == 2,
            let port = UInt16(addressComps[1])
            else { return nil }
        self.host = addressComps[0]
        self.port = port
    }

    public init?(url: URL?) {
        guard let host = url?.host, let port = url?.port else { return nil }
        self.host = host
        self.port = UInt16(port)
    }
}

extension Address: CustomStringConvertible {
    public var description: String {
        return "\(host):\(port)"
    }
}

extension Address: Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(port)
    }

}

extension Address {
    public func urlForScheme(scheme: CoAPMessage.Scheme) -> URL? {
        var components = URLComponents()
        components.scheme = scheme.string
        components.host = host
        components.port = Int(port)
        return components.url
    }
}

public func == (lhs: Address, rhs: Address) -> Bool {
    return lhs.host == rhs.host && lhs.port == rhs.port
}
