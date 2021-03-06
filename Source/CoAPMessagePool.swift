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

    private var syncElements = Synchronized(value: [CoAPMessageId: Element]())
    private var syncMessageIdForToken = Synchronized(value: [CoAPToken: CoAPMessageId]())
    private var timer: Timer?

    var resendTimeInterval = 0.75 { didSet { updateTimer() } }
    var maxAttempts = 6

    weak var coala: Coala? { didSet { updateTimer() } }

    func push(message: CoAPMessage) {
        guard message.type != .acknowledgement else { return }
        if let token = message.token {
            syncMessageIdForToken.value[token] = message.messageId
        }
        guard syncElements.value[message.messageId] == nil else {
          // Do not add same message to a pool more than once
            syncElements.value[message.messageId]?.timesSent += 1
            syncElements.value[message.messageId]?.lastSend = Date()
            return
        }
        syncElements.value[message.messageId] = Element(message: message)
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
        return syncElements.value[messageId]?.message
    }

    func timesSent(messageId: CoAPMessageId) -> Int? {
        return syncElements.value[messageId]?.timesSent
    }

    func remove(messageWithId messageId: CoAPMessageId) {
        if let token = syncMessageIdForToken.value.filter({ $1 == messageId }).first?.key {
            syncMessageIdForToken.value.removeValue(forKey: token)
        }
        syncElements.value.removeValue(forKey: messageId)
    }

    func remove(message: CoAPMessage) {
        if let token = message.token, let messageId = syncMessageIdForToken.value[token] {
            syncMessageIdForToken.value.removeValue(forKey: token)
            syncElements.value.removeValue(forKey: messageId)
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
        timer = Timer.scheduledTimer(timeInterval: recheckTimeInterval,
                                     target: self,
                                     selector: #selector(tick),
                                     userInfo: nil,
                                     repeats: true)
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
                LogError("Error! CoAPMessagePool: messageExpired \(element.message.shortDescription)")
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
            let timeToResend = timeSinceLastSend > resendTimeInterval
            return timeToResend ? .resend : .wait
        } else {
            let timeoutInterval = resendTimeInterval * Double(maxAttempts)
            let timeout = timeSinceLastSend > timeoutInterval
            guard !timeout else { return .delete }
            return .wait
        }
    }
}
