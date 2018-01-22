//
//  ObserverTests.swift
//  Coala
//
//  Created by Roman on 20/03/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class ObserverTests: CoalaTests {

    override func setUp() {
        super.setUp()
        timeout = 10
    }

    func stopObserving(url: URL) {
        print("Test completed, unsubscribing")
        let didStopObserving = expectation(description: "didStopObserving")
        coalaClient.stopObserving(url: url) {
            print("Unsubscribed")
            didStopObserving.fulfill()
        }
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testNonBlock() {
        let url = URL(string: "coap://46.101.158.16:5684/info?period=1")!
        var registered: XCTestExpectation? = expectation(description: "Registered")
        let notificationsReceived = expectation(description: "notificationsReceived")
        var notifications = 0
        coalaClient.startObserving(url: url) { _ in
            notifications += 1
            print("Notification #\(notifications) OK")
            if notifications == 3 {
                notificationsReceived.fulfill()
                print("All notifications received")
            }
            registered?.fulfill()
            registered = nil
        }
        waitForExpectations(timeout: timeout, handler: nil)
        stopObserving(url: url)
    }

    func testBlock() {
        let url = URL(string: "coap://46.101.158.16:5684/tests/large?period=1")!
        var registered: XCTestExpectation? = expectation(description: "Registered")
        let notificationsReceived = expectation(description: "notificationsReceived")
        var notifications = 0
        coalaClient.startObserving(url: url) { _ in
            notifications += 1
            print("Notification #\(notifications) OK")
            if notifications == 3 {
                notificationsReceived.fulfill()
                print("All notifications received")
            }
            registered?.fulfill()
            registered = nil
        }
        waitForExpectations(timeout: timeout, handler: nil)
        stopObserving(url: url)
    }

    func testBlockCoaps() {
        let url = URL(string: "coaps://46.101.158.16:5684/tests/large?period=1")!
        var registered: XCTestExpectation? = expectation(description: "Registered")
        let notificationsReceived = expectation(description: "notificationsReceived")
        var notifications = 0
        coalaClient.startObserving(url: url) { response in
            notifications += 1
            print("Notification #\(notifications) OK")
            switch response {
            case .error:
                XCTAssert(false)
            case .message(let message, _):
                let payload = message.payload?.string ?? ""
                XCTAssert(payload.characters.count > 0)
                print("Response:" + payload)
            }
            if notifications == 3 {
                notificationsReceived.fulfill()
                print("All notifications received")
            }
            registered?.fulfill()
            registered = nil
        }
        waitForExpectations(timeout: timeout, handler: nil)
        stopObserving(url: url)
    }

//    func testHundredIterations() {
//        for iteration in 1...100 {
//            testNonBlock()
//            print("Iteration \(iteration) completed")
//        }
//    }
//
//    func testHundredBlockIterations() {
//        for iteration in 1...100 {
//            testNonBlock()
//            print("Iteration \(iteration) completed")
//        }
//    }

}
