//
//  ResourceDiscoveryTests.swift
//  Coala
//
//  Created by Roman on 20/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class ResourceDiscoveryTests: CoalaTests {

    func testNoResoucesFound() {
        let discoveryCompleted = expectation(description: "Discovery completed")
        coalaClient.resourceDiscovery.run(timeout: timeout,
                                          port: Coala.defaultPort) { discoveredPeers in
                                            print(discoveredPeers)
                                            XCTAssertEqual(discoveredPeers.count, 1)
                                            // XCTAssertEqual(discoveredPeers.first?.supportedMethods.count, 0)
                                            discoveryCompleted.fulfill()
        }
        waitForExpectations(timeout: timeout, handler: nil)
    }

    func testSingleResourceFound() {
        let resource = CoAPResource(method: .get, path: "/msg") { _ in
            return (.content, nil)
        }
        coalaServer.addResource(resource)
        let discoveryCompleted = expectation(description: "Discovery completed")
        coalaClient.resourceDiscovery.run(timeout: timeout,
                                          port: coalaServer.port) { discoveredPeers in
                                            XCTAssertEqual(discoveredPeers.count, 1)
                                            discoveryCompleted.fulfill()
        }
        waitForExpectations(timeout: timeout, handler: nil)
    }

}
