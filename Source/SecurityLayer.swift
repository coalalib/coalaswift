//
//  SecurityLayer.swift
//  Coala
//
//  Created by Roman on 08/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

public enum CoapsError: Error {
    case peerPublicKeyValidationFailed
}

class SecurityLayer: InLayer {

    struct SecuredSessionKey: Hashable {
        let address: Address
        let proxyAddress: Address?

        func hash(into hasher: inout Hasher) {
            hasher.combine(address)
            hasher.combine(proxyAddress)
        }
    }

    fileprivate var securedSessionPool = [SecuredSessionKey: SecuredSession]()
    fileprivate var pendingMessages = [CoAPMessage]()

    enum SecurityLayerError: Error {
        case sessionNotEstablished
        case payloadExpected
        case handshakeInProgress
    }

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        guard message.scheme == .coapSecure else {
            if message.getIntegerOptions(.handshakeType).first == 1 {
                try handleIncomingHandshake(coala: coala,
                                            message: message,
                                            fromAddress: fromAddress)
            }
            let hasOptionSessionNotFound = message.getIntegerOptions(.sessionNotFound).first != nil
            let hasOptionSessionExpired = message.getIntegerOptions(.sessionExpired).first != nil
            if hasOptionSessionNotFound || hasOptionSessionExpired {
                if var sourceMessage = coala.messagePool.getSourceMessageFor(message: message) {
                    coala.messagePool.remove(message: sourceMessage)
                    sourceMessage.address = fromAddress
                    startSession(toAddress: fromAddress, coala: coala, andSendMessage: sourceMessage)
                }
            }
            return
        }
        var sessionAddress = fromAddress
        if let sentMessage = coala.messagePool.getSourceMessageFor(message: message),
          let sentMessageAddress = sentMessage.address {
          if sentMessage.getOptions(.proxyUri).first == nil {
            sessionAddress = sentMessageAddress
          }
        }
        let sessionKey = SecuredSessionKey(address: sessionAddress, proxyAddress: message.proxyViaAddress)
        guard let session = securedSessionPool[sessionKey], let aead = session.aead
            else {
                var sessionNotFound = CoAPMessage(ackTo: message, from: fromAddress, code: .unauthorized)
                sessionNotFound.url = fromAddress.urlForScheme(scheme: .coap)
                sessionNotFound.setOption(.sessionNotFound, value: 1)
                try coala.send(sessionNotFound)
                throw SecurityLayerError.sessionNotEstablished
        }
        if let payload = message.payload {
            message.payload = try aead.open(cipherText: payload.data,
                                            counter: message.messageId)
        }
        if let encryptedUriData = message.getOptions(.coapsUri).first?.data {
            let urlData = try aead.open(cipherText: encryptedUriData,
                                        counter: message.messageId)
            if let absoluteURL = String(data: urlData, encoding: .utf8), let url = URL(string: absoluteURL) {
                message.url = url
            }
        }
        message.peerPublicKey = session.peerPublicKey
    }

    func handleIncomingHandshake(coala: Coala, message: CoAPMessage, fromAddress: Address) throws {
        guard let payload = message.payload
            else { throw SecurityLayerError.payloadExpected }
        switch message.code {
        case .request(.get):
            let sessionKey = SecuredSessionKey(address: fromAddress, proxyAddress: message.proxyViaAddress)
            let session = SecuredSession(incoming: true)
            securedSessionPool[sessionKey] = session
            try session.start(peerPublicKey: payload.data)
            var response = CoAPMessage(ackTo: message, from: fromAddress, code: .content)
            response.setOption(.handshakeType, value: 2)
            response.payload = session.publicKey
            let logLayer = LogLayer()
            logLayer.logDiagram(message: message, toAddr: nil, fromAddr: fromAddress)
            try coala.send(response)
            throw SecurityLayerError.handshakeInProgress
        default:
            return
        }
    }
}

extension SecurityLayer: OutLayer {

    func startSession(toAddress: Address, coala: Coala, andSendMessage message: CoAPMessage) {
        let session = SecuredSession(incoming: false)
        let sessionKey = SecuredSessionKey(address: toAddress, proxyAddress: message.proxyViaAddress)
        securedSessionPool[sessionKey] = session
        performHandshake(coala: coala,
                         session: session,
                         address: toAddress,
                         triggeredBy: message) { [weak self, weak coala] error in
                            if let error = error {
                                self?.failPendingMessages(toAddress: toAddress, withError: error)
                                self?.securedSessionPool.removeValue(forKey: sessionKey)
                            } else if let coala = coala {
                                self?.sendPendingMessages(toAddress: toAddress, usingCoala: coala)
                            }
        }
        pendingMessages.append(message)
    }

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        guard message.scheme == .coapSecure else { return }
        let sessionKey = SecuredSessionKey(address: toAddress, proxyAddress: message.proxyViaAddress)
        guard let session = securedSessionPool[sessionKey] else {
            startSession(toAddress: toAddress, coala: coala, andSendMessage: message)
            throw SecurityLayerError.handshakeInProgress
        }
        guard let aead = session.aead else {
            pendingMessages.append(message)
            throw SecurityLayerError.handshakeInProgress
        }
        if let payload = message.payload {
            message.payload = try aead.seal(plainText: payload.data,
                                            counter: message.messageId)
        }
        if let url = message.url, let urlData = url.absoluteString.data(using: .utf8) {
            let encryptedUrl = try aead.seal(plainText: urlData,
                                             counter: message.messageId) // Same counter?
            message.setOption(.coapsUri, value: encryptedUrl)
        }
        message.removeOption(.uriPath)
        message.removeOption(.uriQuery)
    }

    func performHandshake(coala: Coala,
                          session: SecuredSession,
                          address: Address,
                          triggeredBy causingMessage: CoAPMessage,
                          completion: @escaping (Error?) -> Void) {
        let url = address.urlForScheme(scheme: .coap)
        var message = CoAPMessage(type: .confirmable, method: .get, url: url)
        message.setOption(.handshakeType, value: 1)
        message.payload = session.publicKey
        message.proxyViaAddress = causingMessage.proxyViaAddress
        message.onResponse = { [weak self] response in
            let peerKey: Data
            switch response {
            case .message(let message, let from):
                let sessionKey = SecuredSessionKey(address: from, proxyAddress: message.proxyViaAddress)
                self?.securedSessionPool[sessionKey] = session
                guard let payload = message.payload else { return }
                peerKey = payload.data
            case .error(let error):
                completion(error)
                return
            }
            do {
                if let expectedPeerKey = causingMessage.peerPublicKey, peerKey != expectedPeerKey {
                    LogWarn("Handshake: Peer \(address) public key: \(peerKey.hexDescription)" +
                        " but expected: \(expectedPeerKey.hexDescription)")
                    throw CoapsError.peerPublicKeyValidationFailed
                }
                LogInfo("Handshake: Completed, peer \(address) public key: \(peerKey.hexDescription)")
                try session.start(peerPublicKey: peerKey)
            } catch let error {
                LogError("Session error: \(error)")
                completion(error)
            }
            completion(nil)
        }
        try? coala.send(message)
    }

    private func removePendingMessages(toAddress: Address, performingBlock: (CoAPMessage) -> Void) {
        for message in pendingMessages.filter({ $0.address == toAddress }) {
            performingBlock(message)
        }
        pendingMessages = pendingMessages.filter({ $0.address != toAddress })
    }

    func failPendingMessages(toAddress: Address, withError: Error) {
        removePendingMessages(toAddress: toAddress) { message in
            message.onResponse?(.error(error: withError))
        }
    }

    func sendPendingMessages(toAddress: Address, usingCoala: Coala) {
        removePendingMessages(toAddress: toAddress) { message in
            try? usingCoala.send(message)
        }
    }
}
