//
//  ObservedResourcesRegistry.swift
//  Coala
//
//  Created by Roman on 15/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

struct ObservedResource {

    let url: URL
    fileprivate let handler: Coala.ResponseHandler
    var validUntil: Date?
    var sequenceNumber: UInt?
    fileprivate weak var coala: Coala?

    init(url: URL, coala: Coala, handler: @escaping Coala.ResponseHandler) {
        self.url = url
        self.handler = handler
        self.coala = coala
    }
}

class ObservedResourcesRegistry {

    private var tokenToResource = [CoAPToken: ObservedResource]()
    private var timer: Timer?
    var expirationRandomDelay = 5...15

    func resource(forToken token: CoAPToken) -> ObservedResource? {
        return tokenToResource[token]
    }

    func didStartObserving(resource: ObservedResource, forToken token: CoAPToken) {
        tokenToResource[token] = resource
        if timer == nil {
            startTimer()
        }
    }

    func didStopObservingResource(forToken token: CoAPToken) {
        tokenToResource[token] = nil
        if tokenToResource.count == 0 {
            stopTimer()
        }
    }

    func didReceive(notification: ObserverNotification, forToken token: CoAPToken) {
        let response = Coala.Response.message(message: notification.message,
                                              from: notification.from)
        if let previousSequenceNumber = tokenToResource[token]?.sequenceNumber,
            let sequenceNumber = notification.sequenceNumber,
            previousSequenceNumber >= sequenceNumber {
                return
        }
        if let handler = tokenToResource[token]?.handler {
            DispatchQueue.main.async {
                handler(response)
            }
        }
        tokenToResource[token]?.validUntil = expirationDateFor(maxAge: notification.maxAge)
        tokenToResource[token]?.sequenceNumber = notification.sequenceNumber
    }

    func expirationDateFor(maxAge: UInt?) -> Date? {
        guard let maxAge = maxAge else { return nil }
        var expiration = Double(maxAge)
        let min = expirationRandomDelay.lowerBound
        let max = expirationRandomDelay.upperBound
        expiration += Double(arc4random_uniform(UInt32(max - min))) + Double(min)
        return Date().addingTimeInterval(expiration)
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 1,
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
        for (token, resource) in tokenToResource {
            if let coala = resource.coala, let validUntil: Date = resource.validUntil, validUntil < Date() {
                coala.startObserving(url: resource.url, onUpdate: resource.handler)
                tokenToResource.removeValue(forKey: token)
            }
        }
    }

}
