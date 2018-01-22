//
//  LogLayer.swift
//  Coala
//
//  Created by Roman on 11/01/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

class LogLayer: InLayer, OutLayer {

    var visual = false

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        if visual {
            logDiagram(message: message, toAddr: toAddress, fromAddr: nil)
        } else {
            logSingle(message: message, toAddr: toAddress, fromAddr: nil)
        }
    }

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        if visual {
            logDiagram(message: message, toAddr: nil, fromAddr: fromAddress)
        } else {
            logSingle(message: message, toAddr: nil, fromAddr: fromAddress)
        }
    }

    func logSingle(message: CoAPMessage, toAddr: Address?, fromAddr: Address?) {
        var logMessage = ""
        if let toAddr = toAddr {
            logMessage = "Sending message: \(message.longDescription) to: \(toAddr)"
        } else if let fromAddr = fromAddr {
            logMessage = "Receiving message: \(message.longDescription) from: \(fromAddr)"
        }
        if let proxyAddress = message.proxyViaAddress {
            logMessage += " via proxy \(proxyAddress)"
        }
        let isFinalBlock1 = message.block1Option?.mFlag == false
        let isFinalBlock2 = message.block2Option?.mFlag == false && message.isResponse
        let isFinalBlock = isFinalBlock1 || isFinalBlock2
        if let blockOption = message.block2Option ?? message.block1Option, blockOption.num > 0 && !isFinalBlock {
            LogDebug(logMessage, asynchronous: false)
        } else {
            LogInfo(logMessage, asynchronous: false)
        }
    }

    let lineLength = 62
    let maxMultiLineLength = 500
    func logPadded(_ string: String, incoming: Bool, withArrows: Bool = false) {
        let arrowPrefix = !incoming ? "" : "<------   "
        let arrowSuffix = !incoming ? "   ------>" : ""
        let emptyPrefix = String(repeating: " ", count: arrowPrefix.count)
        let emptySuffix = String(repeating: " ", count: arrowSuffix.count)
        var index = string.startIndex
        let limitIndex = string.index(string.startIndex,
                                      offsetBy: maxMultiLineLength,
                                      limitedBy: string.endIndex) ?? string.endIndex
        while index < limitIndex {
            let withArrows = withArrows && index == string.startIndex
            let prefix = withArrows ? arrowPrefix : emptyPrefix
            let suffix = withArrows ? arrowSuffix : emptySuffix
            let substring = string.suffix(from: index)
            let paddedString = substring.padding(toLength: lineLength,
                                                 withPad: " ",
                                                 startingAt: 0)
            LogDebug("| " + prefix + paddedString + suffix + " |", asynchronous: false)
            guard let nextIndex = string.index(index,
                                               offsetBy: lineLength,
                                               limitedBy: limitIndex) else { break }
            index = nextIndex
        }
    }

    func logPayload(ofMessage message: CoAPMessage, incoming: Bool) {
        guard let payload = message.payload else { return }
        var payloadString = payload.string
        if payloadString.isEmpty && payload.data.count > 0 {
            payloadString = "0x" + payload.data.hexDescription
        }
        let handshakeOption = message.getIntegerOptions(.handshakeType).first
        switch handshakeOption {
        case .some(1):
            payloadString = "HelloREQ: " + payloadString
        case .some(2):
            payloadString = "HelloRES: " + payloadString
        default:
            payloadString = "Payload: " + payloadString
        }
        logPadded(payloadString, incoming: incoming)
    }

    func logDiagram(message: CoAPMessage, toAddr: Address?, fromAddr: Address?) {
        let incoming = toAddr == nil
        logPadded(" ", incoming: incoming)
        logPadded(message.shortDescription, incoming: incoming, withArrows: true)
        if let proxyURI = message.getOptions(.proxyUri).first?.data.string {
            logPadded("proxy-uri: \(proxyURI)", incoming: incoming)
        }
        logPayload(ofMessage: message, incoming: incoming)
        if let token = message.token {
            logPadded("Token: \(token)", incoming: incoming)
        }
        var proxyString = ""
        if let proxyAddress = message.proxyViaAddress {
            proxyString = " via proxy:\(proxyAddress)"
        }
        if let address = fromAddr {
            logPadded("from \(address)\(proxyString)", incoming: incoming)
        } else if let address = toAddr {
            logPadded("to \(address)\(proxyString)", incoming: incoming)
        }
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
