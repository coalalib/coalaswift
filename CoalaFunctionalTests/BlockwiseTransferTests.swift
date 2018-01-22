//
//  BlockwiseTranserTests.swift
//  Coala
//
//  Created by Roman on 11/10/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class BlockwiseTranserTests: CoalaTests {

    override func setUp() {
        super.setUp()
        timeout = 0.8
    }

    func clientSend(_ message: CoAPMessage) {
        do {
            try coalaClient.send(message)
        } catch let error {
            print("Send error: \(error)")
            XCTAssert(false)
        }
    }

    func testGetLargeData() {
        let blocksReceived = expectation(description: "Blocks received")
        let largePayload = Data.randomData(length: 40000)
        var resourceAccessedTimes = 0
        let resource = CoAPResource(method: .get, path: "/large") { _ in
            resourceAccessedTimes += 1
            XCTAssertEqual(resourceAccessedTimes, 1)
            return (.content, largePayload)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/large")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        var numberOfResponses = 0
        requestMessage.onResponse = { response in
            LogVerbose("testGetLargeData Repsonse")
            numberOfResponses += 1
            guard numberOfResponses == 1 else {
                XCTAssert(false)
                return
            }
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.payload?.data, largePayload)
            }
            blocksReceived.fulfill()
        }
        clientSend(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testPostBlock1NotFound() {
        let largePayload = Data.randomData(length: 3000)
        let responseReceived = expectation(description: "Response received")
        let resource = CoAPResource(method: .post, path: "/post-large") { _ in
            XCTAssert(false)
            return (.created, nil)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/post-large")
        // Send get instead of post
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.payload = largePayload
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let message, _):
                XCTAssertEqual(message.responseCode, .methodNotAllowed)
                responseReceived.fulfill()
            }
        }
        clientSend(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testPostLargeData() {
        let largePayload = Data.randomData(length: 40000)
        let responseReceived = expectation(description: "Response received")
        var resourceAccessedTimes = 0
        let resource = CoAPResource(method: .post, path: "/post-large") { _, payload in
            resourceAccessedTimes += 1
            XCTAssertEqual(payload?.data, largePayload)
            return (.changed, "OK, got it")
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/post-large")
        var requestMessage = CoAPMessage(type: .confirmable, method: .post, url: url)
        requestMessage.payload = largePayload
        requestMessage.onResponse = { response in
            XCTAssertFalse(response.isError)
            responseReceived.fulfill()
        }
        clientSend(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssertEqual(resourceAccessedTimes, 1)
    }

    func testMixedBlock1Block2Local() {
        let requestPayload = Data.randomData(length: 1200)
        let responsePayload = Data.randomData(length: 2999)
        let responseReceived = expectation(description: "Response received")
        let resourceAccessed = expectation(description: "Resource accessed")
        let resource = CoAPResource(method: .post, path: "/post-large") { _, payload in
            XCTAssertEqual(payload?.data, requestPayload)
            resourceAccessed.fulfill()
            return (.changed, responsePayload)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/post-large")
        var requestMessage = CoAPMessage(type: .confirmable, method: .post, url: url)
        requestMessage.payload = requestPayload
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let message, _):
                XCTAssertEqual(message.payload?.data, responsePayload)
            }
            responseReceived.fulfill()
        }
        clientSend(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testParallelGetLargeData() {
        let largePayload = Data.randomData(length: 3000)
        var resourceAccessedTimes = 0
        let resource = CoAPResource(method: .get, path: "/large") { _ in
            resourceAccessedTimes += 1
            return (.content, largePayload)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/large")
        var requestMessage1 = CoAPMessage(type: .confirmable, method: .get, url: url)
        let response1Recevied = expectation(description: "Response 1 recevied")
        var response1Count = 0
        requestMessage1.onResponse = { response in
            response1Count += 1
            guard response1Count == 1 else {
                XCTAssert(false)
                return
            }
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.payload?.data, largePayload)
            }
            response1Recevied.fulfill()
        }
        var requestMessage2 = CoAPMessage(type: .confirmable, method: .get, url: url)
        let response2Recevied = expectation(description: "Response 2 recevied")
        var response2Count = 0
        requestMessage2.onResponse = { response in
            response2Count += 1
            guard response2Count == 1 else {
                XCTAssert(false)
                return
            }
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.payload?.data, largePayload)
            }
            response2Recevied.fulfill()
        }
        clientSend(requestMessage1)
        clientSend(requestMessage2)
        XCTAssertNotEqual(requestMessage1.token, requestMessage2.token)
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssertEqual(resourceAccessedTimes, 2)
    }

    func testParallelPostLargeData() {
        let largePayload = Data.randomData(length: 3000)
        var resourceAccessedTimes = 0
        let resource = CoAPResource(method: .post, path: "/large") { _, payload in
            resourceAccessedTimes += 1
            XCTAssertEqual(payload?.data, largePayload)
            return (.changed, "OK, got it")
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/large")
        var requestMessage1 = CoAPMessage(type: .confirmable, method: .post, url: url)
        requestMessage1.payload = largePayload
        let response1Recevied = expectation(description: "Response 1 recevied")
        requestMessage1.onResponse = { response in
            XCTAssertFalse(response.isError)
            response1Recevied.fulfill()
        }
        var requestMessage2 = CoAPMessage(type: .confirmable, method: .post, url: url)
        requestMessage2.payload = largePayload
        let response2Recevied = expectation(description: "Response 2 recevied")
        requestMessage2.onResponse = { response in
            XCTAssertFalse(response.isError)
            response2Recevied.fulfill()
        }
        clientSend(requestMessage1)
        clientSend(requestMessage2)
        XCTAssertNotEqual(requestMessage1.token, requestMessage2.token)
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssertEqual(resourceAccessedTimes, 2)
    }

    func testServerUnreachable() {
        let largePayload = Data.randomData(length: 3000)
        let responseReceived = expectation(description: "Response received")
        coalaClient.messagePool.resendTimeInterval = 0.01
        coalaServer = nil
        let url = URL(string: "coap://localhost:\(serverPort)/post-large")
        // Send get instead of post
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.payload = largePayload
        requestMessage.onResponse = { response in
            switch response {
            case .error(let error):
                let error = error as? CoAPMessagePoolError
                switch error {
                case .some(.messageExpired):
                    XCTAssert(true)
                default:
                    XCTAssert(false)
                }
            case .message:
                XCTAssert(false)
            }
            responseReceived.fulfill()
        }
        clientSend(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

}
