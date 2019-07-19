//
//  SecurityLayerNew.swift
//  Coala
//
//  Created by Pavel Shatalov on 04/04/2019.
//  Copyright © 2019 NDM Systems. All rights reserved.
//

public enum CoapsError: Error {
    case peerPublicKeyValidationFailed
}

class SecurityLayer: InLayer {

    struct SecuredSessionKey: Hashable {
        var address: Address
        var proxyAddress: Address?
        var proxySecurityId: UInt?

        func hash(into hasher: inout Hasher) {
            hasher.combine(address)
            hasher.combine(proxyAddress)
            hasher.combine(proxySecurityId)
        }
    }

    private var securedSessionPool = Synchronized(value: [SecuredSessionKey: SecuredSession]())
    private var proxySecurityIdPool = Synchronized(value: [Address: UInt]())

    private var pendingMessages = [CoAPMessage]()

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
                return
            }

            let hasOptionSessionNotFound = message.getIntegerOptions(.sessionNotFound).first != nil
            let hasOptionSessionExpired = message.getIntegerOptions(.sessionExpired).first != nil

            if hasOptionSessionNotFound || hasOptionSessionExpired {
                if var sourceMessage = coala.messagePool.getSourceMessageFor(message: message) {
                    coala.messagePool.remove(message: sourceMessage)
                    sourceMessage.address = fromAddress
                    let sessionKey = SecuredSessionKey(address: fromAddress,
                                                       proxyAddress: sourceMessage.proxyViaAddress,
                                                       proxySecurityId: proxySecurityIdPool.value[fromAddress])
                    startSession(with: sessionKey, toAddress: fromAddress, coala: coala, andSendMessage: sourceMessage)
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

        let proxySecurityId = getProxySecurityId(from: message)
        let sessionKey = SecuredSessionKey(address: sessionAddress,
                                           proxyAddress: message.proxyViaAddress,
                                           proxySecurityId: proxySecurityId)

        guard let session = securedSessionPool.value[sessionKey], let aead = session.aead
            else {
                var sessionNotFound = CoAPMessage(ackTo: message, from: fromAddress, code: .unauthorized)
                sessionNotFound.url = fromAddress.urlForScheme(scheme: .coap)
                sessionNotFound.setOption(.sessionNotFound, value: 1)
                if let proxySecurityId = proxySecurityId {
                    sessionNotFound.setOption(.proxySecurityId, value: proxySecurityId)
                }
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
            let proxySecurityId = getProxySecurityId(from: message)
            let sessionKey = SecuredSessionKey(address: fromAddress,
                                               proxyAddress: message.proxyViaAddress,
                                               proxySecurityId: proxySecurityId)

            let session = SecuredSession(incoming: true)
            securedSessionPool.value[sessionKey] = session
            try session.start(peerPublicKey: payload.data)
            var response = CoAPMessage(ackTo: message, from: fromAddress, code: .content)
            response.setOption(.handshakeType, value: 2)
            if let proxySecurityId = proxySecurityId {
                response.setOption(.proxySecurityId, value: proxySecurityId)
            }
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

    func startSession(with sessionKey: SecuredSessionKey,
                      toAddress: Address,
                      coala: Coala,
                      andSendMessage message: CoAPMessage) {
        let session = SecuredSession(incoming: false)
        securedSessionPool.value[sessionKey] = session
        performHandshake(coala: coala,
                         session: session,
                         address: toAddress,
                         proxySecurityId: sessionKey.proxySecurityId,
                         triggeredBy: message) { [weak self, weak coala] error in
                            if let error = error {
                                self?.failPendingMessages(toAddress: toAddress, withError: error)
                                self?.securedSessionPool.value.removeValue(forKey: sessionKey)
                            } else if let coala = coala {
                                self?.sendPendingMessages(toAddress: toAddress, usingCoala: coala)
                            }
        }
        pendingMessages.append(message)
    }

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        guard message.scheme == .coapSecure else { return }
        var proxySecurityId: UInt?
        if message.proxyViaAddress != nil {
            if let existingProxyId = proxySecurityIdPool.value[toAddress] {
                proxySecurityId = existingProxyId
            } else {
                proxySecurityId = UInt(arc4random())
                proxySecurityIdPool.value[toAddress] = proxySecurityId
            }
        }

        message.setOption(.proxySecurityId, value: proxySecurityId)

        let sessionKey = SecuredSessionKey(address: toAddress,
                                           proxyAddress: message.proxyViaAddress,
                                           proxySecurityId: proxySecurityId)

        guard let session = securedSessionPool.value[sessionKey] else {
            startSession(with: sessionKey, toAddress: toAddress, coala: coala, andSendMessage: message)
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
                          proxySecurityId: UInt? = nil,
                          triggeredBy causingMessage: CoAPMessage,
                          completion: @escaping (Error?) -> Void) {
        let url = address.urlForScheme(scheme: .coap)
        var message = CoAPMessage(type: .confirmable, method: .get, url: url)
        message.setOption(.handshakeType, value: 1)
        message.payload = session.publicKey
        message.proxyViaAddress = causingMessage.proxyViaAddress
        message.setOption(.proxySecurityId, value: proxySecurityId)

        if causingMessage.proxyViaAddress != nil && proxySecurityId == nil {
            assertionFailure("Wrong behaviour")
        }

        message.onResponse = { [weak self] response in
            let peerKey: Data
            switch response {
            case .message(let message, let from):
                let sessionKey = SecuredSessionKey(address: from,
                                                   proxyAddress: message.proxyViaAddress,
                                                   proxySecurityId: self?.getProxySecurityId(from: message))
                self?.securedSessionPool.value[sessionKey] = session
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

    private func getProxySecurityId(from message: CoAPMessage) -> UInt? {
        return message.getOptions(.proxySecurityId).map { UInt(data: $0.data)}.first
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
