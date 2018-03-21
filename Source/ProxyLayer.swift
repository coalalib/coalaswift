//
//  ProxyLayer.swift
//  Coala
//
//  Created by Roman on 13/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

struct ProxyLayer { }

extension ProxyLayer: InLayer {

    enum ProxyLayerError: Error {
        case proxyingNotSupported
    }

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        let pool = coala.messagePool
        if let previousMessage = pool.getSourceMessageFor(message: message),
            let proxyViaAddress = previousMessage.proxyViaAddress,
            proxyViaAddress == fromAddress,
            let realAddress = previousMessage.address {
                message.proxyViaAddress = proxyViaAddress
                message.address = realAddress
                fromAddress = realAddress
        }
        if message.getOptions(.proxyUri).first != nil {
            ack = CoAPMessage(ackTo: message, from: fromAddress, code: .proxyingNotSupported)
            throw ProxyLayerError.proxyingNotSupported
        }
    }

}

extension ProxyLayer: OutLayer {

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        guard let proxyAddress = message.proxyViaAddress else { return }
        guard let url = message.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme,
              let host = components.host,
              let port = components.port else {
                message.setOption(.proxyUri, value: nil)
                toAddress = proxyAddress
                return
        }
        let proxyUri = "\(scheme)://\(host):\(port)"
        message.setOption(.proxyUri, value: proxyUri)
        toAddress = proxyAddress

        // https://tools.ietf.org/html/rfc7252#section-5.10.2
        // The Proxy-Uri Option MUST take precedence over any of the Uri-Host,
        // Uri-Port, Uri-Path or Uri-Query options (each of which MUST NOT be
        // included in a request containing the Proxy-Uri Option).

        // According latest news we shouldn't remove uri options from original message
        // if message.getOptions(.proxyUri).first != nil {
        //  message.removeOption(.uriHost)
        //  message.removeOption(.uriPort)
        //  message.removeOption(.uriPath)
        //   message.removeOption(.uriQuery)
        //}
    }

}
