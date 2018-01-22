//
//  SecurityIntegrationTests.swift
//  Coala
//
//  Created by Roman on 03/02/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class SecurityIntegrationTests: CoalaTests {

    func testServer() {
        let responseRecieved = expectation(description: "Response received")
        let url = URL(string: "coaps://46.101.158.16/info")
        var requestMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        var resultString: String = ""
        requestMessage.onResponse = { response in
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let responseMessage, _):
                XCTAssertEqual(responseMessage.responseCode, .content)
                resultString = responseMessage.payload?.string ?? ""
                NSLog("resultString: \(resultString)")
                responseRecieved.fulfill()
            }
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: networkTimeout, handler: nil)
    }

}
