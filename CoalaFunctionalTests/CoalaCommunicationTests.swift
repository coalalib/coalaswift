//
//  CoalaCommunicationTests.swift
//  Coala
//
//  Created by Roman on 15/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
import Coala

class CoalaCommunicationTests: CoalaTests {

    func testGETResourceReached() {
        let expectationReceived = expectation(description: "GET Resource reached")
        let resource = CoAPResource(method: .get, path: "/msg") { _ in
            expectationReceived.fulfill()
            return (.content, nil)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/msg")
        let requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testPOSTResourceReached() {
        let expectationReceived = expectation(description: "POST Resource reached")
        let resource = CoAPResource(method: .post, path: "/msg") { _ in
            expectationReceived.fulfill()
            return (.content, nil)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/msg?cid=iPhone")
        let requestMessage = CoAPMessage(type: .confirmable, method: .post, url: url)
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testURLQueryReceived() {
        let expectationReceived = expectation(description: "URL query received")
        let resource = CoAPResource(method: .get, path: "/msg") { query, _ in
            XCTAssertEqual(query.count, 1)
            XCTAssertEqual(query.first?.name, "cid")
            XCTAssertEqual(query.first?.value, "iPhone")
            expectationReceived.fulfill()
            return (.content, nil)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coap://localhost:\(serverPort)/msg?cid=iPhone")
        let requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testConfirmablePiggybackedReceived() {
        let expectedPayload = "PiggyBackedContent"
        let resource = CoAPResource(method: .get, path: "/msg") { _ in
            return (.content, expectedPayload)
        }
        coalaServer.addResource(resource)
        let expectationAckRecieved = expectation(description: "ACK received")
        let url = URL(string: "coap://localhost:\(serverPort)/msg")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.payload?.string, expectedPayload)
            }
            expectationAckRecieved.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: 10, handler: nil)
    }

//    func testConfirmableSeparateReceived() {
//        XCTAssert(false)
//    }
//
//    func testDuplicateResponse() {
//        XCTAssert(false)
//    }
}
