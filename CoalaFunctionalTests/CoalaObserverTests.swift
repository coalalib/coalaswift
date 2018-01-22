//
//  CoalaObserverTests.swift
//  Coala
//
//  Created by Roman on 14/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class CoalaObserverTests: CoalaTests {

    var url: URL!
    var token: CoAPToken!
    var observedResourcesRegistry: ObservedResourcesRegistry!

    override func setUp() {
        super.setUp()
        token = CoAPToken(value: Data())
        timeout = super.timeout * 3
        url = URL(string: "coap://localhost:\(serverPort)/changing")
        observedResourcesRegistry = coalaClient.layerStack.observeLayer.observedResourcesRegistry
    }

    func testRegister() {
        let resource = CoAPMockResource(method: .get, path: "/changing") { [unowned self] message in
            var response = CoAPMessage(type: .confirmable, code: .response(.content))
            response.token = message.token
            self.token = message.token ?? CoAPToken(value: Data())
            response.setOption(.observe, value: 12)
            return response
        }
        coalaServer.addResource(resource)
        var registered: XCTestExpectation? = expectation(description: "Registered")
        coalaClient.startObserving(url: url) { _ in
            registered?.fulfill()
            registered = nil
        }
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssert(observedResourcesRegistry.resource(forToken: token) != nil)
    }

    func testRegisterFailByCode() {
        let resource = CoAPMockResource(method: .get, path: "/changing") { [unowned self] message in
            var response = CoAPMessage(type: .confirmable, code: .response(.badRequest))
            response.token = message.token
            self.token = message.token ?? CoAPToken(value: Data())
            response.setOption(.observe, value: 0)
            return response
        }
        coalaServer.addResource(resource)
        var registerFailed: XCTestExpectation? = expectation(description: "Reister failed code")
        coalaClient.startObserving(url: url) { _ in
            registerFailed?.fulfill()
            registerFailed = nil
        }
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssert(observedResourcesRegistry.resource(forToken: token) == nil)
    }

    func testRegisterFailByOption() {
        let resource = CoAPMockResource(method: .get, path: "/changing") { [unowned self] message in
            let response = CoAPMessage(ackTo: message, code: .content)
            self.token = message.token ?? CoAPToken(value: Data())
            return response
        }
        coalaServer.addResource(resource)
        var registerFailed: XCTestExpectation? = expectation(description: "Reister failed option")
        coalaClient.startObserving(url: url) { _ in
            registerFailed?.fulfill()
            registerFailed = nil
        }
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssert(observedResourcesRegistry.resource(forToken: token) == nil)
    }

    func notification(withToken: CoAPToken?, sequenceNumber: Int) -> CoAPMessage {
        var notification = CoAPMessage(type: .confirmable, code: .response(.content))
        notification.token = withToken
        notification.setOption(.observe, value: sequenceNumber)
        notification.url = URL(string: "coap://localhost:\(clientPort)/")!
        notification.payload = "\(sequenceNumber)"
        return notification
    }

    func testMultipleNotifications() {
        let resource = CoAPMockResource(method: .get, path: "/changing") { [weak self] message in
            guard let suite = self else {
                return CoAPMessage(type: .confirmable, code: .response(.content))
            }
            suite.token = message.token ?? CoAPToken(value: Data())
            try? suite.coalaServer.send(suite.notification(withToken: suite.token, sequenceNumber: 10))
            try? suite.coalaServer.send(suite.notification(withToken: suite.token, sequenceNumber: 11))
            return suite.notification(withToken: suite.token, sequenceNumber: 12)
        }
        coalaServer.addResource(resource)
        let expectationReceived = expectation(description: "Multiple notifications received")
        var notifications = 0
        coalaClient.startObserving(url: url) { _ in
            notifications += 1
            if notifications == 3 {
                expectationReceived.fulfill()
            }
        }
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testObservableResource() {
        var sentNotifications = 0
        var receivedNotifications = 0
        let resource = ObservableResource(path: "/changing") { _ in
            sentNotifications += 1
            return (.content, nil)
        }
        coalaServer.addResource(resource)
        let expectationRecieved = expectation(description: "Observable notification received")
        coalaClient.startObserving(url: url) { _ in
            receivedNotifications += 1
            switch receivedNotifications {
            case 1:
                resource.notifyObservers()
            case 2:
                expectationRecieved.fulfill()
            default:
                break
            }
        }
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssertEqual(receivedNotifications, 2)
        XCTAssertEqual(sentNotifications, 2)
    }

    func testDeregister() {
        var token: CoAPToken = CoAPToken(value: Data())
        var deregistered: XCTestExpectation? = expectation(description: "Client deregistered")
        let resource = CoAPMockResource(method: .get, path: "/changing") { message in
            token = message.token ?? CoAPToken(value: Data())
            deregistered?.fulfill()
            deregistered = nil
            return self.notification(withToken: token, sequenceNumber: 12)
        }
        coalaServer.addResource(resource)
        coalaClient.startObserving(url: url, onUpdate: { _ in})
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssert(observedResourcesRegistry.resource(forToken: token) != nil)
        coalaClient.stopObserving(url: url)
        XCTAssert(observedResourcesRegistry.resource(forToken: token) == nil)
    }

    func testObsrevableResourceDeregister() {
        let resource = ObservableResource(path: "/changing") { _ in
            return (.content, nil)
        }
        coalaServer.addResource(resource)
        let expectationExchangeFinished = expectation(description: "Exchange finished")
        coalaClient.startObserving(url: url) { [unowned self] _ in
            XCTAssertEqual(resource.observersCount, 1)
            self.coalaClient.stopObserving(url: self.url)
            var nextMessage = CoAPMessage(type: .confirmable, method: .get, url: self.url)
            nextMessage.onResponse = { _ in
                expectationExchangeFinished.fulfill()
            }
            try? self.coalaClient.send(nextMessage)
        }
        waitForExpectations(timeout: timeout * 2, handler: nil)
        XCTAssertEqual(resource.observersCount, 0)
    }

    func testNotificationInvalidToken() {
        let badNotificatonDelivered = expectation(description: "Notification delivered")
        let resource = CoAPMockResource(method: .get, path: "/changing") { message in
            let badToken = CoAPToken.generate()
            var badNotification = self.notification(withToken: badToken, sequenceNumber: 12)
            badNotification.onResponse = { response in
                switch response {
                case .error(let error):
                    XCTAssert(error as? ResponseLayer.ResponseLayerError == .requestHasBeenReset)
                case .message:
                    XCTAssert(false)
                }
                badNotificatonDelivered.fulfill()
            }
            try? self.coalaServer.send(badNotification)

            let okNotification = self.notification(withToken: message.token, sequenceNumber: 7)
            return okNotification
        }
        coalaServer.addResource(resource)
        coalaClient.startObserving(url: url) { _ in }
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testMaxAge() {
        let registeredTwice = expectation(description: "Registered twice")
        var registeredTimes = 0
        let resource = CoAPMockResource(method: .get, path: "/changing") { message in
            registeredTimes += 1
            if registeredTimes == 2 {
                registeredTwice.fulfill()
            }
            var expiredNotification =  self.notification(withToken: message.token,
                                                         sequenceNumber: 12)
            expiredNotification.setOption(.maxAge, value: 0)
            return expiredNotification
        }
        coalaServer.addResource(resource)
        coalaClient.layerStack.observeLayer.observedResourcesRegistry.expirationRandomDelay = 0...0
        coalaClient.startObserving(url: url) { _ in }
        waitForExpectations(timeout: timeout + 1, handler: nil)
    }

    func testReordering() {
        let resource = CoAPMockResource(method: .get, path: "/changing") { [weak self] message in
            guard let suite = self else {
                return CoAPMessage(type: .confirmable, code: .response(.content))
            }
            suite.token = message.token ?? CoAPToken(value: Data())
            try? suite.coalaServer.send(suite.notification(withToken: suite.token, sequenceNumber: 10))
            try? suite.coalaServer.send(suite.notification(withToken: suite.token, sequenceNumber: 9))
            return suite.notification(withToken: suite.token, sequenceNumber: 11)
        }
        coalaServer.addResource(resource)
        let expectationReceived = expectation(description: "Multiple notifications received")
        var notificationsCount = 0
        coalaClient.startObserving(url: url) { notification in
            notificationsCount += 1
            switch notification {
            case .message(let message, _):
                let sequenceNumber = message.getIntegerOptions(.observe).first
                switch sequenceNumber {
                case .some(9):
                    XCTAssert(false)
                case .some(11):
                    expectationReceived.fulfill()
                default:
                    break
                }
            default:
                break
            }
        }
        waitForExpectations(timeout: timeout, handler: nil)
        XCTAssertEqual(notificationsCount, 2)
    }

}
