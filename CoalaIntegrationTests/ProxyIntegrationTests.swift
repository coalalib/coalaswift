//
//  ProxyIntegrationTests.swift
//  Coala
//
//  Created by Roman on 20/06/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class ProxyIntegrationTests: CoalaTests {

    func testServerCoapNonSecure() {
        let proxyAddress = Address(host: "46.101.158.16", port: 5686)
        let targetUrl = URL(string: "coap://46.101.158.16:5684/info")
        let expectedResponse = "{\"cid\":\"account\",\"type\":\"account\",\"name\":\"account-dev-TC-DEV-01\"}"

        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: targetUrl)
        requestMessage.proxyViaAddress = proxyAddress
        var resultString: String = ""
        let responseRecieved = expectation(description: "Response received")
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                resultString = responseMessage.payload?.string ?? ""
                responseRecieved.fulfill()
            }
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: networkTimeout, handler: nil)
        XCTAssertEqual(expectedResponse, resultString)
    }

    func testServerCoapSecure() {
        let proxyAddress = Address(host: "46.101.158.16", port: 5686)
        let targetUrl = URL(string: "coaps://46.101.158.16:5684/info")
        let expectedResponse = "{\"cid\":\"account\",\"type\":\"account\",\"name\":\"account-dev-TC-DEV-01\"}"

        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: targetUrl)
        requestMessage.proxyViaAddress = proxyAddress
        var resultString: String = ""
        let responseRecieved = expectation(description: "Response received")
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                resultString = responseMessage.payload?.string ?? ""
                responseRecieved.fulfill()
            }
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: networkTimeout, handler: nil)
        XCTAssertEqual(expectedResponse, resultString)
    }

}
