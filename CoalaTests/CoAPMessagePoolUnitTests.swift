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
}
