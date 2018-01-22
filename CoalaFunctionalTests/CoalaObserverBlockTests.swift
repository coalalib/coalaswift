//
//  CoalaObserverBlockTests.swift
//  CoalaFunctionalTests
//
//  Created by Roman on 03/10/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class CoalaObserverBlockTests: CoalaObserverTests {

    func testRegisterLargeResponse() {
        var sentNotifications = 0
        var receivedNotifications = 0
        let largePayload = Data.randomData(length: 520)
        let resource = ObservableResource(path: "/changing") { _ in
            sentNotifications += 1
            return (.content, largePayload)
        }
        coalaServer.addResource(resource)
        let registered = expectation(description: "Registered")
        let didGetNotification = expectation(description: "didGetNotification")
        coalaClient.startObserving(url: url) { notification in
            receivedNotifications += 1
            switch notification {
            case .error:
                XCTAssert(false)
            case .message(let message, _):
                XCTAssertEqual(message.payload?.data, largePayload)
            }
            if receivedNotifications == 1 {
                registered.fulfill()
                resource.notifyObservers()
            } else {
                didGetNotification.fulfill()
            }
        }
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssertEqual(receivedNotifications, 2)
        XCTAssertEqual(sentNotifications, 2)
    }
}
