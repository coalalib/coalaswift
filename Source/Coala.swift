//
//  Coala.swift
//  Coala
//
//  Created by Roman on 05/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation
import Curve25519

/**
    The main class, exposes most of Coala capabilities
    Is itself a representation of P2P capable CoAP client/server
*/

public class Coala: NSObject {
  
    public enum Transport {
        case tcp(host: String, port: UInt16)
        case udp(port: UInt16)
    }
  
    /// Response to a CoAP request
    public enum Response {
        case message(message: CoAPMessage, from: Address)   /// Response message from a peer
        case error(error: Error)    /// Error caused by a request (including a delivery timeout)
    }
    /// Response handler to be called on receiving response to a `CoAPMessage`
    public typealias ResponseHandler = (Response) -> Void

    /// Backing storage for `transport`. Written only under `tcpLifecycleLock`; read directly
    /// by the methods that already hold it, and through `transport` by everyone else.
    private var _transport: Transport
    public var transport: Transport { locked { _transport } }

    /// Lifecycle of the TCP transport. `stopped` covers both "never started" and
    /// "intentionally stopped" — the disconnect handler must not resurrect
    /// either. `connecting` is the window the old code was destroying.
    enum TcpState {
        case stopped
        case connecting
        case connected
    }

    /// Guarded by `tcpLifecycleLock` on both sides — see rule 1 there.
    private var tcpSocket: GCDAsyncSocket?
    private var udpSocket: GCDAsyncUdpSocket?

    private var _tcpState: TcpState = .stopped

    /// TCP lifecycle state, for callers outside the lock (tests). Mutated only through
    /// `_tcpState`, under the lock.
    var tcpState: TcpState { locked { _tcpState } }

    /// How `socketDidDisconnect` classified this instance's callbacks: the outcome of the most
    /// recent one, and how many have been classified.
    ///
    /// Each branch there already logs its decision, but `Coala.logger` is a process-wide
    /// static — every live `Coala` writes into whatever logger is installed, so a log line
    /// cannot be attributed to an instance. This can. `handled` is what lets a caller wait for
    /// the *next* callback rather than re-read the previous one's outcome, which is why every
    /// branch records, not just the interesting ones.
    struct DisconnectLog: Equatable {
        /// Exactly one applies per callback — they are the branches of `socketDidDisconnect`.
        enum Outcome: Equatable {
            /// Discarded by the identity guard: the callback belonged to a replaced socket.
            case stale
            /// Arrived on an intentionally stopped transport.
            case whileStopped
            /// Charged to an in-flight connect attempt, settling it as failed.
            case whileConnecting
            /// Dropped an established session, so one reconnect was issued.
            case whileConnected
        }

        private(set) var handled = 0
        private(set) var last: Outcome?

        mutating func record(_ outcome: Outcome) {
            handled += 1
            last = outcome
        }
    }

    /// Written under `tcpLifecycleLock`, in the same locked step as the decision it records —
    /// so a snapshot can never show an outcome the state does not match.
    private var _disconnectLog = DisconnectLog()

    /// Snapshot of `_disconnectLog`, for callers outside the lock (tests).
    var disconnectLog: DisconnectLog { locked { _disconnectLog } }

    /// Whether `tcpLifecycleLock` is free at this instant, for callers outside the lock (tests).
    ///
    /// A completion that reads this while it runs is checking rule 4 from the inside. The lock
    /// is not recursive (rule 3), so a callout still under it would otherwise surface only as a
    /// deadlock on its first re-entrant `restart()` — a hang, not a failure. `try()` never
    /// blocks, and the lock is handed straight back.
    var isLifecycleLockFree: Bool {
        guard tcpLifecycleLock.try() else { return false }
        tcpLifecycleLock.unlock()
        return true
    }

    /// Called exactly once per transport switch, with `nil` on success. Its presence decides
    /// who is told about a connect failure, not how loudly Coala logs it: a socket fault is
    /// ERROR here whether or not a caller is about to receive the same error.
    private var onTcpTransportReady: ((Error?) -> Void)?
    private let tcpSerializer = CoAPTcpSerializer()

    /// Deadline for establishing the TCP proxy connection, in seconds.
    ///
    /// CocoaAsyncSocket defaults to `withTimeout: -1` — no deadline at all — so a *blackholed*
    /// SYN hangs until the kernel gives up, roughly 75 s on Darwin. That is the expected case,
    /// not an exotic one: the fallback exists because UDP is being filtered, and the networks
    /// that filter UDP drop rather than refuse. For that whole window neither
    /// `didConnectToHost` nor `socketDidDisconnect` arrives, so `onTcpTransportReady` never
    /// fires and `CoAPService` sits `.connecting`, queueing every message and reporting
    /// nothing — rebuilding the very wedge this transport was added to route around. A refused
    /// connect fails fast and was already covered; this covers the silent case.
    ///
    /// Injected and never mutated, so it needs no synchronization: only tests want a value
    /// other than the default, and they choose it before anything connects.
    let tcpConnectTimeout: TimeInterval

    /// Guards `_transport`, `tcpSocket`, `udpSocket`, `_tcpState` and `onTcpTransportReady`.
    /// Four rules; every comment elsewhere in this file that mentions the lock is pointing at
    /// one of them.
    ///
    /// **1. Reads are guarded too, with no fast-path exemptions.** Two of these fields are
    /// strong references, where a read is a load *and* a retain — racing `setupSocket()`'s
    /// overwrite-and-release means retaining an object being deallocated underneath you, which
    /// is use-after-free rather than a stale read. One is an enum with a `String` payload,
    /// wider than a word, so a racing read tears. The "we re-check under the lock anyway"
    /// pre-checks in the delegate callbacks were therefore not free, and TSan flagged them.
    ///
    /// **2. It serializes read-then-write sequences**, across `restart()`, `stop()`,
    /// `set(transport:)` and the delegate callbacks. `CloudClient.restart()` (foreground, main
    /// thread) and the pool's tick-driven `restart()` used to be serialized for free by both
    /// landing on the main queue; the tick now has its own dispatch source, so without this
    /// `restart()`'s "connect already in flight" guard is a cross-thread check-then-act.
    ///
    /// **3. Not recursive, and the design follows from that.** A method needing the lock for
    /// more than one step takes it once at the top and calls `…Locked` helpers, which never
    /// re-lock. With a recursive lock and nested `lock()`/`unlock()` pairs, "I have unlocked,
    /// so it is safe to call out" is false at every level but the outermost — a rule that
    /// cannot be checked locally, only by tracing every caller, and whose failure mode is
    /// running arbitrary app code under the lock. One level makes it structural.
    ///
    /// **4. Bounded work may run under it; unbounded work may not.** `disconnect()` and
    /// `connect(toHost:onPort:)` are held across deliberately: each is a `dispatch_sync` onto
    /// the socket's own `socketQueue`, which never waits on `delegateQueue` or on this lock, so
    /// it always drains. Completions are the opposite — `CoAPService.didConnect` walks the
    /// queued messages, one `send()` each, i.e. crypto and socket writes — so every completion
    /// is captured-and-cleared while locked and invoked only after `unlock()`.
    private let tcpLifecycleLock = NSLock()

    /// Runs `body` under `tcpLifecycleLock` and returns its result — the read-side shorthand
    /// for the four rules above, so a plain field read does not spell out lock/defer/unlock.
    ///
    /// Deliberately *not* a `Synchronized` box per field. Two of the values it guards are
    /// written in the same locked step as `_tcpState` (see `socketDidDisconnect`), and a
    /// per-field lock cannot express that: a reader would be able to observe a counter already
    /// incremented while the state change it describes has not landed yet — a pairing that
    /// never logically existed. It would also put a second lock inside a class whose whole
    /// concurrency design is "one lock, taken once at the top" (rule 3).
    ///
    /// `body` must not take the lock again — it is not recursive. That is what the `…Locked`
    /// helpers are for.
    private func locked<R>(_ body: () -> R) -> R {
        tcpLifecycleLock.lock()
        defer { tcpLifecycleLock.unlock() }
        return body()
    }

    /// One consistent view of "which transport is live, and on which socket".
    ///
    /// `_transport`, `tcpSocket` and `udpSocket` only make sense together, and `setupSocket()`
    /// rewrites all three. Reading them one at a time — as `send()` and `isSocketConnected`
    /// used to — lets a caller observe a half-applied switch: a `.udp` transport paired with a
    /// UDP socket already closed and released. One locked snapshot makes the pairing
    /// consistent, and keeps the socket alive for the call that follows.
    private enum ActiveTransport {
        case tcp(socket: GCDAsyncSocket?, host: String, port: UInt16)
        case udp(socket: GCDAsyncUdpSocket?, port: UInt16)
    }

    /// Caller must hold `tcpLifecycleLock`.
    private func activeTransportLocked() -> ActiveTransport {
        switch _transport {
        case .tcp(let host, let port):
            return .tcp(socket: tcpSocket, host: host, port: port)
        case .udp(let port):
            return .udp(socket: udpSocket, port: port)
        }
    }

    /// For callers outside the lock.
    private func activeTransport() -> ActiveTransport { locked { activeTransportLocked() } }

    var isSocketConnected: Bool {
        // Queried after the lock is released, on the snapshot's own strong reference.
        switch activeTransport() {
        case .tcp(let socket, _, _):
            return socket?.isConnected == true
        case .udp(let socket, _):
            return socket?.isClosed() == false
        }
    }


    private(set) var resources = [CoAPResourceProtocol]()
    let messagePool = CoAPMessagePool()
    var layerStack = LayerStack()

    /// Component, responsible for discovering other compatible peers on the local network
    public let resourceDiscovery = ResourceDiscovery()

    public static let defaultPort: UInt16 = 5683

    /// External logger can be used here
    public static var logger: CoalaLogger? = DefaultLogger()

    static var keyPair = Curve25519.generateKeyPair()

    private let tcpSocketFactory: (Coala, DispatchQueue, DispatchQueue) -> GCDAsyncSocket

    public convenience init(transport: Transport, tcpConnectTimeout: TimeInterval = 10) throws {
        try self.init(transport: transport, tcpConnectTimeout: tcpConnectTimeout) { delegate, delegateQueue, socketQueue in
            GCDAsyncSocket(delegate: delegate, delegateQueue: delegateQueue, socketQueue: socketQueue)
        }
    }

    init(transport: Transport, tcpConnectTimeout: TimeInterval = 10,
         tcpSocketFactory: @escaping (Coala, DispatchQueue, DispatchQueue) -> GCDAsyncSocket) throws {
        self.tcpSocketFactory = tcpSocketFactory
        self._transport = transport
        self.tcpConnectTimeout = tcpConnectTimeout

        super.init()

        // No lock taken here or below: `self` is not reachable from any other thread yet, so
        // the `…Locked` preconditions are satisfied vacuously.
        setupSocket()

        // Object ownership, not socket setup: doing this from `setupSocket` re-ran
        // it on every transport switch, which re-armed the pool timer on whatever
        // queue drove the switch and re-appended the discovery resource each time.
        messagePool.coala = self
        resourceDiscovery.startService(coala: self)

        if let failure = startLocked() {
            LogError("Socket initialization failed", context: failure)
            throw CoalaError.portIsBusy
        }
    }

    /// Caller must hold `tcpLifecycleLock` — this rewrites all three fields that
    /// `activeTransportLocked()` snapshots together, and releases the socket it replaces
    /// — or be `init`, where `self` is not reachable from any other thread yet.
    private func setupSocket() {
        let socketQueue = DispatchQueue(label: "com.ndmsystems.coala.socketQueue", qos: .default)
        let delegateQueue = DispatchQueue(label: "com.ndmsystems.coala.delegateQueue", qos: .utility)

        switch _transport {
        case .tcp:
            tcpSocket = tcpSocketFactory(self, delegateQueue, socketQueue)
            udpSocket?.close()
            udpSocket = nil

        case .udp:
            udpSocket = GCDAsyncUdpSocket(
                delegate: self,
                delegateQueue: delegateQueue,
                socketQueue: socketQueue
            )
            tcpSocket?.disconnect()
            tcpSocket = nil
        }
    }

    /// Restart Coala.
    public func restart() {
        tcpLifecycleLock.lock()

        // A TCP connect already in flight must be left alone. Tearing it down here is what
        // turned one background/foreground cycle during the transport switch — or any send
        // landing in the same window — into a service stuck `.connecting` forever with its
        // completion discarded. CocoaAsyncSocket already queues writes issued after connect
        // started. This check and the teardown below are one locked step (rule 2): two
        // callers both reading `.connecting` would both proceed and race `connect()` on the
        // same socket, and the loser's failure path clobbers the winner's state.
        if case .tcp = _transport, _tcpState == .connecting {
            tcpLifecycleLock.unlock()
            LogDebug("Restart ignored while TCP connection is in progress",
                     context: ["reason": "connect_in_progress"])
            return
        }

        let completion = stopLocked()
        // A *fresh* socket, not the one `stopLocked()` just disconnected. `disconnect()`
        // delivers `socketDidDisconnect` asynchronously (`closeWithError:` does
        // `dispatch_async(delegateQueue, …)`), so on a reused instance that callback lands
        // after the reconnect below has begun — and the identity guard cannot tell the two
        // apart, because it *is* the same object. It would then read `.connecting`, conclude
        // the new connect had failed, and reset the state to `.stopped` mid-connect: the
        // in-flight guard above stops protecting the attempt, and if the attempt does fail
        // its disconnect is misread as an intentional stop, so no completion fires at all.
        // Replacing the socket makes the stale callback filterable by the guard that already
        // exists.
        setupSocket()
        let failure = startLocked()

        tcpLifecycleLock.unlock()

        if let failure = failure { LogError("Socket initialization failed", context: failure) }
        completion?(CoalaError.tcpConnectCancelled)   // rule 4
    }

    /// Stop listening to all incoming messages
    public func stop() {
        tcpLifecycleLock.lock()
        let completion = stopLocked()
        tcpLifecycleLock.unlock()

        completion?(CoalaError.tcpConnectCancelled)
    }

    /// The teardown half of `stop()`: state mutation and the socket call, but *not* firing
    /// the transport-switch completion — that is handed back for the caller to invoke after
    /// releasing the lock (rule 4). Caller must hold `tcpLifecycleLock`.
    private func stopLocked() -> ((Error?) -> Void)? {
        let active = activeTransportLocked()
        var completion: ((Error?) -> Void)?
        if case .tcp = active {
            _tcpState = .stopped
            // Abandoning an in-flight connect must not leave the caller waiting on a
            // completion that can now never arrive. Captured and cleared here so it fires
            // exactly once, even when a stale delegate callback races a fresh transition for
            // the same slot.
            completion = onTcpTransportReady
            onTcpTransportReady = nil
        }

        switch active {
        case .tcp(let socket, _, _):
            socket?.disconnect()

        case .udp(let socket, _):
            socket?.close()
        }

        return completion
    }

    /// Caller must hold `tcpLifecycleLock`. Returns the log context of the failure, if any —
    /// the logger is app code, so every caller emits it after releasing the lock (rule 4).
    ///
    /// This used to lock internally and release before `connect()`, which was dead code: every
    /// caller but `init` already holds the lock, so that `unlock()` only decremented a
    /// recursion count and the connect ran under the lock regardless (rule 4 says that is
    /// fine). Requiring the lock states what actually happens.
    private func startLocked() -> [String: Any]? {
        // One step: mark the attempt in flight *and* snapshot the socket it applies to, so
        // the connect cannot be issued against a socket a concurrent `setupSocket()` has
        // already replaced and released.
        let active = activeTransportLocked()
        if case .tcp = active {
            // Mark every attempt, not just the one `set(transport:)` starts, so a reconnect is
            // equally protected from a concurrent `restart()` tearing it down.
            _tcpState = .connecting
        }

        do {
            switch active {
            case .tcp(let socket, let host, let port):
                // A deadline, not CocoaAsyncSocket's `-1` default: see `tcpConnectTimeout`. On
                // expiry the socket closes itself, which lands in `socketDidDisconnect`'s
                // `.connecting` case and reports the failure exactly once.
                try socket?.connect(toHost: host, onPort: port, withTimeout: tcpConnectTimeout)

            case .udp(let socket, let port):
                try socket?.bind(toPort: port)
                try socket?.beginReceiving()
                try socket?.joinMulticastGroup(ResourceDiscovery.multicastAddress)
            }
            return nil

        } catch {
            if case .tcp = active {
                _tcpState = .stopped
            }
            var context = LogContext.error(error, ["transport": _transport.logName])
            if case .udp(_, let port) = active, port != 0 { context["local_port"] = Int(port) }
            return context
        }
    }

    public func set(transport: Coala.Transport, completion: @escaping ((Error?) -> Void)) throws {
        tcpLifecycleLock.lock()

        let switchContext = ["from_transport": _transport.logName, "to_transport": transport.logName]
        // Abandons whatever transport switch, if any, was still pending. Fired after the
        // unlock below, like every other completion here.
        let stopCompletion = stopLocked()

        _transport = transport

        setupSocket()

        if case .tcp = transport {
            onTcpTransportReady = completion
        }
        // `startLocked()` owns the state: `.connecting` on the way in, back to `.stopped` if
        // it fails.
        let failure = startLocked()
        if failure != nil {
            // The caller learns about this from the throw; drop the stored completion so it
            // cannot fire as well.
            onTcpTransportReady = nil
        }

        tcpLifecycleLock.unlock()

        LogDebug("Transport switch requested", context: switchContext)
        stopCompletion?(CoalaError.tcpConnectCancelled)

        if let failure = failure {
            // The throw tells the caller too, but a socket that cannot even start is a
            // transport fault: ERROR here, like the init/restart/reconnect sites.
            LogError("Socket initialization failed", context: failure)
            throw CoalaError.portIsBusy
        }
        // UDP has no delegate-driven completion path, so it must fire `completion` itself —
        // but only after unlocking: `completion` is unbounded app code.
        if case .udp = transport {
            completion(nil)
        }
    }

    public func configureMessagePool(
        expirationTimeout: TimeInterval,
        totalResendCount: Int
    ) {
        // One write, so a tick can never see the new interval against the old attempt count.
        var settings = messagePool.settings
        settings.resendTimeInterval = expirationTimeout
        settings.maxAttempts = totalResendCount
        messagePool.settings = settings
    }

    public func configureMessagePoolTimeouts(
        for urlPaths: [UriPathConfig]
    ) {
        messagePool.longRunningUrlPaths = urlPaths
    }

    deinit {
        messagePool.stopTimer()

        // No lock. `deinit` runs only once the last reference is gone, so no other thread can
        // be inside a method on `self`: `GCDAsyncSocket` holds its delegate `__weak` and
        // promotes it to a strong reference for the duration of each callback
        // (`GCDAsyncSocket.m`, `closeWithError:`), and both timer handlers resolve `self`
        // strongly with `guard let`. Any of those in flight keeps the object alive, so it
        // cannot overlap with this. The lock here was self-evidently uncontended.
        _tcpState = .stopped
        let tcp = tcpSocket
        let udp = udpSocket
        tcpSocket = nil
        udpSocket = nil
        onTcpTransportReady = nil

        // Each hops onto the socket's own `socketQueue`.
        tcp?.disconnect()
        udp?.close()
    }

    /// Send CoAPMessage to a reciever specified in `message.url`
    public func send(_ message: CoAPMessage) throws {
        if !isSocketConnected {
            restart()
        }
        guard var address = message.address else {
            throw CoalaError.addressNotSet
        }
        var processedMessage = message
        do {
            try layerStack.run(&processedMessage, coala: self, toAddress: &address)
            let data = try CoAPSerializer.dataWithCoAPMessage(processedMessage)

            // One locked snapshot, not three unlocked field reads: this runs on the pool's
            // timer queue for as long as anything is in flight, and the UDP→TCP fallback
            // rewrites all three fields from another queue — and it fires *because* the pool
            // is expiring messages, so the tick is busy at exactly that instant.
            // `encodeTcpFrame` touches no shared state, so it stays outside the lock.
            switch activeTransport() {
            case .tcp(let socket, _, _):
                let tcpFrame = try tcpSerializer.encodeTcpFrame(with: address, data: data)
                socket?.write(tcpFrame, withTimeout: -1, tag: 0)

            case .udp(let socket, _):
                socket?.send(data, toHost: address.host, port: address.port, withTimeout: -1, tag: 0)
            }

            messagePool.push(message: message)

        } catch {
            if !shouldSilentlyIgnore(error) {
                throw error
            }
        }
    }

    public func send(
        _ message: CoAPMessage,
        block2DownloadProgress: ((Data) -> Void)?
    ) throws {
        if let token = message.token {
          layerStack.arqLayer.setBlock2DownloadProgress(block2DownloadProgress, forToken: token)
        }
        try send(message)
    }

    /// Add resource to Coala
    public func addResource(_ resource: CoAPResourceProtocol) {
        if let resource = resource as? CoAPResource {
            resource.coala = self
        }
        resources.append(resource)
    }

    /// Remove resources from Coala
    public func removeResources(forPath path: String) {
        while let index = resources.firstIndex(where: { $0.path == path }) {
            if let resource = resources[index] as? CoAPResource {
                resource.coala = nil
            }
            resources.remove(at: index)
        }
    }

    private func decodePayload(from address: Address, payload: Data) {
        var address = address
        var message: CoAPMessage
        do {
            message = try CoAPSerializer.coapMessageWithData(payload)
        } catch {
            LogError("Incoming message could not be deserialized", context: LogContext.error(error))
            return
        }
        message.address = address
        do {
            try layerStack.run(&message, coala: self, fromAddress: &address)
        } catch let error {
            logIncomingFailure(error, messageID: Int(message.messageId))
        }
    }
}

public extension Coala.Transport {
    /// Stable transport name for log context.
    var logName: String {
        switch self {
        case .tcp: return "tcp"
        case .udp: return "udp"
        }
    }
}

extension Coala.TcpState {
    /// Stable state name for log context.
    var logName: String {
        switch self {
        case .stopped: return "stopped"
        case .connecting: return "connecting"
        case .connected: return "connected"
        }
    }
}

extension Coala: GCDAsyncUdpSocketDelegate {

    public func udpSocket(_ sock: GCDAsyncUdpSocket, didSendDataWithTag tag: Int) {}

    public func udpSocket(
        _ sock: GCDAsyncUdpSocket,
        didNotSendDataWithTag tag: Int,
        dueToError error: Error?
    ) {
        var context = LogContext.error(error, ["transport": "udp"])
        let port = sock.localPort()
        if port != 0 { context["local_port"] = Int(port) }
        LogError("UDP send failed", context: context)
    }

    public func udpSocket(_ sock: GCDAsyncUdpSocket,
                          didReceive data: Data,
                          fromAddress address: Data,
                          withFilterContext filterContext: Any?) {
        guard let address = Address(addressData: address)
            else {
                LogError("Message sender is unknown", context: ["transport": "udp"])
                return
        }
        decodePayload(from: address, payload: data)
    }

    public func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        guard sock.localPort() != 0 else { return }

        if let error = error {
            var context = LogContext.error(error, ["transport": "udp"])
            let port = sock.localPort()
            if port != 0 { context["local_port"] = Int(port) }
            LogError("UDP socket closed unexpectedly", context: context)
        }
    }

}

/// Each callback opens with the same `sock === tcpSocket` identity guard, and each performs it
/// *inside* the lock. `setupSocket()` replaces the socket on every transport switch and on
/// every `restart()`, so callbacks from a socket already retired keep arriving on that
/// socket's own (now orphaned) `delegateQueue` and must not be applied to the current one.
/// The guard cannot be hoisted out as a cheap pre-check: reading `tcpSocket` retains it, which
/// is rule 1 on `tcpLifecycleLock`.
extension Coala: GCDAsyncSocketDelegate {
    public func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        tcpLifecycleLock.lock()
        guard sock === tcpSocket else {
            tcpLifecycleLock.unlock()
            LogDebug("Ignored callback from replaced socket", context: [
                "transport": "tcp",
                "reason": "stale_callback",
                "callback": "connect"
            ])
            return
        }
        _tcpState = .connected
        let completion = onTcpTransportReady
        onTcpTransportReady = nil
        tcpLifecycleLock.unlock()

        LogDebug("TCP socket connected", context: ["transport": "tcp"])

        completion?(nil)
        sock.readData(withTimeout: -1, tag: 1)
    }

    public func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {}

    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        tcpLifecycleLock.lock()
        // This is the callback that was missing the guard. Each socket gets a *fresh*
        // `delegateQueue`, so without it a read on the previous socket's queue runs
        // `decodeTcpFrame` concurrently with the new socket's queue doing the same — and both
        // append to and `removeSubrange` one shared `Data`, which is memory-unsafe on top of
        // injecting the old session's frames into the new one.
        guard sock === tcpSocket else {
            tcpLifecycleLock.unlock()
            LogDebug("Ignored callback from replaced socket", context: [
                "transport": "tcp",
                "reason": "stale_callback",
                "callback": "read"
            ])
            return
        }
        // Decoding stays under the lock — bounded parsing, no callout (rule 4) — which is
        // what makes the guard above more than a check-then-act and makes `buffer`
        // single-owner against `flushBuffer()` below. Delivering the frames runs the whole
        // inbound layer stack, so that happens after unlocking.
        let frames = tcpSerializer.decodeTcpFrame(with: data)
        tcpLifecycleLock.unlock()

        frames.forEach {
            decodePayload(from: $0.address, payload: $0.data)
        }
        sock.readData(withTimeout: -1, tag: tag)
    }

    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        tcpLifecycleLock.lock()

        // A stale disconnect must not be charged to the new socket's in-flight attempt — this
        // is the guard `restart()`'s `setupSocket()` exists to let fire.
        guard sock === tcpSocket else {
            _disconnectLog.record(.stale)
            tcpLifecycleLock.unlock()
            LogDebug("Ignored callback from replaced socket", context: [
                "transport": "tcp",
                "reason": "stale_callback",
                "callback": "disconnect"
            ])
            return
        }

        // Captured under the lock and logged after it: interpolating the state into the log
        // line straight off the field was itself one of the races.
        let stateAtDisconnect = _tcpState

        // Only the current socket's partial frame may be dropped, and only while no other
        // delegate queue can be decoding into the same buffer — hence inside the lock, after
        // the identity check.
        tcpSerializer.flushBuffer()

        var completion: ((Error?) -> Void)?
        var initializationFailure: [String: Any]?

        switch stateAtDisconnect {
        case .stopped:
            // Intentional stop. Reconnecting here is what made `stop()` unable
            // to stop a TCP Coala at all.
            _disconnectLog.record(.whileStopped)

        case .connecting:
            // The connect never completed. Report it once instead of retrying without pacing —
            // that loop burned thousands of attempts a second and surfaced nothing to the
            // caller. Also the path a `tcpConnectTimeout` expiry arrives on.
            _disconnectLog.record(.whileConnecting)
            _tcpState = .stopped
            completion = onTcpTransportReady
            onTcpTransportReady = nil

        case .connected:
            // An established session dropped. Re-establish once; if that connect also fails
            // it lands in `.connecting` above and settles, and the next send re-drives it
            // through `restart()`.
            _disconnectLog.record(.whileConnected)
            _tcpState = .connecting
            initializationFailure = startLocked()
        }

        tcpLifecycleLock.unlock()

        if let failure = initializationFailure { LogError("Socket initialization failed", context: failure) }

        // The socket's own error is the reason. Anything the transport layer did not ask for
        // is ERROR — even when a `set(transport:)` caller is about to receive the same error,
        // because its own record stays DEBUG and this is the one production entry. That
        // covers a connect that never completed, a dropped session, and a disconnect that
        // carries an error while stopped: `disconnect()` itself reports `nil`, so an error
        // there is the peer or the OS closing the socket just as `stop()` ran. Only the
        // error-free disconnect an intentional stop produces is expected, hence DEBUG.
        var context = LogContext.error(err, ["transport": "tcp"])
        context["tcp_state"] = stateAtDisconnect.logName
        switch stateAtDisconnect {
        case .stopped where err == nil:
            LogDebug("TCP socket disconnected", context: context)
        case .stopped, .connected:
            LogError("TCP socket disconnected unexpectedly", context: context)
        case .connecting:
            LogError("TCP connection failed", context: context)
        }

        completion?(err ?? CoalaError.tcpConnectFailed)
    }
}

extension Coala {
    func logIncomingFailure(_ error: Error, messageID: Int) {
        if shouldSilentlyIgnore(error) { return }

        if case SecurityLayer.SecurityLayerError.sourceMessageNotFound = error {
            LogDebug("Response has no matching request", context: ["message_id": messageID])
            return
        }

        LogWarn("Incoming message processing failed",
                context: LogContext.error(error, ["message_id": messageID]))
    }

    func shouldSilentlyIgnore(_ error: Error) -> Bool {
        if let error = error as? ARQLayerError {
            switch error {
            case .arqTransferIncomplete, .splittingToBlocks:
                return true
            default:
                return false
            }
        }
        if let error = error as? SecurityLayer.SecurityLayerError, error == .handshakeInProgress {
            return true
        }
        return false
    }
}

// MARK: - Delivery statistics
extension Coala {
    public func getStatistics(for address: Address, scheme: CoAPMessage.Scheme) -> DeliveryStatistics? {
        messagePool.getStatistics(for: address, scheme: scheme)
    }

    public func getStatistics(for message: CoAPMessage) -> DeliveryStatistics? {
        guard let address = message.address else { return nil }
        return messagePool.getStatistics(for: address, scheme: message.scheme)
    }

    public func flushStatistics(for address: Address, scheme: CoAPMessage.Scheme) {
        messagePool.flushStatistics(for: address, scheme: scheme)
    }

    public func flushAllStatistics() {
        messagePool.flushAllStatistics()
    }
}

public enum CoalaError: LocalizedError {
    case addressNotSet
    case portIsBusy
    /// The TCP proxy connection could not be established.
    case tcpConnectFailed
    /// An in-flight TCP connect was abandoned by an explicit stop.
    case tcpConnectCancelled
    /// Payload exceeds the TCP proxy frame's 16-bit size field.
    case tcpFrameTooLarge(byteCount: Int)
    /// Destination host cannot be encoded into the frame's fixed 4-byte IPv4 field.
    case tcpDestinationNotIPv4(host: String)
    public var errorDescription: String? {
        switch self {
        case .portIsBusy:
            return "Port is taken by another application"
        case .addressNotSet:
            return "Message destination not set"
        case .tcpConnectFailed:
            return "Could not connect to the TCP proxy"
        case .tcpConnectCancelled:
            return "TCP proxy connection was cancelled"
        case .tcpFrameTooLarge(let byteCount):
            return "Message of \(byteCount) bytes exceeds the \(UInt16.max) byte TCP frame limit"
        case .tcpDestinationNotIPv4(let host):
            return "TCP proxy destination \"\(host)\" is not an IPv4 address"
        }
    }
}
