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

    struct Element {
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

    /// Bidirectional token↔messageId index. A token is re-inserted with a new
    /// messageId for every ARQ block message, so `insert` must evict the previous
    /// reverse entry and `remove(messageId:)` must only drop the forward mapping
    /// while it still points at that id — otherwise removing an old id (its ACK
    /// arrived) would destroy the token's mapping to the live message.
    private struct TokenIndex {
        var idForToken: [CoAPToken: CoAPMessageId] = [:]
        var tokenForId: [CoAPMessageId: CoAPToken] = [:]

        mutating func insert(token: CoAPToken, messageId: CoAPMessageId) {
            if let previousId = idForToken[token], previousId != messageId {
                tokenForId.removeValue(forKey: previousId)
            }
            idForToken[token] = messageId
            tokenForId[messageId] = token
        }

        mutating func remove(messageId: CoAPMessageId) {
            if let token = tokenForId.removeValue(forKey: messageId),
                idForToken[token] == messageId {
                idForToken.removeValue(forKey: token)
            }
        }

        mutating func remove(token: CoAPToken) {
            if let messageId = idForToken.removeValue(forKey: token) {
                tokenForId.removeValue(forKey: messageId)
            }
        }
    }

    private var syncElements = Synchronized(value: [CoAPMessageId: Element]())
    private var syncTokenIndex = Synchronized(value: TokenIndex())
    private var syncMessageDeliveryStats = Synchronized(value: [DeliveryStatisticsKey: DeliveryStatistics]())

    /// Owns `timer` and runs `tick`. A dispatch source needs no run loop, which is the whole
    /// point: a `Timer` is bound to the run loop of whichever thread armed it, and the pool is
    /// armed from `resendTimeInterval`'s setter — reached from the Remote Config fetch
    /// completion, a plain GCD queue with no run loop running.
    private let timerQueue = DispatchQueue(label: "com.ndmsystems.coala.messagePool", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Retransmission policy. One value, one lock, so a tick cannot observe a half-applied
    /// reconfiguration (a new `resendTimeInterval` against the old `maxAttempts`).
    struct Settings {
        var resendTimeInterval: TimeInterval = 0.75
        var maxAttempts = 6

        /// Used to prevent message expiration for long-running request
        /// Messages with paths containing `longRunningUrlPaths` will use `timeout`
        /// instead of `resendTimeInterval`
        var longRunningUrlPaths = [UriPathConfig]()
    }

    /// These are written from the Remote Config fetch completion
    /// (`Coala.configureMessagePool*` ← `GUMService.configureMessageSendingParameters`) and
    /// read by `tick()`/`actionFor(element:)`. As plain `var`s that was a genuine data race
    /// the moment the tick moved off the main run loop — and `longRunningUrlPaths` is an
    /// `Array`, so a read racing a write is an unsynchronized CoW-buffer access: memory-unsafe,
    /// not merely stale.
    private let syncSettings = Synchronized(value: Settings())

    /// Passthroughs, so every existing call site keeps working while the storage underneath
    /// them is synchronized. Each setter re-arms the timer exactly as the old `didSet` did.
    var settings: Settings {
        get { syncSettings.value }
        set {
            syncSettings.value = newValue
            updateTimer()
        }
    }

    var resendTimeInterval: TimeInterval {
        get { syncSettings.value.resendTimeInterval }
        set {
            syncSettings.mutate { $0.resendTimeInterval = newValue }
            updateTimer()
        }
    }

    var maxAttempts: Int {
        get { syncSettings.value.maxAttempts }
        set { syncSettings.mutate { $0.maxAttempts = newValue } }
    }

    var longRunningUrlPaths: [UriPathConfig] {
        get { syncSettings.value.longRunningUrlPaths }
        set { syncSettings.mutate { $0.longRunningUrlPaths = newValue } }
    }

    weak var coala: Coala? { didSet { updateTimer() } }

    func push(message: CoAPMessage) {
        guard message.type != .acknowledgement else { return }

        if let token = message.token {
            syncTokenIndex.mutate { $0.insert(token: token, messageId: message.messageId) }
        }

        trackStatistics(for: message)

        syncElements.mutate { elements in
            if elements[message.messageId] != nil {
                // Do not add same message to a pool more than once
                elements[message.messageId]?.timesSent += 1
                elements[message.messageId]?.lastSend = Date()
            } else {
                elements[message.messageId] = Element(message: message)
            }
        }
    }

    private func trackStatistics(for message: CoAPMessage) {
        guard let address = message.address else { return }

        let key = DeliveryStatisticsKey(scheme: message.scheme, address: address)
        let viaProxy = message.proxyViaAddress != nil
        let isRetransmit = syncElements.value[message.messageId] != nil

        syncMessageDeliveryStats.mutate { stats in
            var entry = stats[key] ?? DeliveryStatistics(
                scheme: message.scheme,
                address: address,
                direct: .init(totalCount: 0, retransmitsCount: 0),
                proxy: .init(totalCount: 0, retransmitsCount: 0)
            )
            if viaProxy {
                entry.proxy.totalCount += 1
                if isRetransmit { entry.proxy.retransmitsCount += 1 }
            } else {
                entry.direct.totalCount += 1
                if isRetransmit { entry.direct.retransmitsCount += 1 }
            }
            stats[key] = entry
        }
    }

    func getStatistics(for address: Address, scheme: CoAPMessage.Scheme) -> DeliveryStatistics? {
        syncMessageDeliveryStats.value[.init(scheme: scheme, address: address)]
    }

    func flushStatistics(for address: Address, scheme: CoAPMessage.Scheme) {
        syncMessageDeliveryStats.mutate { $0.removeValue(forKey: .init(scheme: scheme, address: address)) }
    }

    func flushAllStatistics() {
        syncMessageDeliveryStats.mutate { $0.removeAll() }
    }

    func didTransmitMessage(messageId: CoAPMessageId) {
        syncElements.mutate { $0[messageId]?.didTransmit = true }
    }

    func getSourceMessageFor(message: CoAPMessage) -> CoAPMessage? {
        return get(token: message.token) ?? get(messageId: message.messageId)
    }

    func get(token: CoAPToken?) -> CoAPMessage? {
        guard let token = token, let messageId = syncTokenIndex.value.idForToken[token]
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
        syncTokenIndex.mutate { $0.remove(messageId: messageId) }
        syncElements.mutate { $0.removeValue(forKey: messageId) }
    }

    func flushPoolMetrics(for message: CoAPMessage) {
        syncElements.mutate {
            $0[message.messageId]?.timesSent = 0
            $0[message.messageId]?.lastSend = Date()
        }
    }

    func remove(message: CoAPMessage) {
        // The message's token may map to a different pooled element (e.g. an observe
        // register removed via its separate-response notification) — purge it too.
        let tokenMappedId = message.token.flatMap { syncTokenIndex.value.idForToken[$0] }
        syncTokenIndex.mutate {
            $0.remove(messageId: message.messageId)
            if let token = message.token { $0.remove(token: token) }
        }
        if let token = message.token {
            coala?.layerStack.arqLayer.block2DownloadProgresses.mutate { $0[token] = nil }
        }
        syncElements.mutate {
            $0.removeValue(forKey: message.messageId)
            if let tokenMappedId = tokenMappedId { $0.removeValue(forKey: tokenMappedId) }
        }
    }

    func removeAll() {
        syncTokenIndex.mutate { $0 = TokenIndex() }
        syncElements.mutate { $0.removeAll() }
    }

    /// Slowest the pool will ever be told to re-check, whatever the server sends.
    ///
    /// `resendTimeInterval` is remote-config controlled (`Coala.configureMessagePool`, driven
    /// from `GUMService.configureMessageSendingParameters`), so 0 is reachable by
    /// misconfiguration. A `DispatchSourceTimer` has no floor of its own — `repeating: 0`
    /// fires continuously and busy-spins `timerQueue`'s core — so one is needed here.
    ///
    /// 20 Hz, not `Timer`'s documented 0.1 ms clamp: matching a deprecated API's quirk is not
    /// a requirement, and 10 kHz ticks each walking the whole pool is still a spin, just a
    /// legal one. Production configures 4.0 s (≈1.33 s re-check), so this is three orders of
    /// magnitude faster than anything real and only ever binds on a bad config.
    static let minimumRecheckTimeInterval: TimeInterval = 0.05

    /// Exposed (not just inlined into `updateTimer()`) so the floor can be verified
    /// directly, without needing to run a real timer to observe it.
    func recheckTimeInterval() -> TimeInterval {
        max(syncSettings.value.resendTimeInterval / 3, Self.minimumRecheckTimeInterval)
    }

    /// Always `async`, never `sync`: a tick can itself drive a transport switch
    /// (expiry -> `.unreachable` -> TCP fallback), so a synchronous hop would
    /// deadlock on the queue the tick is already running on.
    ///
    /// The source is rebuilt rather than reused because `resendTimeInterval` changes the period.
    func updateTimer() {
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            guard self.coala != nil else { return }
            let recheckTimeInterval = self.recheckTimeInterval()
            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            timer.schedule(deadline: .now() + recheckTimeInterval, repeating: recheckTimeInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stopTimer() {
        timerQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// A dispatch source with a `[weak self]` handler does not retain the pool the way
    /// `Timer.scheduledTimer(target:)` did, so an un-cancelled source would outlive it and keep
    /// firing no-ops. Touching `timer` directly here (skipping `timerQueue`) is safe: the
    /// event handler's `self?.tick()` resolves `self` to a strong temporary for the
    /// duration of the call, so a running tick holds a strong reference the whole time it
    /// executes — `deinit` can therefore never run *while* a tick is in flight, only
    /// before one starts or after one has returned. A tick that is merely queued (not yet
    /// started) will simply resolve `self` to `nil` and no-op once it does run, since the
    /// refcount is already zero by then.
    deinit {
        timer?.cancel()
    }

    func tick() {
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

    enum Action {
        case resend
        case wait
        case delete
        case timeout
    }

    func actionFor(element: Element) -> Action {
        // One snapshot, so every branch below decides against a single coherent policy.
        let settings = syncSettings.value
        let timeSinceLastSend = abs(element.lastSend.timeIntervalSinceNow)
        let resendable = element.message.type == .confirmable
        if resendable {
            let delivered = element.didTransmit
            let sentTooManyTimes = element.timesSent >= settings.maxAttempts
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

            if let customUriPath = settings.longRunningUrlPaths.first(where: {
                uriPath.contains($0.path) || (reqPath?.contains($0.path) ?? false)
            }) {
                return timeSinceLastSend > customUriPath.timeout ? .resend : .wait
            }
            return timeSinceLastSend > settings.resendTimeInterval ? .resend : .wait
        } else {
            let timeoutInterval = settings.resendTimeInterval * Double(settings.maxAttempts)
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
