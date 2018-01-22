//
//  CoAPMessagePoolTests.swift
//  Coala
//
//  Created by Roman on 15/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class CoAPMessagePoolTests: CoalaTests {

    let resendInterval = 0.1
    let maxAttempts = 3

    override func setUp() {
        super.setUp()
        let pool = coalaClient.messagePool
        pool.resendTimeInterval = resendInterval
        pool.maxAttempts = maxAttempts
    }

    func testPoolRelease() {
        weak var pool = coalaServer.messagePool
        coalaServer = nil
        XCTAssertNil(pool)
    }

    func testPoolContainsMessageAfterSend() {
        let reached = expectation(description: "Server reached")
        let resource = CoAPResource(method: .get, path: "/msg") { _ in
            reached.fulfill()
            return (.content, nil)
        }
        coalaServer.addResource(resource)

        let url = URL(string: "coap://localhost:\(serverPort)/msg")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.token = CoAPToken.generate(length: 4)
        _ = try? coalaClient.send(requestMessage)

        let messageInPoolAfterSend = coalaClient.messagePool.get(token: requestMessage.token)
        XCTAssertNotNil(messageInPoolAfterSend)
        XCTAssertEqual(messageInPoolAfterSend?.messageId, requestMessage.messageId)

        let wait2Intervals = expectation(description: "Wait 2 resend intervals")
        DispatchQueue.main.asyncAfter(deadline: .now() + resendInterval * 2) {
            wait2Intervals.fulfill()
        }

        waitForExpectations(timeout: timeout + resendInterval * 2, handler: nil)

        let messageInPoolAfterResponse = coalaClient.messagePool.get(token: requestMessage.token)
        XCTAssertNil(messageInPoolAfterResponse)
    }

    func testPoolResendAndDeleteAfter3Times() {
        coalaServer = nil
        let url = URL(string: "coap://localhost:\(serverPort)/msg")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.token = CoAPToken.generate(length: 4)
        _ = try? coalaClient.send(requestMessage)

        let wait4Intervals = expectation(description: "Wait 4 resend intervals")
        DispatchQueue.main.asyncAfter(deadline: .now() + resendInterval * 4) {
            wait4Intervals.fulfill()
        }
        waitForExpectations(timeout: resendInterval * 6, handler: nil)

        let pool = coalaClient.messagePool
        let messageInPool = pool.get(token: requestMessage.token)
        XCTAssertNil(messageInPool)
    }

    func testTimeout() {let url = URL(string: "coap://localhost:\(serverPort)/msg")
        coalaServer = nil // Stop server
        let responseInvoked = expectation(description: "Response invoked")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.onResponse = { response in
            switch response {
            case .error(let error):
                XCTAssert(error is CoAPMessagePoolError)
            case .message:
                XCTAssert(false)
            }
            responseInvoked.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: resendInterval * 5, handler: nil)
    }
}
