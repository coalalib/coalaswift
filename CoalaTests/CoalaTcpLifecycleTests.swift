import Darwin
import XCTest
@testable import Coala

/// Exercises the TCP transport lifecycle against real loopback sockets, so both
/// connect success and connect failure are deterministic and fast rather than
/// depending on a live network.
final class CoalaTcpLifecycleTests: XCTestCase, GCDAsyncSocketDelegate {

    /// Accepted client sockets are retained so the connections stay open for the
    /// lifetime of a test that needs a live listener.
    private var acceptedSockets = [GCDAsyncSocket]()

    /// Raw BSD descriptors opened by `blackholedLoopbackPort()`, closed together
    /// at teardown so the blackhole stops existing with the test that needed it.
    private var rawDescriptors = [Int32]()

    /// Every `Coala` a test builds, stopped at teardown *before* the loopback peers are
    /// torn down.
    ///
    /// An instance that outlives its test is not inert: `socketDidDisconnect`'s `.connected`
    /// branch reconnects, so disconnecting an accepted peer first makes a departing instance
    /// dial a listener that is already gone and report the failure — on a `.utility` delegate
    /// queue, i.e. whenever the scheduler gets round to it, which under CI load is comfortably
    /// inside the *next* test. Stopping first leaves every instance in `.stopped`, the one
    /// branch that neither reconnects nor reports.
    private var coalas = [Coala]()

    override func tearDown() {
        // Order matters: stopping after the peers were dropped is what produces the
        // cross-test reconnect described on `coalas`.
        coalas.forEach { $0.stop() }
        coalas.removeAll()
        acceptedSockets.forEach { $0.disconnect() }
        acceptedSockets.removeAll()
        rawDescriptors.forEach { close($0) }
        rawDescriptors.removeAll()
        super.tearDown()
    }

    /// Polls `condition` until it holds or `timeout` elapses, spinning the run
    /// loop in between so main-queue work still makes progress.
    ///
    /// Deliberately not a fixed sleep: it returns the instant the condition is
    /// observed and only spends the whole budget when something is genuinely
    /// wrong, so the timeout is a failure threshold rather than a guess at how
    /// long the machine will take.
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(condition(),
                      "timed out after \(timeout)s waiting until \(description)",
                      file: file, line: line)
    }

    func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        acceptedSockets.append(newSocket)
    }

    /// Runs `body` on a thread of its own, handing back an expectation that is
    /// fulfilled once that thread is actually running.
    ///
    /// Deliberately not `DispatchQueue.global()`. Every step in this class that has to
    /// happen on *another* thread used to go there, which quietly made each assertion
    /// depend on libdispatch handing out a worker promptly — and that pool is shared
    /// process-wide and capped. Measured on this platform: with ~64 default-QoS workers
    /// blocked, a newly submitted block does not start *at all* (12 s, no arrival), and
    /// machine-wide CPU contention delays it the same way. What that produces here is
    /// indistinguishable from the bug under test — a completion that "never fires",
    /// because the thread meant to trigger it never ran. A thread of its own is
    /// scheduled on its own, and the returned expectation is what lets a failure say
    /// which of the two actually happened.
    private func onOwnThread(_ name: String, _ body: @escaping () -> Void) -> XCTestExpectation {
        let running = expectation(description: "\(name) is running")
        let thread = Thread {
            running.fulfill()
            body()
        }
        thread.name = name
        thread.start()
        return running
    }

    /// Starts `count` threads that each hold at `gate` before running `body`, and
    /// returns once every one of them is running.
    ///
    /// Same reason as `onOwnThread`, and here it is the point of the test rather than a
    /// detail: a herd libdispatch quietly serialises — or does not start — is not a
    /// race. Parking N pooled workers on a gate is also itself what pushes the shared
    /// pool towards its cap for everything else in the process.
    private func startGatedThreads(count: Int,
                                   name: String,
                                   gate: DispatchSemaphore,
                                   _ body: @escaping () -> Void) {
        let running = (0..<count).map { index in
            onOwnThread("\(name)-\(index)") {
                gate.wait()
                body()
            }
        }
        wait(for: running, timeout: 10)
    }

    /// A port nothing listens on: bind an ephemeral listener, note the port it
    /// was given, then close it. Connecting there fails immediately with
    /// ECONNREFUSED instead of hanging for a SYN timeout.
    private func closedLoopbackPort() throws -> UInt16 {
        let probe = GCDAsyncSocket(delegate: self, delegateQueue: DispatchQueue.main)
        try probe.accept(onInterface: "127.0.0.1", port: 0)
        let port = probe.localPort
        probe.disconnect()
        return port
    }

    /// A loopback port whose SYNs are *silently dropped* — the blackhole case,
    /// which is a different failure mode from `closedLoopbackPort()`'s fast
    /// `ECONNREFUSED` refusal and the one that actually wedges a connect.
    ///
    /// Built without any external network: BSD drops rather than resets a SYN once
    /// a listener's accept queue is full, so a raw socket with `listen(fd, 1)`
    /// that never calls `accept()` blackholes every connect after the first. This
    /// makes that first connect itself, so the port handed back is already
    /// saturated. Measured on this platform: connect #1 completes immediately,
    /// #2 and later never complete and never fail.
    private func blackholedLoopbackPort() throws -> UInt16 {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(listener < 0, "could not open a listening socket")
        rawDescriptors.append(listener)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "could not bind a loopback listener")
        // Backlog 1, and never accepted: one pending connection saturates it.
        try XCTSkipIf(listen(listener, 1) != 0, "could not listen on the loopback listener")

        var bound4 = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound4) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(listener, sockaddrPointer, &length)
            }
        }
        let port = UInt16(bigEndian: bound4.sin_port)

        // Saturate the queue. This one connect succeeds; every later one hangs.
        let filler = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(filler < 0, "could not open the saturating socket")
        rawDescriptors.append(filler)
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(filler, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(connected != 0, "could not saturate the listener's accept queue")

        return port
    }

    /// A listener that accepts and holds connections, so a TCP connect genuinely
    /// succeeds. Returned socket must be kept alive by the caller.
    private func liveLoopbackListener() throws -> (socket: GCDAsyncSocket, port: UInt16) {
        let listener = GCDAsyncSocket(delegate: self, delegateQueue: DispatchQueue.main)
        try listener.accept(onInterface: "127.0.0.1", port: 0)
        return (listener, listener.localPort)
    }

    /// Built against a closed loopback port so the constructor's own connect
    /// fails immediately and leaves nothing pending. The socket is replaced by
    /// `set(transport:)` anyway, and the identity guard discards this one's late
    /// callback.
    private func makeCoala(tcpConnectTimeout: TimeInterval = 10) throws -> Coala {
        let coala = try Coala(transport: .tcp(host: "127.0.0.1", port: closedLoopbackPort()),
                              tcpConnectTimeout: tcpConnectTimeout)
        coalas.append(coala)
        return coala
    }

    /// A TCP connect that never succeeds previously left the completion unfired:
    /// the success-only closure swallowed `false`, so `CoAPService` sat in
    /// `.connecting` forever, queueing every message with no error and no timeout.
    func testRefusedTcpConnectReportsAnError() throws {
        let coala = try makeCoala()
        let port = try closedLoopbackPort()

        let reported = expectation(description: "set(transport:) completion fired")
        var reportedError: Error?
        try coala.set(transport: .tcp(host: "127.0.0.1", port: port)) { error in
            reportedError = error
            reported.fulfill()
        }

        wait(for: [reported], timeout: 5)
        XCTAssertNotNil(reportedError, "a refused TCP connect must surface an error")
    }

    /// The other half of the same wedge, and the half that actually happens in the
    /// field. `testRefusedTcpConnectReportsAnError` above only covers
    /// `ECONNREFUSED`, which fails *fast* — so it passes even with no connect
    /// deadline at all. A **blackholed** SYN does not fail: CocoaAsyncSocket's
    /// default is `withTimeout: -1`, neither `didConnectToHost` nor
    /// `socketDidDisconnect` arrives, `onTcpTransportReady` never fires, and
    /// `CoAPService` sits `.connecting` for the ~75 s the Darwin kernel takes to
    /// give up — queueing every message and reporting nothing.
    ///
    /// This is not a corner case: the TCP fallback exists because UDP is being
    /// filtered, and the networks that filter UDP (captive portals, corporate
    /// egress) are the ones that drop rather than refuse.
    ///
    /// The assertion is on the error's **identity**, not merely on an error
    /// arriving. A loopback blackhole is not a faithful stand-in for a WAN one:
    /// with a near-zero RTT estimate the kernel exhausts its SYN retransmits in
    /// about 8 s here rather than the ~75 s it takes on a real path, so
    /// "an error eventually arrived" passes with no deadline at all — measured,
    /// not assumed. Requiring `GCDAsyncSocketConnectTimeoutError` specifically
    /// means only *our* deadline can satisfy this test; the kernel giving up
    /// reports `ETIMEDOUT` in `NSPOSIXErrorDomain` and fails it.
    func testBlackholedTcpConnectReportsAnErrorInsteadOfHanging() throws {
        let port = try blackholedLoopbackPort()
        // Shorter than the production default purely so the test is quick, and comfortably
        // inside the kernel's own give-up window so the two outcomes stay distinguishable.
        // What is under test is that a deadline exists at all, not its value.
        let coala = try makeCoala(tcpConnectTimeout: 1)

        let reported = expectation(description: "set(transport:) completion fired")
        var reportedError: Error?
        let start = Date()
        try coala.set(transport: .tcp(host: "127.0.0.1", port: port)) { error in
            reportedError = error
            reported.fulfill()
        }

        wait(for: [reported], timeout: 20)
        let elapsed = Date().timeIntervalSince(start)

        let error = try XCTUnwrap(reportedError,
                                  "a blackholed TCP connect must surface an error rather than hang")
        XCTAssertEqual((error as NSError).domain, GCDAsyncSocketErrorDomain,
                       "the failure must come from our connect deadline, not from the kernel "
                       + "eventually giving up: got \(error)")
        XCTAssertEqual((error as NSError).code, GCDAsyncSocketError.connectTimeoutError.rawValue,
                       "the failure must be a connect timeout: got \(error)")
        XCTAssertLessThan(elapsed, 5,
                          "the connect deadline must fire well before the kernel abandons the SYN")
        XCTAssertEqual(coala.tcpState, .stopped,
                       "a timed-out connect must settle, not stay marked in flight forever")
    }

    /// The foreground wedge. `willEnterForeground` → `CloudClient.restart` →
    /// `GUMService.restart` → `Coala.restart` → `stop()` cleared the only stored
    /// completion, and nothing re-armed it: one background/foreground cycle
    /// inside the connect window left the service `.connecting` forever. A
    /// send during the same window self-inflicts it via `if !isSocketConnected`.
    func testRestartDuringConnectDoesNotAbandonTheConnect() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        let reported = expectation(description: "set(transport:) completion fired")
        var reportedError: Error?
        try coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { error in
            reportedError = error
            reported.fulfill()
        }

        coala.restart()

        wait(for: [reported], timeout: 5)
        XCTAssertNil(reportedError, "foregrounding mid-connect must not abandon the connect")
        XCTAssertTrue(coala.isSocketConnected, "the connection must still be established")
    }

    /// `socketDidDisconnect` reconnected unconditionally, so an intentional
    /// `stop()` was undone the instant it took effect: a TCP Coala could not be
    /// stopped at all.
    func testStopActuallyStopsATcpCoala() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        let connected = expectation(description: "connected")
        try coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { _ in
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(coala.isSocketConnected, "sanity: connected before stopping")

        coala.stop()

        // Give the disconnect handler ample opportunity to reconnect behind us.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertFalse(coala.isSocketConnected, "stop() must actually stop a TCP Coala")
    }

    /// `restart()` tears the socket down and immediately reconnects it, and must end up
    /// genuinely connected again — not merely "not stopped".
    func testRestartWhileConnectedReestablishesTheConnection() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        let connected = expectation(description: "connected")
        try coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { _ in
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(coala.isSocketConnected, "sanity: connected before restarting")

        coala.restart()

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        XCTAssertTrue(coala.isSocketConnected, "restart must re-establish a connected session")
    }

    /// Every connect attempt must be marked in flight, not just the one started
    /// by `set(transport:)`. A reconnect driven by `restart()` is otherwise
    /// unprotected, so a send landing in *its* window tears it down — the same
    /// wedge, one path further along.
    ///
    /// The interesting case is a `restart()` issued while the *previous* teardown's
    /// disconnect callback is still in flight. `disconnect()` reports asynchronously, so
    /// that callback arrives after the reconnect has already started; `restart()` replaces
    /// the socket precisely so the identity guard can recognise it as stale. Without that
    /// replacement the callback passes the guard — it is the same object — reads
    /// `.connecting`, concludes the reconnect failed and resets the state to `.stopped`
    /// underneath a live connect.
    ///
    /// The test asserts on how that callback is **classified**, not on `tcpState`: the
    /// loopback connect completes within milliseconds and overwrites the damage, so the bug
    /// is already invisible by the time a state assertion runs — which is precisely why it
    /// survived this long. The classification is the durable signal.
    ///
    /// Restarting from `connected` (rather than after an explicit `stop()`) is what makes it
    /// deterministic. `stopLocked()`'s `disconnect()` enqueues the callback synchronously
    /// while `restart()` still holds `tcpLifecycleLock`, so the callback cannot be processed
    /// until `restart()` has finished replacing the socket — the interleaving is forced, not
    /// raced. Restarting from `stopped` instead lets the callback land before `restart()` even
    /// takes the lock, where it is legitimately reported as `while stopped`, and the test
    /// becomes a coin flip in both directions.
    func testRestartMarksTheReconnectAsInFlight() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        let connected = expectation(description: "connected")
        try coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { _ in
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(coala.isSocketConnected, "sanity: connected before restarting")

        // Setup contributes one disconnect callback of its own: `makeCoala()`'s constructor
        // dials a closed port, and that connect fails. Let it be classified first, or the wait
        // after `restart()` could return on it instead of on the teardown's.
        waitUntil("the setup's own disconnect callback has been classified") {
            coala.disconnectLog.handled >= 1
        }
        let before = coala.disconnectLog

        coala.restart()

        waitUntil("the teardown's disconnect callback has been delivered") {
            coala.disconnectLog.handled > before.handled
        }

        XCTAssertEqual(coala.disconnectLog.last, .stale,
                       "the teardown's own disconnect must be recognised as stale, not charged "
                       + "to the reconnect")
        XCTAssertNotEqual(coala.tcpState, .stopped,
                          "a reconnect must be marked in flight so a concurrent send cannot tear it down")
    }

    /// Captures every message Coala logs. Installed as `Coala.logger` (a process-wide
    /// static) only for the duration of a single test, restored via `defer`.
    ///
    /// Being process-wide, it captures *every* live instance, not only the one under test — so
    /// it can carry an assertion about the *absence* of a string only when no other instance
    /// could have produced it. Its one remaining caller looks for `Couldn't initiate socket`,
    /// reachable only from `startLocked()`, which a stopped instance never reaches; `tearDown`
    /// stopping every `Coala` this class builds is what makes that hold.
    private final class LogCapturingLogger: CoalaLogger {
        let messages = Synchronized(value: [String]())
        func log(_ message: String, level: LogLevel, asynchronous: Bool) {
            messages.mutate { $0.append(message) }
        }
    }

    /// `CloudClient.restart()` (foreground, main thread) and the message pool's
    /// tick-driven `restart()` (its own dispatch source) used to be serialized for
    /// free by both landing on the main queue. Racing them from separate threads
    /// while genuinely connected lets every caller pass the "already connecting"
    /// guard and run overlapping `stop()`+`start()` cycles that each issue
    /// `connect()` on the *same* socket instance. CocoaAsyncSocket rejects the
    /// loser synchronously ("Couldn't initiate socket") and its `start()` catch
    /// clobbers `tcpState` back to `.stopped` behind the winner's back,
    /// stranding an otherwise-healthy connection.
    func testConcurrentRestartsDoNotStrandAnEstablishedConnection() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        let connected = expectation(description: "connected")
        try coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { _ in
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(coala.isSocketConnected, "sanity: connected before racing restarts")

        let capturingLogger = LogCapturingLogger()
        let originalLogger = Coala.logger
        Coala.logger = capturingLogger
        defer { Coala.logger = originalLogger }

        // Two simultaneous callers, repeated many times: this mirrors the real
        // scenario (one foreground `restart()` landing at the same instant as
        // one tick-driven `restart()`), not an artificial thundering herd. A
        // much higher fan-out — or back-to-back rounds with no gap — backlogs
        // the socket's own delegate queue with stale disconnect callbacks that
        // later misfire regardless of this lock; that starvation is a real but
        // separate concern from the cross-thread check-then-act under test
        // here, so each round gets a brief moment to actually settle.
        let concurrentRestarts = 2
        let rounds = 30
        for _ in 0..<rounds {
            let barrier = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            for _ in 0..<concurrentRestarts { group.enter() }
            startGatedThreads(count: concurrentRestarts, name: "concurrent-restart", gate: barrier) {
                coala.restart()
                group.leave()
            }
            for _ in 0..<concurrentRestarts { barrier.signal() }
            group.wait()
            Thread.sleep(forTimeInterval: 0.005)
        }

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        let collisions = capturingLogger.messages.value.filter { $0.contains("Couldn't initiate socket") }
        XCTAssertTrue(collisions.isEmpty,
                      "concurrent restarts collided on the shared socket: \(collisions)")
        XCTAssertTrue(coala.isSocketConnected, "concurrent restarts must not strand the connection")
    }

    /// `takeTcpTransportCompletion()`'s contract: the returned completion is invoked
    /// only *after* releasing `tcpLifecycleLock`, because it is arbitrary app code
    /// (`CoAPService.didConnect` → a `send()` per queued message, i.e. crypto and
    /// socket writes) that can itself call back into `restart()`/`stop()`. If the
    /// lock were still held while it ran, every other thread wanting to call
    /// `restart()`/`stop()` — including a concurrent foreground
    /// `CloudClient.restart()` on main — would block for as long as it takes.
    func testTransportReadyCompletionDoesNotBlockOtherThreadsFromTheLock() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        let completionStarted = expectation(description: "completion started")
        let completionMayReturn = DispatchSemaphore(value: 0)
        try coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { _ in
            completionStarted.fulfill()
            _ = completionMayReturn.wait(timeout: .now() + 3)
        }
        wait(for: [completionStarted], timeout: 5)

        // The completion above is still parked inside its `wait`. If
        // `tcpLifecycleLock` were still held while it runs, this concurrent
        // `restart()` would block behind it until the semaphore is signaled below,
        // and the 1-second wait on `restarted` would time out.
        let restarted = expectation(description: "concurrent restart returned")
        let restartRunning = onOwnThread("concurrent-restart") {
            coala.restart()
            restarted.fulfill()
        }
        wait(for: [restartRunning], timeout: 10)
        wait(for: [restarted], timeout: 1)

        completionMayReturn.signal()
    }

    /// N-2 remnant: `stop()` is called *nested* from `set(transport:)`. In that
    /// nesting, `stop()`'s own `unlock()` only decrements the recursive count —
    /// `set(transport:)`'s outer `lock()` still holds it — so firing the abandoned
    /// switch's completion from inside that nested call still runs with the lock
    /// held in every way that matters to another thread. `stopLocked()` closes
    /// this by handing the completion back up to `set(transport:)`'s own unlock
    /// instead of firing it inline.
    func testAbandonedTransportSwitchCompletionDoesNotBlockOtherThreadsWhenCancelledBySetTransport() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        // A connect to a non-routable TEST-NET-1 address never resolves, so this
        // stays `.connecting` — and its completion still pending — until
        // something else cancels it.
        let completionMayReturn = DispatchSemaphore(value: 0)
        let firstCompletionStarted = expectation(description: "first completion started")
        try coala.set(transport: .tcp(host: "192.0.2.1", port: 16666)) { _ in
            firstCompletionStarted.fulfill()
            _ = completionMayReturn.wait(timeout: .now() + 3)
        }

        // Cancel it via a second `set(transport:)` — the nested
        // `set(transport:)` → `stopLocked()` path under test. This call itself
        // blocks on whatever thread runs it until the parked completion above
        // returns, so it must run off the test's own thread.
        let secondSetTransportReturned = expectation(description: "second set(transport:) returned")
        let secondSetTransportRunning = onOwnThread("second-set-transport") {
            try? coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { _ in }
            secondSetTransportReturned.fulfill()
        }

        // Two waits, not one. Getting that thread onto a CPU is the harness's job;
        // firing the abandoned completion once it is there is `Coala`'s. Folded
        // together, a scheduling delay reads as "the abandoned completion was
        // dropped" — the exact bug this test exists to catch — so the two are asserted
        // separately and fail with different messages.
        wait(for: [secondSetTransportRunning], timeout: 10)
        wait(for: [firstCompletionStarted], timeout: 5)

        // The abandoned first completion is now parked inside its `wait`, having
        // been invoked by the second `set(transport:)`'s nested `stopLocked()`
        // call. If `tcpLifecycleLock` were still (nominally) held while it runs —
        // the exact bug under test — a concurrent `restart()` would be stuck
        // behind it until the semaphore below is signaled, and this 1-second
        // wait would time out.
        let restarted = expectation(description: "concurrent restart returned")
        let restartRunning = onOwnThread("concurrent-restart") {
            coala.restart()
            restarted.fulfill()
        }
        wait(for: [restartRunning], timeout: 10)
        wait(for: [restarted], timeout: 1)

        completionMayReturn.signal()
        wait(for: [secondSetTransportReturned], timeout: 5)
    }

    /// `takeTcpTransportCompletion()` must deliver the completion exactly once even
    /// when several threads race to be the one that triggers it — e.g. a delegate
    /// callback reporting a connect outcome racing an app-driven `stop()` for the
    /// same pending transport switch.
    func testTransportReadyCompletionFiresExactlyOnceUnderConcurrentStops() throws {
        let listener = try liveLoopbackListener()
        defer { listener.socket.disconnect() }
        let coala = try makeCoala()

        let fireCount = Synchronized(value: 0)
        let fired = expectation(description: "completion fired")
        try coala.set(transport: .tcp(host: "127.0.0.1", port: listener.port)) { _ in
            fireCount.mutate { $0 += 1 }
            fired.fulfill()
        }

        // Races these stops against the connect's own delegate-driven success —
        // exactly one of the 21 competitors for `onTcpTransportReady` must win.
        let concurrentStops = 20
        let barrier = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for _ in 0..<concurrentStops { group.enter() }
        startGatedThreads(count: concurrentStops, name: "concurrent-stop", gate: barrier) {
            coala.stop()
            group.leave()
        }
        for _ in 0..<concurrentStops { barrier.signal() }
        group.wait()

        wait(for: [fired], timeout: 3)

        // Give any duplicate firing a chance to land before asserting.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(fireCount.value, 1, "the transport-ready completion must fire exactly once")
    }
}
