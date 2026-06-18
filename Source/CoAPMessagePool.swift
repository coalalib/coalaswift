//
//  CoAPMessagePool.swift
//  Coala
//
//  Created by Roman on 15/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

public enum CoAPMessagePoolError: LocalizedError {

    case messageExpired(Address)

    public var errorDescription: String? {
        switch self {
        case .messageExpired(let address):
            return "Peer \(address) did not respond to CON message"
        }
    }
}

final class CoAPMessagePool {

    private struct Element {
        let message: CoAPMessage
        let createTime = Date()
        var timesSent = 1
        var lastSend = Date()
        var didTransmit = false

        init(message: CoAPMessage) {
            self.message = message
        }
    }

    private struct DeliveryStatisticsKey: Hashable {
        let scheme: CoAPMessage.Scheme
        let address: Address
    }

    private var syncElements = Synchronized(value: [CoAPMessageId: Element]())
    private var syncMessageIdForToken = Synchronized(value: [CoAPToken: CoAPMessageId]())
    private var syncMessageDeliveryStats = Synchronized(value: [DeliveryStatisticsKey: DeliveryStatistics]())

    private var timer: Timer?

    var resendTimeInterval = 0.75 { didSet { updateTimer() } }
    var maxAttempts = 6

    /// Used to prevent message expiration for long-running request
    /// Messages with paths containing `longRunningUrlPaths` will use `timeout`
    /// instead of `resendTimeInterval`
    var longRunningUrlPaths = [UriPathConfig]()

    weak var coala: Coala? { didSet { updateTimer() } }

    func push(message: CoAPMessage) {
        guard message.type != .acknowledgement else { return }

        if let token = message.token {
            syncMessageIdForToken.value[token] = message.messageId
        }

        trackStatistics(for: message)

        var alreadyPresent = false
        syncElements.writer { dict in
            if dict[message.messageId] != nil {
                // Do not add same message to a pool more than once
                dict[message.messageId]?.timesSent += 1
                dict[message.messageId]?.lastSend = Date()
                alreadyPresent = true
            } else {
                dict[message.messageId] = Element(message: message)
            }
        }
        if alreadyPresent { return }
    }

    private func trackStatistics(for message: CoAPMessage) {
        guard let address = message.address else { return }

        let key = DeliveryStatisticsKey(scheme: message.scheme, address: address)
        let viaProxy = message.proxyViaAddress != nil

        let isRetransmit = syncElements.reader { $0[message.messageId] != nil }
        syncMessageDeliveryStats.writer { statsDict in
            if statsDict[key] != nil {
                if viaProxy {
                    statsDict[key]?.proxy.totalCount += 1
                    if isRetransmit { statsDict[key]?.proxy.retransmitsCount += 1 }
                } else {
                    statsDict[key]?.direct.totalCount += 1
                    if isRetransmit { statsDict[key]?.direct.retransmitsCount += 1 }
                }
            } else {
                var newStats = DeliveryStatistics(
                    scheme: message.scheme,
                    address: address,
                    direct: .init(totalCount: 0, retransmitsCount: 0),
                    proxy: .init(totalCount: 0, retransmitsCount: 0)
                )
                if viaProxy {
                    newStats.proxy.totalCount += 1
                } else {
                    newStats.direct.totalCount += 1
                }
                statsDict[key] = newStats
            }
        }
    }

    func getStatistics(for address: Address, scheme: CoAPMessage.Scheme) -> DeliveryStatistics? {
        syncMessageDeliveryStats.value[.init(scheme: scheme, address: address)]
    }

    func flushStatistics(for address: Address, scheme: CoAPMessage.Scheme) {
        syncMessageDeliveryStats.value.removeValue(forKey: .init(scheme: scheme, address: address))
    }

    func flushAllStatistics() {
        syncMessageDeliveryStats.value.removeAll()
    }

    func didTransmitMessage(messageId: CoAPMessageId) {
        syncElements.writer { $0[messageId]?.didTransmit = true }
    }

    func getSourceMessageFor(message: CoAPMessage) -> CoAPMessage? {
        return get(token: message.token) ?? get(messageId: message.messageId)
    }

    func get(token: CoAPToken?) -> CoAPMessage? {
        guard let token = token, let messageId = syncMessageIdForToken.value[token]
            else { return nil }
        return get(messageId: messageId)
    }

    func get(messageId: CoAPMessageId) -> CoAPMessage? {
        syncElements.value[messageId]?.message
    }

    func timesSent(messageId: CoAPMessageId) -> Int? {
        syncElements.value[messageId]?.timesSent
    }

    func remove(messageWithId messageId: CoAPMessageId) {
        if let token = syncMessageIdForToken.value.filter({ $1 == messageId }).first?.key {
            syncMessageIdForToken.value.removeValue(forKey: token)
        }
        syncElements.value.removeValue(forKey: messageId)
    }

    func flushPoolMetrics(for message: CoAPMessage) {
        let messageId = message.messageId
        let now = Date()
        syncElements.writer { dict in
            dict[messageId]?.timesSent = 0
            dict[messageId]?.lastSend = now
        }
    }

    func remove(message: CoAPMessage) {
        if let token = message.token, let messageId = syncMessageIdForToken.value[token] {
            syncMessageIdForToken.value.removeValue(forKey: token)
            syncElements.value.removeValue(forKey: messageId)
            coala?.layerStack.arqLayer.setBlock2DownloadProgress(nil, forToken: token.description)
        }
        syncElements.value.removeValue(forKey: message.messageId)
    }

    func removeAll() {
        syncMessageIdForToken.value.removeAll()
        syncElements.value.removeAll()
    }

    func updateTimer() {
        if coala != nil {
            startTimer()
        } else {
            stopTimer()
        }
    }

    func startTimer() {
        timer?.invalidate()
        let recheckTimeInterval = resendTimeInterval / 3
        let t = Timer(
            timeInterval: recheckTimeInterval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc func tick() {
        guard let coala = coala else { return }
        for (_, element) in syncElements.value {
            switch actionFor(element: element) {
            case .delete:
                remove(message: element.message)
            case .wait:
                break
            case .resend:
                try? coala.send(element.message)
            case .timeout:
                LogWarn("Error! CoAPMessagePool: messageExpired \(element.message.shortDescription)")
                let unknownAddress = Address(host: "unknown", port: 0)
                let error: CoAPMessagePoolError = .messageExpired(element.message.address ?? unknownAddress)
                element.message.onResponse?(.error(error: error))
                remove(message: element.message)
            }
        }
    }

    private enum Action {
        case resend
        case wait
        case delete
        case timeout
    }

    private func actionFor(element: Element) -> Action {
        let timeSinceLastSend = abs(element.lastSend.timeIntervalSinceNow)
        let resendable = element.message.type == .confirmable
        if resendable {
            let delivered = element.didTransmit
            let sentTooManyTimes = element.timesSent >= maxAttempts
            guard !sentTooManyTimes else {
                return delivered ? .delete : .timeout
            }
            guard !delivered else { return .delete }

            let uriPath = "/" + element.message
                .getStringOptions(.uriPath)
                .joined(separator: "/")

            let reqPath = element.message
              .getStringOptions(.uriQuery)
              .first(where: { $0.contains("req") })

            if let customUriPath = longRunningUrlPaths.first(where: {
                uriPath.contains($0.path) || (reqPath?.contains($0.path) ?? false)
            }) {
                let timeToResend = timeSinceLastSend > customUriPath.timeout
                return timeToResend ? .resend : .wait
            } else {
                let timeToResend = timeSinceLastSend > resendTimeInterval
                return timeToResend ? .resend : .wait
            }
        } else {
            let timeoutInterval = resendTimeInterval * Double(maxAttempts)
            let timeout = timeSinceLastSend > timeoutInterval
            guard !timeout else { return .delete }
            return .wait
        }
    }
}

public struct UriPathConfig {

    public let path: String
    public let timeout: Double

    public init(
        path: String,
        timeout: Double = 6.0
    ) {
        self.path = path
        self.timeout = timeout
    }

}
