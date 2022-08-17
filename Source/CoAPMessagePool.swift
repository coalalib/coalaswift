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
    /// Messages with paths containing `longRunningUrlPaths` will use `longRunningTasksTimeout`
    /// instead of `resendTimeInterval`
    var longRunningUrlPaths = Set<String>()
    var longRunningTasksTimeout = 6.0

    weak var coala: Coala? { didSet { updateTimer() } }

    func push(message: CoAPMessage) {
        guard message.type != .acknowledgement else { return }

        if let token = message.token {
            syncMessageIdForToken.value[token] = message.messageId
        }

        trackStatistics(for: message)

        guard syncElements.value[message.messageId] == nil else {
          // Do not add same message to a pool more than once
            syncElements.value[message.messageId]?.timesSent += 1
            syncElements.value[message.messageId]?.lastSend = Date()
            return
        }
        syncElements.value[message.messageId] = Element(message: message)
    }

    private func trackStatistics(for message: CoAPMessage) {
        guard let address = message.address else { return }

        let key = DeliveryStatisticsKey(scheme: message.scheme, address: address)
        let viaProxy = message.proxyViaAddress != nil

        if var existingStatistics = syncMessageDeliveryStats.value[key] {
            if viaProxy {
                existingStatistics.proxy.totalCount += 1
            } else {
                existingStatistics.direct.totalCount += 1
            }

            if syncElements.value[message.messageId] != nil {
                if viaProxy {
                    existingStatistics.proxy.retransmitsCount += 1
                } else {
                    existingStatistics.direct.retransmitsCount += 1
                }
            }
            syncMessageDeliveryStats.value[key] = existingStatistics
        } else {
            syncMessageDeliveryStats.value[key] = .init(
                scheme: message.scheme,
                address: address,
                direct: .init(totalCount: 0, retransmitsCount: 0),
                proxy: .init(totalCount: 0, retransmitsCount: 0)
            )

            if viaProxy {
                syncMessageDeliveryStats.value[key]?.proxy.totalCount += 1
            } else {
                syncMessageDeliveryStats.value[key]?.direct.totalCount += 1
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
        syncElements.value[messageId]?.didTransmit = true
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
      syncElements.value[message.messageId]?.timesSent = 0
      syncElements.value[message.messageId]?.lastSend = Date()
    }

    func remove(message: CoAPMessage) {
        if let token = message.token, let messageId = syncMessageIdForToken.value[token] {
            syncMessageIdForToken.value.removeValue(forKey: token)
            syncElements.value.removeValue(forKey: messageId)
            coala?.layerStack.arqLayer.block2DownloadProgresses[token.description] = nil
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
        timer = Timer.scheduledTimer(
            timeInterval: recheckTimeInterval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
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
            
            let optionValuesString = element.message.options
                .compactMap { $0.value as? String }
                .joined()

            if longRunningUrlPaths.contains(where: optionValuesString.contains) {
                let timeToResend = timeSinceLastSend > longRunningTasksTimeout
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
