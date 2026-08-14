import XCTest
@testable import Coala

/// Sequence-number dedup, expiration windows and timer lifecycle of
/// `ObservedResourcesRegistry`. Handlers are dispatched via
/// `DispatchQueue.main.async`, so tests drain the main queue with an
/// expectation before asserting delivery counts. `tick()` is always called
/// directly; no test relies on the real 1-second Timer firing.
final class ObservedResourcesRegistryTests: XCTestCase {

    private var coala: Coala!
    private var registry: ObservedResourcesRegistry!

    private func makeCoala(ports: Range<UInt16>) -> (Coala, UInt16)? {
        for port in ports {
            if let coala = try? Coala(transport: .udp(port: port)) {
                return (coala, port)
            }
        }
        return nil
    }

    override func setUpWithError() throws {
        let (coala, _) = try XCTUnwrap(makeCoala(ports: 15743..<15763))
        self.coala = coala
        registry = ObservedResourcesRegistry()
    }

    override func tearDown() {
        registry?.stopTimer()
        registry = nil
        coala?.stop()
        coala = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeToken(_ byte: UInt8 = 1) -> CoAPToken {
        CoAPToken(value: Data([byte, 2, 3, 4]))
    }

    private func makeResource(onUpdate: @escaping Coala.ResponseHandler = { _ in }) -> ObservedResource {
        ObservedResource(url: URL(string: "coap://127.0.0.1:1/obs")!,
                         coala: coala,
                         handler: onUpdate)
    }

    private func notification(sequenceNumber: UInt?, maxAge: UInt? = nil) -> ObserverNotification {
        ObserverNotification(message: CoAPMessage(type: .confirmable, code: .response(.content)),
                             from: Address(host: "127.0.0.1", port: 1),
                             sequenceNumber: sequenceNumber,
                             maxAge: maxAge)
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

    /// Waits until every block already dispatched to the main queue has run,
    /// so a handler that was (wrongly) scheduled would have fired by now.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    /// Arm/disarm is asynchronous, so the accessor drains the registry's own queue first.
    private func isTimerArmed() -> Bool {
        return registry?.isTimerArmedAfterPendingWork == true
    }

    // MARK: - Sequence number dedup

    func testFirstNotificationIsDeliveredAndSequenceNumberStored() {
        var deliveredCount = 0
        let token = makeToken()
        registry.didStartObserving(resource: makeResource { _ in deliveredCount += 1 },
                                   forToken: token)

        registry.didReceive(notification: notification(sequenceNumber: 5), forToken: token)

        drainMainQueue()
        XCTAssertEqual(deliveredCount, 1)
        XCTAssertEqual(registry.resource(forToken: token)?.sequenceNumber, 5)
    }

    func testDuplicateAndStaleSequenceNumbersAreDropped() {
        var deliveredCount = 0
        let token = makeToken()
        registry.didStartObserving(resource: makeResource { _ in deliveredCount += 1 },
                                   forToken: token)

        registry.didReceive(notification: notification(sequenceNumber: 5), forToken: token)
        registry.didReceive(notification: notification(sequenceNumber: 5), forToken: token) // duplicate
        registry.didReceive(notification: notification(sequenceNumber: 4), forToken: token) // stale

        drainMainQueue()
        XCTAssertEqual(deliveredCount, 1)
        // State is not updated by the dropped notifications.
        XCTAssertEqual(registry.resource(forToken: token)?.sequenceNumber, 5)
    }

    func testNilIncomingSequenceNumberIsAlwaysDelivered() {
        var deliveredCount = 0
        let token = makeToken()
        registry.didStartObserving(resource: makeResource { _ in deliveredCount += 1 },
                                   forToken: token)

        registry.didReceive(notification: notification(sequenceNumber: 5), forToken: token)
        registry.didReceive(notification: notification(sequenceNumber: nil), forToken: token)
        registry.didReceive(notification: notification(sequenceNumber: nil), forToken: token)

        drainMainQueue()
        XCTAssertEqual(deliveredCount, 3)
    }

    func testNotificationForUnknownTokenIsNotDelivered() {
        var deliveredCount = 0
        registry.didStartObserving(resource: makeResource { _ in deliveredCount += 1 },
                                   forToken: makeToken(1))

        registry.didReceive(notification: notification(sequenceNumber: 5), forToken: makeToken(9))

        drainMainQueue()
        XCTAssertEqual(deliveredCount, 0)
    }

    // MARK: - Expiration

    func testExpirationDateIsNilForNilMaxAge() {
        XCTAssertNil(registry.expirationDateFor(maxAge: nil))
    }

    func testExpirationDateFallsWithinMaxAgePlusRandomDelayWindow() throws {
        registry.expirationRandomDelay = 5...15
        let before = Date()
        let date = try XCTUnwrap(registry.expirationDateFor(maxAge: 10))
        let interval = date.timeIntervalSince(before)
        // maxAge 10 + delay in [5, 15) => [15, 25)
        XCTAssertGreaterThanOrEqual(interval, 15)
        XCTAssertLessThanOrEqual(interval, 25)
    }

    func testTickRemovesExpiredResourceAndKeepsFreshOne() {
        let expiredToken = makeToken(1)
        var expired = makeResource()
        expired.validUntil = Date(timeIntervalSinceNow: -1)
        registry.didStartObserving(resource: expired, forToken: expiredToken)

        let freshToken = makeToken(2)
        var fresh = makeResource()
        fresh.validUntil = Date(timeIntervalSinceNow: 3600)
        registry.didStartObserving(resource: fresh, forToken: freshToken)

        registry.tick()

        XCTAssertNil(registry.resource(forToken: expiredToken))
        XCTAssertNotNil(registry.resource(forToken: freshToken))
    }

    /// Before this task, `tick()` only removed a resource `if let coala = resource.coala`,
    /// so a resource whose `coala` had already died was kept in the dictionary forever — it
    /// could never be re-observed, so retaining it only leaked. `tick()` now removes any
    /// expired resource unconditionally, regardless of whether `coala` is still alive.
    func testTickRemovesExpiredResourceEvenAfterItsCoalaHasDied() throws {
        let token = makeToken()
        // `ObservedResource.coala` is `fileprivate` to the production file, so this
        // independent weak witness — pointing at the same instance — stands in for it:
        // once the instance deallocates, both go nil together.
        weak var weakScratchCoala: Coala?
        var resource: ObservedResource!
        do {
            let (scratchCoala, _) = try XCTUnwrap(makeCoala(ports: 15943..<15963))
            weakScratchCoala = scratchCoala
            resource = ObservedResource(url: URL(string: "coap://127.0.0.1:1/obs")!,
                                        coala: scratchCoala,
                                        handler: { _ in })
            scratchCoala.stop()
        }
        // Socket teardown finishes asynchronously on its own GCD queues, so the
        // weak reference does not clear the moment `stop()` returns. The delay is
        // genuine rather than a retain cycle: `GCDAsyncUdpSocket`'s delegate is
        // `__weak`, but `closeWithError:` → `notifyDidCloseWithError:`
        // async-dispatches a *strong* delegate capture onto the delegate queue, so
        // the last reference outlives `stop()` by however long that queue takes to
        // drain.
        //
        // This used to budget a fixed 0.5 s for that. It gates a *sanity
        // precondition*, not the behaviour under test, so on a loaded CI runner
        // the test would go red for a reason unrelated to what it covers — the
        // likeliest CI failure in this suite. Polling to a generous deadline is
        // both faster in the normal case and immune to that.
        waitUntil("the scratch Coala deallocates") { weakScratchCoala == nil }
        XCTAssertNil(weakScratchCoala, "sanity: the scratch Coala must already be deallocated")
        resource.validUntil = Date(timeIntervalSinceNow: -1)
        registry.didStartObserving(resource: resource, forToken: token)

        registry.tick()

        XCTAssertNil(registry.resource(forToken: token),
                     "an expired resource must be evicted even once its coala has died, or it leaks forever")
    }

    // MARK: - Concurrency

    /// `observeLayer` is an out-layer, so every send — including a retransmit issued from
    /// `CoAPMessagePool.tick` on its own queue — mutates this dictionary. It is reachable from
    /// the app thread, the delegate queue and the pool queue at once.
    func testConcurrentRegistrationDoesNotCorruptTheRegistry() {
        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let token = CoAPToken(value: Data([UInt8(index % 256), UInt8(index / 256), 3, 4]))
            self.registry.didStartObserving(resource: self.makeResource(), forToken: token)
        }
        let survivors = (0..<iterations).filter { index in
            registry.resource(forToken: CoAPToken(value: Data([UInt8(index % 256),
                                                              UInt8(index / 256), 3, 4]))) != nil
        }
        XCTAssertEqual(survivors.count, iterations,
                       "every concurrent registration must survive")
    }

    /// Pins the atomicity of `didReceive`'s dedup-check-then-update: it must run as a single
    /// `mutate` so a compound read-modify-write can't unfold into separate lock acquisitions.
    /// If it ever did unfold, two concurrent notifications could each read the same stale
    /// `previousSequenceNumber`, both pass the dedup guard, and then race to write — letting
    /// whichever call happens to write last decide the outcome, regardless of its sequence
    /// number. Under the real atomic implementation the reduction is
    /// `current = max(current, incoming)`, which is commutative/order-independent: no matter
    /// what order `iterations` concurrent calls actually execute in, the final stored
    /// sequence number is deterministically the maximum submitted, `iterations - 1`.
    func testConcurrentNotificationsDoNotRegressTheSequenceNumber() {
        let iterations = 200
        let token = makeToken()
        registry.didStartObserving(resource: makeResource(), forToken: token)

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            self.registry.didReceive(notification: self.notification(sequenceNumber: UInt(index)),
                                     forToken: token)
        }

        XCTAssertEqual(registry.resource(forToken: token)?.sequenceNumber, UInt(iterations - 1),
                       "the highest sequence number must win regardless of arrival order")
    }

    // MARK: - Timer lifecycle

    func testTimerStopsOnlyWhenLastResourceIsRemoved() {
        XCTAssertFalse(isTimerArmed())

        let firstToken = makeToken(1)
        let secondToken = makeToken(2)
        registry.didStartObserving(resource: makeResource(), forToken: firstToken)
        registry.didStartObserving(resource: makeResource(), forToken: secondToken)
        XCTAssertTrue(isTimerArmed(), "timer must survive while resources remain")

        registry.didStopObservingResource(forToken: firstToken)
        XCTAssertTrue(isTimerArmed(), "timer must survive while resources remain")

        registry.didStopObservingResource(forToken: secondToken)
        XCTAssertFalse(isTimerArmed(), "timer must stop when the registry becomes empty")
    }
}
