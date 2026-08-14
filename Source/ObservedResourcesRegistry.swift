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

    private let syncTokenToResource = Synchronized(value: [CoAPToken: ObservedResource]())
    /// Owns `timer`, and every arm/disarm request is `async` onto it.
    private let timerQueue = DispatchQueue(label: "com.ndmsystems.coala.observedResources",
                                           qos: .utility)
    private var timer: DispatchSourceTimer?
    var expirationRandomDelay = 5...15

    /// Whether the expiry timer is currently armed, once every queued arm/disarm request has
    /// run. Exists so a test can assert on the timer without reaching into `timerQueue`
    /// itself: arming is asynchronous, so a bare `timer != nil` read would race it.
    var isTimerArmedAfterPendingWork: Bool {
        return timerQueue.sync { timer != nil }
    }

    func resource(forToken token: CoAPToken) -> ObservedResource? {
        return syncTokenToResource.value[token]
    }

    func didStartObserving(resource: ObservedResource, forToken token: CoAPToken) {
        syncTokenToResource.mutate { $0[token] = resource }
        updateTimer()
    }

    func didStopObservingResource(forToken token: CoAPToken) {
        syncTokenToResource.mutate { $0[token] = nil }
        updateTimer()
    }

    /// Idempotent: armed whenever a resource is registered, disarmed when the last one goes.
    /// Unlike the message pool's, this period is a constant, so an already-running source is
    /// left alone rather than rebuilt.
    ///
    /// Always `async`, never `sync` — `tick()` calls back into this from this very queue.
    ///
    /// This is the only place allowed to disarm as part of normal operation, because it is
    /// the only one that re-reads the registry before doing so. `stopTimer()` cancels
    /// unconditionally, which is correct only for teardown.
    func updateTimer() {
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.syncTokenToResource.value.isEmpty else {
                self.timer?.cancel()
                self.timer = nil
                return
            }
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func didReceive(notification: ObserverNotification, forToken token: CoAPToken) {
        let response = Coala.Response.message(message: notification.message,
                                              from: notification.from)
        let handler: Coala.ResponseHandler? = syncTokenToResource.mutate { resources in
            guard let resource = resources[token] else { return nil }
            if let previousSequenceNumber = resource.sequenceNumber,
                let sequenceNumber = notification.sequenceNumber,
                previousSequenceNumber >= sequenceNumber {
                return nil
            }
            resources[token]?.validUntil = expirationDateFor(maxAge: notification.maxAge)
            resources[token]?.sequenceNumber = notification.sequenceNumber
            return resource.handler
        }
        if let handler = handler {
            DispatchQueue.main.async {
                handler(response)
            }
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

    func stopTimer() {
        timerQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// An un-cancelled source outlives the registry and keeps firing no-ops.
    deinit {
        timer?.cancel()
    }

    func tick() {
        let expired: [ObservedResource] = syncTokenToResource.mutate { resources in
            let due = resources.filter { _, resource in
                guard let validUntil = resource.validUntil else { return false }
                return validUntil < Date()
            }
            due.keys.forEach { resources.removeValue(forKey: $0) }
            return Array(due.values)
        }
        // Outside the lock on purpose: `startObserving` sends, and the out-layer stack calls
        // straight back into `didStartObserving`, which takes the same non-reentrant lock.
        for resource in expired {
            resource.coala?.startObserving(url: resource.url, onUpdate: resource.handler)
        }
        // `updateTimer()`, not `stopTimer()`: this must not disarm without re-reading the
        // registry. `stopTimer()` cancels unconditionally, while `updateTimer()` early-returns
        // on an already-armed source — so a `didStartObserving` racing this tick could enqueue
        // its arm request *before* the cancel, find the source still live, return, and leave
        // the cancel to win. That parks a non-empty registry with no timer, and nothing
        // re-arms until the next register/unregister: expired observations silently stop
        // re-subscribing for the rest of the session. `updateTimer()` re-checks emptiness when
        // it runs, so it is correct in either order.
        updateTimer()
    }

}
