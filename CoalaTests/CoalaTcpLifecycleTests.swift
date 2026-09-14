import XCTest
@testable import Coala

// swiftlint:disable type_body_length
/// Exercises the TCP transport lifecycle against a scripted socket, so every interleaving is
/// *constructed* on the test thread instead of raced against real sockets, helper threads and
/// dispatch queues.
///
/// The previous version of this class drove real loopback sockets and asserted timing — "a
/// concurrent `restart()` returns within N seconds while a completion is parked". Every one of
/// those waits went through the shared libdispatch pool (`connect()` parks a worker for the
/// OS SYN timeout; `disconnect()`/`connect(toHost:)` are `dispatch_sync` onto queues that need
/// a worker), so a loaded CI agent could hold any of them past any budget and the failure was
/// indistinguishable from the bug under test.
///
/// A real `GCDAsyncSocket` delivers every delegate callback asynchronously on its
/// `delegateQueue`, and never after `disconnect()` (`closeWithError:` bumps its state index,
/// which retires every pending `didConnect`). `FakeTcpSocket` therefore never calls back into
/// `Coala` on its own: each test delivers the callback it wants, at the point in the
/// interleaving it wants — and only interleavings a real socket can produce.
final class CoalaTcpLifecycleTests: XCTestCase {

    /// Where every fake connects to. Nothing listens there and nothing needs to.
    private let peerHost = "192.0.2.1"
    private let peerPort: UInt16 = 5683

    /// Every socket the factory handed out, in creation order: index 0 is the constructor's,
    /// and each `set(transport:)` or socket-replacing `restart()` appends one.
    private var sockets = [FakeTcpSocket]()

    /// Every `Coala` a test builds, stopped at teardown so none outlives its test.
    private var coalas = [Coala]()

    override func tearDown() {
        coalas.forEach { $0.stop() }
        coalas.removeAll()
        sockets.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    private func makeCoala(tcpConnectTimeout: TimeInterval = 10) throws -> Coala {
        let coala = try Coala(transport: .tcp(host: peerHost, port: peerPort),
                              tcpConnectTimeout: tcpConnectTimeout) { [weak self] delegate, delegateQueue, queue in
            let socket = FakeTcpSocket(delegate: delegate, delegateQueue: delegateQueue, socketQueue: queue)
            self?.sockets.append(socket)
            return socket
        }
        coalas.append(coala)
        return coala
    }

    /// Plays the connect success a real socket would deliver on its delegate queue.
    private func deliverConnect(_ coala: Coala, on socket: FakeTcpSocket) {
        socket.connected = true
        coala.socket(socket, didConnectToHost: peerHost, port: peerPort)
    }

    /// Switches `coala` to TCP and delivers the connect success, returning the live socket.
    private func connect(_ coala: Coala) throws -> FakeTcpSocket {
        var completions = [Error?]()
        try coala.set(transport: .tcp(host: peerHost, port: peerPort)) { completions.append($0) }
        let socket = try XCTUnwrap(sockets.last)
        deliverConnect(coala, on: socket)
        XCTAssertEqual(completions.count, 1, "sanity: the switch completed exactly once")
        XCTAssertNil(try XCTUnwrap(completions.first), "sanity: the switch completed without error")
        XCTAssertTrue(coala.isSocketConnected, "sanity: connected")
        return socket
    }

    private func installRecordingLogger() -> (logger: RecordingLogger, original: CoalaLogger?) {
        let logger = RecordingLogger()
        let original = Coala.logger
        Coala.logger = logger
        return (logger, original)
    }

    private func error(_ code: GCDAsyncSocketError.Code) -> NSError {
        NSError(domain: GCDAsyncSocketErrorDomain, code: code.rawValue)
    }

    // MARK: - Connect outcomes

    /// A TCP connect that never succeeds previously left the completion unfired:
    /// the success-only closure swallowed `false`, so `CoAPService` sat in
    /// `.connecting` forever, queueing every message with no error and no timeout.
    func testRefusedTcpConnectReportsAnError() throws {
        let logging = installRecordingLogger()
        defer { Coala.logger = logging.original }
        let coala = try makeCoala()

        var completions = [Error?]()
        try coala.set(transport: .tcp(host: peerHost, port: peerPort)) { completions.append($0) }
        let socket = try XCTUnwrap(sockets.last)
        XCTAssertEqual(coala.tcpState, .connecting, "sanity: the attempt is in flight")

        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        coala.socketDidDisconnect(socket, withError: refused)

        XCTAssertEqual(completions.count, 1, "a refused TCP connect must surface an error")
        XCTAssertTrue(try XCTUnwrap(completions.first) as NSError? === refused)
        XCTAssertEqual(coala.tcpState, .stopped, "a failed connect must settle")
        XCTAssertEqual(coala.disconnectLog.last, .whileConnecting)
        // The completion above received the error too, but a refused connect is a transport
        // fault and Coala's record is the production one: ERROR.
        let failures = logging.logger.records.filter { $0.message == "TCP connection failed" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.allSatisfy { $0.level == .error })
        XCTAssertTrue(failures.allSatisfy { $0.context["transport"] as? String == "tcp" })
    }

    /// The other half of the same wedge, and the half that actually happens in the field. A
    /// refused connect fails *fast*, so the test above passes even with no connect deadline at
    /// all. A **blackholed** SYN does not fail: CocoaAsyncSocket's default is `withTimeout: -1`,
    /// neither `didConnectToHost` nor `socketDidDisconnect` arrives, `onTcpTransportReady`
    /// never fires, and `CoAPService` sits `.connecting` for the ~75 s the Darwin kernel takes
    /// to give up — queueing every message and reporting nothing.
    ///
    /// This is not a corner case: the TCP fallback exists because UDP is being filtered, and
    /// the networks that filter UDP (captive portals, corporate egress) drop rather than refuse.
    ///
    /// Coala's half of the contract is that *every* connect carries its deadline — the
    /// constructor's, the switch's, a reconnect's — and that the expiry CocoaAsyncSocket then
    /// reports (`GCDAsyncSocketConnectTimeoutError`, via `socketDidDisconnect`) settles the
    /// attempt with that identity. That the vendored library honours the deadline it is given
    /// is its contract, not this class's.
    func testBlackholedTcpConnectReportsAnErrorInsteadOfHanging() throws {
        let coala = try makeCoala(tcpConnectTimeout: 1)

        var completions = [Error?]()
        try coala.set(transport: .tcp(host: peerHost, port: peerPort)) { completions.append($0) }
        let socket = try XCTUnwrap(sockets.last)

        let deadlines = sockets.flatMap { $0.connectCalls }.map { $0.timeout }
        XCTAssertEqual(deadlines, [1, 1],
                       "every connect must carry Coala's deadline, not CocoaAsyncSocket's -1 default")

        let timedOut = error(.connectTimeoutError)
        coala.socketDidDisconnect(socket, withError: timedOut)

        XCTAssertEqual(completions.count, 1, "a blackholed TCP connect must surface an error rather than hang")
        XCTAssertTrue(try XCTUnwrap(completions.first) as NSError? === timedOut,
                      "the failure must be the connect timeout, exactly as the socket reported it")
        XCTAssertEqual(coala.tcpState, .stopped,
                       "a timed-out connect must settle, not stay marked in flight forever")
    }

    // MARK: - restart() and stop()

    /// The foreground wedge. `willEnterForeground` → `CloudClient.restart` →
    /// `GUMService.restart` → `Coala.restart` → `stop()` cleared the only stored
    /// completion, and nothing re-armed it: one background/foreground cycle
    /// inside the connect window left the service `.connecting` forever. A
    /// send during the same window self-inflicts it via `if !isSocketConnected`.
    func testRestartDuringConnectDoesNotAbandonTheConnect() throws {
        let coala = try makeCoala()

        var completions = [Error?]()
        try coala.set(transport: .tcp(host: peerHost, port: peerPort)) { completions.append($0) }
        let socket = try XCTUnwrap(sockets.last)
        let socketCount = sockets.count

        coala.restart()

        XCTAssertEqual(sockets.count, socketCount, "a restart mid-connect must leave the socket in place")
        XCTAssertEqual(socket.disconnectCount, 0, "a restart mid-connect must not tear the connect down")
        XCTAssertTrue(completions.isEmpty, "the completion must stay armed for the connect's outcome")
        XCTAssertEqual(coala.tcpState, .connecting)

        deliverConnect(coala, on: socket)

        XCTAssertEqual(completions.count, 1, "foregrounding mid-connect must not abandon the connect")
        XCTAssertNil(try XCTUnwrap(completions.first))
        XCTAssertTrue(coala.isSocketConnected, "the connection must still be established")
    }

    /// `socketDidDisconnect` reconnected unconditionally, so an intentional
    /// `stop()` was undone the instant it took effect: a TCP Coala could not be
    /// stopped at all.
    func testStopActuallyStopsATcpCoala() throws {
        let coala = try makeCoala()
        let socket = try connect(coala)
        let connectsBefore = socket.connectCalls.count
        let socketsBefore = sockets.count

        let logging = installRecordingLogger()
        defer { Coala.logger = logging.original }

        coala.stop()
        XCTAssertEqual(socket.disconnectCount, 1, "stop() must disconnect the live socket")
        // The disconnect the stop itself produced lands afterwards, error-free.
        coala.socketDidDisconnect(socket, withError: nil)

        XCTAssertFalse(coala.isSocketConnected, "stop() must actually stop a TCP Coala")
        XCTAssertEqual(coala.tcpState, .stopped)
        XCTAssertEqual(coala.disconnectLog.last, .whileStopped)
        XCTAssertEqual(socket.connectCalls.count, connectsBefore, "an intentional stop must not reconnect")
        XCTAssertEqual(sockets.count, socketsBefore, "an intentional stop must not dial a fresh socket either")
        let stopped = logging.logger.records.filter { $0.message == "TCP socket disconnected" }
        XCTAssertEqual(stopped.count, 1)
        XCTAssertTrue(stopped.allSatisfy { $0.level == .debug })
        XCTAssertTrue(stopped.allSatisfy { $0.context["transport"] as? String == "tcp" })
    }

    func testUnexpectedConnectedDisconnectRemainsVisibleAtRecoveryOwner() throws {
        let coala = try makeCoala()
        let socket = try connect(coala)
        let connectsBefore = socket.connectCalls.count

        let logging = installRecordingLogger()
        defer { Coala.logger = logging.original }

        // The peer went away: the socket reports it closed, with the library's own reason.
        socket.connected = false
        coala.socketDidDisconnect(socket, withError: error(.closedError))

        XCTAssertEqual(coala.disconnectLog.last, .whileConnected)
        XCTAssertEqual(coala.tcpState, .connecting, "a dropped session issues exactly one reconnect")
        XCTAssertEqual(socket.connectCalls.count, connectsBefore + 1, "the reconnect reuses the socket")
        let failures = logging.logger.records.filter { $0.message == "TCP socket disconnected unexpectedly" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.last?.level, .error)
        XCTAssertEqual(failures.last?.context["transport"] as? String, "tcp")
        XCTAssertEqual(failures.last?.context["tcp_state"] as? String, "connected")
    }

    /// `restart()` tears the socket down and immediately reconnects it, and must end up
    /// genuinely connected again — not merely "not stopped".
    func testRestartWhileConnectedReestablishesTheConnection() throws {
        let coala = try makeCoala()
        let first = try connect(coala)
        let socketsBefore = sockets.count

        coala.restart()

        XCTAssertEqual(first.disconnectCount, 1, "restart must tear the live socket down")
        XCTAssertEqual(sockets.count, socketsBefore + 1, "restart must dial a fresh socket")
        let second = try XCTUnwrap(sockets.last)
        XCTAssertEqual(second.connectCalls, [.init(host: peerHost, port: peerPort, timeout: 10)],
                       "the fresh socket must dial the same peer")
        XCTAssertEqual(coala.tcpState, .connecting)
        XCTAssertFalse(coala.isSocketConnected, "not connected until the new socket says so")

        deliverConnect(coala, on: second)

        XCTAssertEqual(coala.tcpState, .connected)
        XCTAssertTrue(coala.isSocketConnected, "restart must re-establish a connected session")
    }

    /// Every connect attempt must be marked in flight, not just the one started
    /// by `set(transport:)`. A reconnect driven by `restart()` is otherwise
    /// unprotected, so a send landing in *its* window tears it down — the same
    /// wedge, one path further along.
    ///
    /// The interesting case is the *previous* teardown's disconnect callback landing after the
    /// reconnect has already started. `disconnect()` reports asynchronously, so that is the
    /// order a real socket produces; `restart()` replaces the socket precisely so the identity
    /// guard can recognise the callback as stale. Without that replacement it passes the guard —
    /// it is the same object — reads `.connecting`, concludes the reconnect failed and resets
    /// the state to `.stopped` underneath a live connect.
    func testRestartMarksTheReconnectAsInFlight() throws {
        let coala = try makeCoala()
        let first = try connect(coala)
        let before = coala.disconnectLog

        coala.restart()
        // The teardown's own callback, arriving once the socket has already been replaced.
        coala.socketDidDisconnect(first, withError: nil)

        XCTAssertEqual(coala.disconnectLog.handled, before.handled + 1)
        XCTAssertEqual(coala.disconnectLog.last, .stale,
                       "the teardown's own disconnect must be recognised as stale, not charged "
                       + "to the reconnect")
        XCTAssertEqual(coala.tcpState, .connecting,
                       "a reconnect must be marked in flight so a concurrent send cannot tear it down")
    }

    func testCallbacksFromReplacedSocketsAreDebugNoise() throws {
        let coala = try makeCoala()
        let logging = installRecordingLogger()
        defer { Coala.logger = logging.original }
        let replaced = GCDAsyncSocket(delegate: nil, delegateQueue: DispatchQueue.main)

        coala.socket(replaced, didConnectToHost: peerHost, port: peerPort)
        coala.socket(replaced, didRead: Data(), withTag: 7)
        coala.socketDidDisconnect(replaced, withError: nil)

        let callbacks = logging.logger.records.filter {
            $0.message == "Ignored callback from replaced socket"
        }
        XCTAssertEqual(callbacks.map { $0.context["callback"] as? String }, [
            "connect", "read", "disconnect"
        ])
        XCTAssertTrue(callbacks.allSatisfy { $0.level == .debug })
        XCTAssertTrue(callbacks.allSatisfy {
            $0.context["transport"] as? String == "tcp"
                && $0.context["reason"] as? String == "stale_callback"
        })
    }

    // MARK: - Rule 4: completions run after the lock is released

    /// A `set(transport:)` completion that records, at the instant it runs, whether
    /// `tcpLifecycleLock` had already been released — rule 4 observed from inside the callout.
    ///
    /// This replaces the old "a concurrent `restart()` returns within N seconds" assertion, which
    /// measured the scheduler as much as the lock. The probe is non-blocking; on the same thread
    /// it can only read "taken" if the caller's own frames still hold the lock. Re-entering
    /// `restart()` instead — what `CoAPService.didConnect` really does via `send()` — would hang
    /// the run on regression rather than fail it, because the lock is not recursive.
    private final class CompletionProbe {
        private(set) var outcomes = [Error?]()
        private(set) var lockWasFree = [Bool]()

        /// The completion to hand to `set(transport:)`.
        func completion(for coala: Coala) -> (Error?) -> Void {
            { [unowned coala] outcome in
                self.outcomes.append(outcome)
                self.lockWasFree.append(coala.isLifecycleLockFree)
            }
        }
    }

    /// The completion is arbitrary app code (`CoAPService.didConnect` → a `send()` per queued
    /// message, i.e. crypto and socket writes) that can itself call back into
    /// `restart()`/`stop()`. If the lock were still held while it ran, every other thread
    /// wanting `restart()`/`stop()` — including a concurrent foreground `CloudClient.restart()`
    /// on main — would block for as long as it takes. Both ways a connect can settle are covered:
    /// success via `didConnectToHost`, failure via `socketDidDisconnect` while `.connecting`.
    func testTransportReadyCompletionDoesNotBlockOtherThreadsFromTheLock() throws {
        for settles in ["success", "failure"] {
            let coala = try makeCoala()
            let probe = CompletionProbe()
            try coala.set(transport: .tcp(host: peerHost, port: peerPort), completion: probe.completion(for: coala))
            let socket = try XCTUnwrap(sockets.last)

            switch settles {
            case "success":
                deliverConnect(coala, on: socket)
            default:
                coala.socketDidDisconnect(socket, withError: error(.connectTimeoutError))
            }

            XCTAssertEqual(probe.outcomes.count, 1, settles)
            XCTAssertEqual(probe.lockWasFree, [true],
                           "\(settles): the completion ran while tcpLifecycleLock was still held")
        }
    }

    /// N-2 remnant: `stop()` is called *nested* from `set(transport:)`. In that
    /// nesting, `stop()`'s own `unlock()` only decremented the recursive count —
    /// `set(transport:)`'s outer `lock()` still held it — so firing the abandoned
    /// switch's completion from inside that nested call still ran with the lock
    /// held in every way that matters to another thread. `stopLocked()` closes
    /// this by handing the completion back up to `set(transport:)`'s own unlock
    /// instead of firing it inline.
    func testAbandonedTransportSwitchCompletionDoesNotBlockOtherThreadsWhenCancelledBySetTransport() throws {
        let coala = try makeCoala()
        let probe = CompletionProbe()
        var replacementOutcomes = [Error?]()
        try coala.set(transport: .tcp(host: peerHost, port: peerPort), completion: probe.completion(for: coala))
        XCTAssertTrue(probe.outcomes.isEmpty, "sanity: the first switch is still pending")

        // Cancel it via a second `set(transport:)` — the nested `set(transport:)` →
        // `stopLocked()` path under test.
        try coala.set(transport: .tcp(host: peerHost, port: peerPort)) { replacementOutcomes.append($0) }

        XCTAssertEqual(probe.outcomes.count, 1, "the abandoned switch must be told exactly once")
        guard case CoalaError.tcpConnectCancelled? = probe.outcomes.first ?? nil else {
            return XCTFail("the abandoned switch must be told it was cancelled: \(probe.outcomes)")
        }
        XCTAssertEqual(probe.lockWasFree, [true],
                       "the abandoned completion ran while tcpLifecycleLock was still held")
        XCTAssertTrue(replacementOutcomes.isEmpty, "the replacement switch is still in flight")
        XCTAssertEqual(coala.tcpState, .connecting)
    }

    /// The same abandonment through `stop()` itself, the other caller of `stopLocked()`.
    func testAbandonedTransportSwitchCompletionDoesNotBlockOtherThreadsWhenCancelledByStop() throws {
        let coala = try makeCoala()
        let probe = CompletionProbe()
        try coala.set(transport: .tcp(host: peerHost, port: peerPort), completion: probe.completion(for: coala))
        coala.stop()

        XCTAssertEqual(probe.outcomes.count, 1, "the abandoned switch must be told exactly once")
        guard case CoalaError.tcpConnectCancelled? = probe.outcomes.first ?? nil else {
            return XCTFail("the abandoned switch must be told it was cancelled: \(probe.outcomes)")
        }
        XCTAssertEqual(probe.lockWasFree, [true],
                       "the abandoned completion ran while tcpLifecycleLock was still held")
        XCTAssertEqual(coala.tcpState, .stopped)
    }

    // MARK: - Exactly once

    /// `onTcpTransportReady` is captured-and-cleared under the lock, so however an app-driven
    /// `stop()` interleaves with the connect's own outcome, exactly one of them delivers the
    /// completion. The interleavings are enumerated rather than raced: with one lock taken once
    /// per call, the sequential orderings *are* the reachable ones, and a herd of threads can
    /// only sample them non-deterministically.
    ///
    /// "Stop, then a late connect success" is deliberately absent: a real socket cannot produce
    /// it, because `disconnect()` retires every pending `didConnect` before it returns.
    func testTransportReadyCompletionFiresExactlyOnceHoweverStopInterleavesWithTheConnectOutcome() throws {
        let cancelled: (Error?) -> Bool = { outcome in
            if case CoalaError.tcpConnectCancelled? = outcome { return true }
            return false
        }
        let failure = error(.connectTimeoutError)
        struct Interleaving {
            let name: String
            let steps: (Coala, FakeTcpSocket) -> Void
            let expected: (Error?) -> Bool
        }
        let interleavings = [
            Interleaving(name: "stop, stop", steps: { coala, _ in
                coala.stop()
                coala.stop()
            }, expected: cancelled),
            Interleaving(name: "stop, then the stop's own disconnect", steps: { coala, socket in
                coala.stop()
                coala.socketDidDisconnect(socket, withError: nil)
            }, expected: cancelled),
            Interleaving(name: "connect success, then stop", steps: { coala, socket in
                self.deliverConnect(coala, on: socket)
                coala.stop()
            }, expected: { $0 == nil }),
            Interleaving(name: "connect failure, then stop", steps: { coala, socket in
                coala.socketDidDisconnect(socket, withError: failure)
                coala.stop()
            }, expected: { $0 as NSError? === failure })
        ]

        for interleaving in interleavings {
            let coala = try makeCoala()
            var completions = [Error?]()
            try coala.set(transport: .tcp(host: peerHost, port: peerPort)) { completions.append($0) }
            let socket = try XCTUnwrap(sockets.last)

            interleaving.steps(coala, socket)

            XCTAssertEqual(completions.count, 1,
                           "\(interleaving.name): the transport-ready completion must fire exactly once")
            XCTAssertTrue(interleaving.expected(completions.first ?? nil),
                          "\(interleaving.name): unexpected outcome \(String(describing: completions.first))")
        }
    }
}
// swiftlint:enable type_body_length

/// A `GCDAsyncSocket` that records what `Coala` asks of it and connects to nothing.
///
/// It never calls back into its delegate: a real socket delivers every callback asynchronously
/// on `delegateQueue`, so a fake that delivered `socketDidDisconnect` from inside `disconnect()`
/// would run it under `tcpLifecycleLock` — an interleaving that cannot happen — and deadlock.
/// Tests deliver callbacks themselves, in the order a real socket would.
private final class FakeTcpSocket: GCDAsyncSocket {

    struct ConnectCall: Equatable {
        let host: String
        let port: UInt16
        let timeout: TimeInterval
    }

    private(set) var connectCalls = [ConnectCall]()
    private(set) var disconnectCount = 0

    /// What `isConnected` reports. Set by the test alongside the connect callback it delivers,
    /// cleared by `disconnect()`.
    var connected = false

    override var isConnected: Bool { connected }

    override func connect(toHost host: String, onPort port: UInt16, withTimeout timeout: TimeInterval) throws {
        connectCalls.append(ConnectCall(host: host, port: port, timeout: timeout))
    }

    override func disconnect() {
        connected = false
        disconnectCount += 1
    }

    override func readData(withTimeout timeout: TimeInterval, tag: Int) {}
}
