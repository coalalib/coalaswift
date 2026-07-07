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

    /// Waits until every block already dispatched to the main queue has run,
    /// so a handler that was (wrongly) scheduled would have fired by now.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func registryTimer() -> Timer? {
        guard let registry = registry else { return nil }
        return Mirror(reflecting: registry).children
            .first { $0.label == "timer" }?.value as? Timer
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

    // MARK: - Timer lifecycle

    func testTimerStopsOnlyWhenLastResourceIsRemoved() {
        XCTAssertNil(registryTimer())

        let firstToken = makeToken(1)
        let secondToken = makeToken(2)
        registry.didStartObserving(resource: makeResource(), forToken: firstToken)
        registry.didStartObserving(resource: makeResource(), forToken: secondToken)
        XCTAssertEqual(registryTimer()?.isValid, true)

        registry.didStopObservingResource(forToken: firstToken)
        XCTAssertEqual(registryTimer()?.isValid, true, "timer must survive while resources remain")

        registry.didStopObservingResource(forToken: secondToken)
        XCTAssertNil(registryTimer(), "timer must stop when the registry becomes empty")
    }
}
