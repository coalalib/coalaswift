//
//  SecurityLayerTests.swift
//  Coala
//
//  Created by Roman on 08/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class SecurityLayerTests: CoalaTests {

    override func setUp() {
        super.setUp()
        timeout = super.timeout * 2
    }

    func testSecureMessage() {
        let requestText = "The quick, brown fox jumps over a lazy dog."
        let responseText = "Affirmative."
        let query = "sensibleOption=31"
        let resource = CoAPResource(method: .get, path: "/msg") { query, payload in
            XCTAssertEqual(query.first, URLQueryItem(name: "sensibleOption", value: "31"))
            XCTAssertEqual(payload?.string, requestText)
            return (.content, responseText)
        }
        coalaServer.addResource(resource)
        let expectationAckRecieved = expectation(description: "ACK received")
        let url = URL(string: "coaps://localhost:\(serverPort)/msg?\(query)")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.payload = requestText
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.scheme, .coapSecure)
                XCTAssertEqual(responseMessage.payload?.string, responseText)
            }
            expectationAckRecieved.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
        // test sent data is encrypted?
    }

    func testSecureMessageBlockwise() {
        let requestText = "The quick, brown fox jumps over a lazy dog."
        let largePayload = Data.randomData(length: 3000)
        let resource = CoAPResource(method: .get, path: "/msg") { _, payload in
            XCTAssertEqual(payload?.string, requestText)
            return (.content, largePayload)
        }
        coalaServer.addResource(resource)
        let expectationAckRecieved = expectation(description: "ACK received")
        let url = URL(string: "coaps://localhost:\(serverPort)/msg")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.payload = requestText
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.scheme, .coapSecure)
                XCTAssertEqual(responseMessage.payload?.data, largePayload)
            }
            expectationAckRecieved.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: timeout * 3, handler: nil)
        // test sent data is encrypted?
    }

    func testSessionRestart() {
        let requestText = "The quick, brown fox jumps over a lazy dog."
        let responseText = "Affirmative."
        let resource = CoAPResource(method: .get, path: "/msg") { _, payload in
            XCTAssertEqual(payload?.string, requestText)
            return (.content, responseText)
        }
        coalaServer.addResource(resource)
        let url = URL(string: "coaps://localhost:\(serverPort)/msg")

        // Request #1
        let extepctation1 = expectation(description: "First response")
        var request1 = CoAPMessage(type: .confirmable, method: .get, url: url)
        request1.payload = requestText
        request1.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.scheme, .coapSecure)
                XCTAssertEqual(responseMessage.payload?.string, responseText)
            }
            extepctation1.fulfill()
        }
        _ = try? coalaClient.send(request1)
        waitForExpectations(timeout: timeout, handler: nil)

        // Restart server
        coalaServer.stop()
        coalaServer = nil
        coalaServer = Coala(port: serverPort)
        coalaServer.addResource(resource)

        // Request #2
        let extepctation2 = expectation(description: "Second response")
        var request2 = CoAPMessage(type: .confirmable, method: .get, url: url)
        request2.payload = requestText
        request2.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.scheme, .coapSecure)
                XCTAssertEqual(responseMessage.payload?.string, responseText)
            }
            extepctation2.fulfill()
        }
        _ = try? coalaClient.send(request2)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testMITMAttack() {
        let resource = CoAPResource(method: .get, path: "/msg") { _, _ in
            return (.content, "Affirmative.")
        }
        coalaServer.addResource(resource)
        let expectationAckRecieved = expectation(description: "ACK received")
        let url = URL(string: "coaps://localhost:\(serverPort)/msg")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        let attackerPublicKey = "ff".dataFromHexadecimalString()
        requestMessage.peerPublicKey = attackerPublicKey
        requestMessage.onResponse = { response in
            switch response {
            case .error(let error):
                XCTAssert(error as? CoapsError == .peerPublicKeyValidationFailed)
            case .message:
                XCTAssert(false)
            }
            expectationAckRecieved.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testGetPeerPublicKey() {
        let resource = CoAPResource(method: .get, path: "/msg") { _, _ in
            return (.content, "Affirmative.")
        }
        coalaServer.addResource(resource)
        let expectationAckRecieved = expectation(description: "ACK received")
        let url = URL(string: "coaps://localhost:\(serverPort)/msg")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let message, _):
                XCTAssertNotNil(message.peerPublicKey)
                XCTAssert(message.peerPublicKey?.count == 32)
            }
            expectationAckRecieved.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: timeout, handler: nil)
    }

}
