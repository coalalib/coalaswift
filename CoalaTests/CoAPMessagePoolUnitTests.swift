import XCTest
@testable import Coala

final class CoAPMessagePoolUnitTests: XCTestCase {

    private func makeMessage(token: CoAPToken) -> CoAPMessage {
        var message = CoAPMessage(type: .confirmable, method: .get)
        message.token = token
        message.address = Address(host: "127.0.0.1", port: 5683)
        return message
    }

    func testRemoveByMessageIdAlsoRemovesTokenMapping() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x10]))
        let message = makeMessage(token: token)
        pool.push(message: message)
        XCTAssertNotNil(pool.get(messageId: message.messageId))
        XCTAssertNotNil(pool.get(token: token))

        pool.remove(messageWithId: message.messageId)
        XCTAssertNil(pool.get(messageId: message.messageId))
        XCTAssertNil(pool.get(token: token))
    }

    func testRemoveByMessageRemovesBothMaps() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x11]))
        let message = makeMessage(token: token)
        pool.push(message: message)
        pool.remove(message: message)
        XCTAssertNil(pool.get(messageId: message.messageId))
        XCTAssertNil(pool.get(token: token))
    }

    private func makeMessage(token: CoAPToken, messageId: UInt16) -> CoAPMessage {
        var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: messageId)
        message.token = token
        message.address = Address(host: "127.0.0.1", port: 5683)
        return message
    }

    /// Observe: the notification arrives as a separate message (own messageId, shared
    /// token). Removing it must also purge the pooled register request the token maps
    /// to, otherwise the register keeps resending and finally times out.
    func testRemoveByMessagePurgesElementTheTokenMapsTo() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x13]))
        let register = makeMessage(token: token, messageId: 100)
        pool.push(message: register)

        let notification = makeMessage(token: token, messageId: 200)
        pool.remove(message: notification)

        XCTAssertNil(pool.get(messageId: register.messageId))
        XCTAssertNil(pool.get(token: token))
    }

    /// ARQ block transfers push many messages sharing one token with distinct
    /// messageIds. Removing an OLD messageId (its ACK arrived) must not follow a
    /// stale reverse-index entry and destroy the token's mapping to the LIVE message.
    func testRemovingOldMessageIdKeepsTokenMappedToNewerMessage() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x14]))
        let block1 = makeMessage(token: token, messageId: 300)
        let block2 = makeMessage(token: token, messageId: 301)
        pool.push(message: block1)
        pool.push(message: block2)

        pool.remove(messageWithId: block1.messageId)

        XCTAssertNil(pool.get(messageId: block1.messageId))
        XCTAssertEqual(pool.get(token: token)?.messageId, block2.messageId)
    }

    func testRemovingCurrentMessageIdClearsTokenMapping() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x15]))
        pool.push(message: makeMessage(token: token, messageId: 400))
        pool.push(message: makeMessage(token: token, messageId: 401))

        pool.remove(messageWithId: 401)

        XCTAssertNil(pool.get(token: token))
    }

    func testRemoveAllClearsTokenLookup() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x12]))
        pool.push(message: makeMessage(token: token))
        pool.removeAll()
        XCTAssertNil(pool.get(token: token))
    }

    func testPushIgnoresAcknowledgements() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x16]))
        var ack = CoAPMessage(type: .acknowledgement, code: .response(.content), messageId: 500)
        ack.token = token
        pool.push(message: ack)
        XCTAssertNil(pool.get(messageId: ack.messageId))
        XCTAssertNil(pool.get(token: token))
    }

    func testRepushSameMessageCountsRetransmit() {
        let pool = CoAPMessagePool()
        let token = CoAPToken(value: Data([0x17]))
        let message = makeMessage(token: token, messageId: 600)
        pool.push(message: message)
        pool.push(message: message)
        XCTAssertEqual(pool.timesSent(messageId: message.messageId), 2)
        XCTAssertEqual(pool.get(token: token)?.messageId, message.messageId)
    }

    private func confirmableElement(timesSent: Int,
                                    lastSendAgo: TimeInterval,
                                    didTransmit: Bool) -> CoAPMessagePool.Element {
        var message = CoAPMessage(type: .confirmable, method: .get)
        message.address = Address(host: "127.0.0.1", port: 5683)
        var element = CoAPMessagePool.Element(message: message)
        element.timesSent = timesSent
        element.lastSend = Date(timeIntervalSinceNow: -lastSendAgo)
        element.didTransmit = didTransmit
        return element
    }

    /// `Timer.scheduledTimer` installs on the *calling* thread's run loop, and the
    /// pool is adopted (`coala` assigned) by whichever queue drives a transport
    /// switch — a plain GCD queue with no run loop running. A timer scheduled
    /// there never fires, silently disabling retransmission and expiry for every
    /// message, process-wide.
    func testTimerFiresWhenPoolIsAdoptedFromAQueueWithoutARunLoop() throws {
        let coala = try Coala(transport: .tcp(host: "192.0.2.1", port: 16666))
        let pool = CoAPMessagePool()
        pool.maxAttempts = 0        // any pooled confirmable expires on the first tick
        pool.resendTimeInterval = 0.15     // 0.05 s re-check: the floor, not clamped by it

        let expired = expectation(description: "pooled message expired from a timer tick")
        var message = CoAPMessage(type: .confirmable, method: .get)
        message.address = Address(host: "10.0.0.1", port: 5683)
        message.onResponse = { _ in expired.fulfill() }
        pool.push(message: message)

        DispatchQueue(label: "queue.without.a.runloop").async {
            pool.coala = coala
        }

        wait(for: [expired], timeout: 3)

        // Leaving the source armed would keep it ticking for the rest of the test run.
        pool.stopTimer()
    }

    /// `Timer.scheduledTimer` registers in `.default` run-loop mode only, so it stops firing
    /// while the main run loop is in tracking mode — any scroll gesture — or otherwise busy.
    /// Retransmission and expiry must not depend on the main thread being free.
    func testTicksContinueWhileTheMainThreadIsBlocked() throws {
        let coala = try Coala(transport: .tcp(host: "192.0.2.1", port: 16666))
        let pool = CoAPMessagePool()
        pool.maxAttempts = 0        // any pooled confirmable expires on the first tick
        pool.resendTimeInterval = 0.15     // 0.05 s re-check: the floor, not clamped by it

        let fired = Synchronized(value: false)
        var message = CoAPMessage(type: .confirmable, method: .get)
        message.address = Address(host: "10.0.0.1", port: 5683)
        message.onResponse = { _ in fired.value = true }
        pool.push(message: message)
        pool.coala = coala

        // Occupy the main thread without turning its run loop, the way a gesture does.
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while Date() < deadline { }

        XCTAssertTrue(fired.value, "expiry must not depend on the main run loop turning")
        pool.stopTimer()
    }

    /// Remote Config reconfigures the retransmission policy from its fetch completion while
    /// the tick reads it on `timerQueue`. As plain `var`s those were a genuine data race the
    /// moment the tick left the main run loop, and `longRunningUrlPaths` is an `Array`, so a
    /// read racing a write is an unsynchronized CoW-buffer access — memory-unsafe, not merely
    /// stale.
    ///
    /// This is a ThreadSanitizer test: without TSan it passes either way, because a torn read
    /// of two `Double`s and an array header is unlikely to produce a visibly wrong `Action`.
    /// Run it with `-enableThreadSanitizer YES` for it to mean anything.
    func testReconfiguringWhileTicksAreReadingIsRaceFree() throws {
        let coala = try Coala(transport: .tcp(host: "192.0.2.1", port: 16666))
        let pool = CoAPMessagePool()
        pool.resendTimeInterval = 3 * CoAPMessagePool.minimumRecheckTimeInterval  // tick at the floor
        pool.coala = coala

        // Keep the tick busy: it only reads the settings when it has elements to judge.
        for index in 0..<50 {
            pool.push(message: makeMessage(token: CoAPToken(value: Data([UInt8(index)])),
                                           messageId: UInt16(index + 1)))
        }

        let deadline = Date(timeIntervalSinceNow: 0.5)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            var flip = false
            while Date() < deadline {
                flip.toggle()
                pool.resendTimeInterval = flip ? 0.15 : 0.30
                pool.maxAttempts = flip ? 3 : 9
                pool.longRunningUrlPaths = flip
                    ? [UriPathConfig(path: "/long/\(worker)", timeout: 6)]
                    : []
            }
        }

        pool.stopTimer()
    }

    /// The pool does crypto, serialization and socket writes on every tick. None of it belongs
    /// on the main thread, and no caller may assume the expiry callback arrives there.
    func testExpiryIsDeliveredOffTheMainThread() throws {
        let coala = try Coala(transport: .tcp(host: "192.0.2.1", port: 16666))
        let pool = CoAPMessagePool()
        pool.maxAttempts = 0
        pool.resendTimeInterval = 0.15     // 0.05 s re-check: the floor, not clamped by it

        let expired = expectation(description: "pooled message expired")
        let onMainThread = Synchronized(value: true)
        var message = CoAPMessage(type: .confirmable, method: .get)
        message.address = Address(host: "10.0.0.1", port: 5683)
        message.onResponse = { _ in
            onMainThread.value = Thread.isMainThread
            expired.fulfill()
        }
        pool.push(message: message)
        pool.coala = coala

        wait(for: [expired], timeout: 3)
        XCTAssertFalse(onMainThread.value, "the pool tick must not occupy the main thread")
        pool.stopTimer()
    }

    /// `resendTimeInterval` is remote-config controlled and can arrive here as 0 (or,
    /// via a misconfigured server, negative). `Timer` used to clamp a non-positive
    /// interval to its documented minimum; a `DispatchSourceTimer` has no floor of its
    /// own, so an unclamped `repeating: 0` busy-spins `timerQueue`'s core forever.
    func testRecheckIntervalNeverGoesBelowTheTimerFloorEvenWhenResendIntervalIsNonPositive() {
        let pool = CoAPMessagePool()

        pool.resendTimeInterval = 0
        XCTAssertEqual(pool.recheckTimeInterval(), CoAPMessagePool.minimumRecheckTimeInterval)

        pool.resendTimeInterval = -5
        XCTAssertEqual(pool.recheckTimeInterval(), CoAPMessagePool.minimumRecheckTimeInterval)

        // Above the floor, so the divide-by-three is what decides.
        pool.resendTimeInterval = 3
        XCTAssertEqual(pool.recheckTimeInterval(), 1, accuracy: 0.0000001)
    }

    func testActionForRecentUndeliveredConWaits() {
        let pool = CoAPMessagePool()
        pool.resendTimeInterval = 0.75
        let element = confirmableElement(timesSent: 1, lastSendAgo: 0.1, didTransmit: false)
        XCTAssertEqual(pool.actionFor(element: element), .wait)
    }

    func testActionForStaleUndeliveredConResends() {
        let pool = CoAPMessagePool()
        pool.resendTimeInterval = 0.75
        let element = confirmableElement(timesSent: 1, lastSendAgo: 5, didTransmit: false)
        XCTAssertEqual(pool.actionFor(element: element), .resend)
    }

    func testActionForDeliveredConIsDeleted() {
        let pool = CoAPMessagePool()
        let element = confirmableElement(timesSent: 1, lastSendAgo: 5, didTransmit: true)
        XCTAssertEqual(pool.actionFor(element: element), .delete)
    }

    func testActionForExhaustedUndeliveredConTimesOut() {
        let pool = CoAPMessagePool()
        pool.maxAttempts = 6
        let element = confirmableElement(timesSent: 6, lastSendAgo: 5, didTransmit: false)
        XCTAssertEqual(pool.actionFor(element: element), .timeout)
    }

    func testExpirationIsDebugAndStillDeliversCallback() throws {
        let previous = Coala.logger
        let logger = RecordingLogger()
        Coala.logger = logger
        defer { Coala.logger = previous }
        let coala = try Coala(transport: .udp(port: 0))
        let pool = CoAPMessagePool()
        pool.coala = coala
        pool.stopTimer()
        pool.maxAttempts = 0
        var callbacks = 0
        var message = makeMessage(token: CoAPToken.generate())
        message.onResponse = { response in
            guard case .error(let error) = response,
                  case CoAPMessagePoolError.messageExpired = error else {
                return XCTFail("expected unchanged expiration error")
            }
            callbacks += 1
        }
        pool.push(message: message)
        pool.tick()
        XCTAssertEqual(callbacks, 1)
        let expired = logger.records.filter { $0.message == "Request expired" }
        XCTAssertEqual(expired.map { $0.level }, [.debug])
        XCTAssertTrue(expired.allSatisfy { $0.context["message_id"] is Int })
    }

}
