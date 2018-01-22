//
//  BlockwiseTranserTests.swift
//  Coala
//
//  Created by Roman on 03/02/17.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class BlockwiseTranserTests: CoalaTests {

    let ndmServer = "46.101.158.16"

    override func setUp() {
        super.setUp()
        timeout = 0.5
        (Coala.logger as? DefaultLogger)?.minLogLevel = .debug
    }

    func testGetBlock2FromCoapMe() {
        let blocksReceived = expectation(description: "Blocks received")
        let url = URL(string: "coap://coap.me/large")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        var resultString: String = ""
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                resultString = responseMessage.payload?.string ?? ""
                blocksReceived.fulfill()
            }
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: networkTimeout, handler: nil)
        XCTAssert(resultString.characters.count > 512)
    }

    func testPostBlock1ToNDMServer() {
        let responseReceived = expectation(description: "Response received")
        let largePayload = Data.randomData(length: 3000)
        let url = URL(string: "coap://\(ndmServer)/tests/large")
        var requestMessage = CoAPMessage(type: .confirmable, method: .post, url: url)
        requestMessage.payload = largePayload
        requestMessage.query = [URLQueryItem(name: "hash",
                                             value: MD5(largePayload).hexDescription)]
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let message, _):
                XCTAssertEqual(message.payload?.string, "SUCCESSFUL")
            }
            responseReceived.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: networkTimeout, handler: nil)
    }

    func testGetBlock2FromNDMServer() {
        let responseReceived = expectation(description: "Response received")
        let url = URL(string: "coap://\(ndmServer)/tests/large")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        requestMessage.query = [URLQueryItem(name: "size",
                                             value: "3000")]
        requestMessage.onResponse = { response in
            XCTAssertFalse(response.isError)
            responseReceived.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: networkTimeout, handler: nil)
    }

    func testMixedBlock1Block2NDMServer() {
        let responseReceived = expectation(description: "Response received")
        let largePayload = Data.randomData(length: 1000)
        let url = URL(string: "coap://\(ndmServer)/tests/mirror")
        var requestMessage = CoAPMessage(type: .confirmable, method: .post, url: url)
        requestMessage.payload = largePayload
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let message, _):
                XCTAssertEqual(message.payload?.data, largePayload)
            }
            responseReceived.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: networkTimeout, handler: nil)
    }

}
