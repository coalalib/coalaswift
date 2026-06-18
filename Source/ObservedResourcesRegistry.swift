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

    // Bug 3 fix: wrap in Synchronized to guard concurrent access from the delegate queue
    // and the main-runloop tick().
    private let syncTokenToResource = Synchronized<[CoAPToken: ObservedResource]>(value: [:])
    private var timer: Timer?
    var expirationRandomDelay = 5...15

    func resource(forToken token: CoAPToken) -> ObservedResource? {
        return syncTokenToResource.reader { $0[token] }
    }

    func didStartObserving(resource: ObservedResource, forToken token: CoAPToken) {
        syncTokenToResource.writer { $0[token] = resource }
        // Timer inspection / start is done on whatever thread this is called from.
        // The timer itself is scheduled on the main run loop (see startTimer).
        // This check is a best-effort guard; the worst case is we call startTimer
        // redundantly while the timer already exists, which is harmless (we invalidate first).
        if timer == nil {
            startTimer()
        }
    }

    func didStopObservingResource(forToken token: CoAPToken) {
        syncTokenToResource.writer { $0[token] = nil }
        let isEmpty = syncTokenToResource.reader { $0.isEmpty }
        if isEmpty {
            stopTimer()
        }
    }

    // Bug 4 fix: RFC 7641 §3.4 modular freshness check with 24-bit wrap handling.
    private func isFresher(new: UInt, than old: UInt) -> Bool {
        let v: Int = Int(new) - Int(old)
        // Within the 24-bit sequence number space (max 2^24 = 16777216).
        // Treat `new` as fresher iff the signed distance mod 2^24 is positive
        // and less than 2^23.
        return (v > 0 && v < (1 << 23)) || (v < 0 && v < -(1 << 23))
    }

    func didReceive(notification: ObserverNotification, forToken token: CoAPToken) {
        let response = Coala.Response.message(message: notification.message,
                                              from: notification.from)
        // Bug 4: use RFC 7641 modular freshness check instead of plain >=
        if let previousSequenceNumber = syncTokenToResource.reader({ $0[token]?.sequenceNumber }),
            let sequenceNumber = notification.sequenceNumber,
            !isFresher(new: sequenceNumber, than: previousSequenceNumber) {
                return
        }
        if let handler = syncTokenToResource.reader({ $0[token]?.handler }) {
            DispatchQueue.main.async {
                handler(response)
            }
        }
        syncTokenToResource.writer {
            $0[token]?.validUntil = self.expirationDateFor(maxAge: notification.maxAge)
            $0[token]?.sequenceNumber = notification.sequenceNumber
        }
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
        // The target/selector Timer retains self, but the cycle is broken by
        // Coala.deinit calling stopTimer(). Added to RunLoop.main so it fires
        // even when the current thread has no run loop. (Block-based Timer init
        // requires iOS 10+, which this deployment target predates.)
        let t = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // Bug 1 fix: collect expired entries first, then mutate outside the iteration.
    // Bug 3: reads are via syncTokenToResource.reader (concurrent-safe).
    @objc func tick() {
        // Collect all expired (token, coala, url, handler) tuples atomically.
        let expired: [(token: CoAPToken, coala: Coala, url: URL, handler: Coala.ResponseHandler)] =
            syncTokenToResource.reader { dict in
                dict.compactMap { (token, resource) -> (CoAPToken, Coala, URL, Coala.ResponseHandler)? in
                    guard let coala = resource.coala,
                          let validUntil = resource.validUntil,
                          validUntil < Date() else { return nil }
                    return (token, coala, resource.url, resource.handler)
                }
            }

        // Nothing to do.
        guard !expired.isEmpty else { return }

        // Remove the expired tokens in a single writer pass.
        syncTokenToResource.writer { dict in
            for entry in expired {
                dict.removeValue(forKey: entry.token)
            }
        }

        // Restart observing outside the synchronized block and outside the iteration.
        for entry in expired {
            entry.coala.startObserving(url: entry.url, onUpdate: entry.handler)
        }
    }

}
