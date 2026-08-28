//
//  LogLayer.swift
//  Coala
//
//  Created by Roman on 11/01/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

final class LogLayer: InLayer, OutLayer {

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        Self.logSingle(message: message, toAddr: toAddress, fromAddr: nil)
    }

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        Self.logSingle(message: message, toAddr: nil, fromAddr: fromAddress)
    }

    /// One line per CoAP message on the wire, at `.debug`.
    ///
    /// `static` because the layer holds no state: `SecurityLayer` logs the inbound
    /// handshake GET itself — that path throws `handshakeInProgress` before the
    /// stack reaches `LogLayer` — and did so through a throwaway instance.
    static func logSingle(message: CoAPMessage, toAddr: Address?, fromAddr: Address?) {
        var logMessage = ""
        if let toAddr = toAddr {
            logMessage = "Sending message: \(message.longDescription) to: \(toAddr)"
        } else if let fromAddr = fromAddr {
            logMessage = "Receiving message: \(message.longDescription) from: \(fromAddr)"
        }
        if let proxyAddress = message.proxyViaAddress {
            logMessage += " via proxy \(proxyAddress)"
        }
        LogDebug(logMessage, asynchronous: false)
    }
}

extension CoAPMessage {

    var shortDescription: String {
        var description = "\(type) \(code) [id\(messageId)]"
        if self.scheme == .coapSecure {
            description = "$ " + description
        }
        if isRequest {
            let path = "/" + getStringOptions(.uriPath).joined(separator: "/")
            description += " \(path)"
            if let query = url?.query {
                description += "?\(query)"
            }
        }
        if let block1Option = block1Option {
            description += ", 1:\(block1Option)"
        }
        if let block2Option = block2Option {
            description += ", 2:\(block2Option)"
        }
        if let payload = payload {
            description += ", [\(payload.data.count)b]"
        }
        return description
    }

    var longDescription: String {
        var description = shortDescription
        if let token = token {
            description += " TOKEN:\(token.value.hexDescription)"
        }
        if let payloadString = payload?.string, !payloadString.isEmpty {
            description += " PAYLOAD:\(payloadString)"
        } else if let bytes = payload?.data.count, bytes > 0 {
            description += " PAYLOAD of <\(bytes)b>"
        }
        description += " OPTIONS:[" + options.map({ "\($0)" }).joined(separator: ", ") + "]"
        return description
    }

}
