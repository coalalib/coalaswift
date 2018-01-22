//
//  CoalaTests.swift
//  CoalaTests
//
//  Created by Roman on 07/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

private class CoalaSubclass: Coala {
    var onDeinit: (() -> Void)?
    deinit {
        onDeinit?()
    }
}

class CoalaTests: XCTestCase {

    var coalaServer, coalaClient: Coala!
    let serverPort: UInt16 = 7826
    let clientPort: UInt16 = 6287

    var timeout = 0.1
    var networkTimeout = 2.0

    override func setUp() {
        super.setUp()
        timeout = 0.1
        networkTimeout = 2.0
        coalaServer = CoalaSubclass(port: serverPort)
        coalaClient = CoalaSubclass(port: clientPort)
//        for coalaInstance in [coalaClient, coalaServer] {
//            coalaInstance!.layerStack.logLayer.visual = true
//        }
    }

    override func tearDown() {
        var memoryExpectatons = [XCTestExpectation]()
        if let client = coalaClient as? CoalaSubclass {
            let clientDidFreeMemory = expectation(description: "Client did free memory")
            client.onDeinit = {
                clientDidFreeMemory.fulfill()
            }
            memoryExpectatons.append(clientDidFreeMemory)
        }
        if let server = coalaServer as? CoalaSubclass {
            let serverDidFreeMemory = expectation(description: "Server did free memory")
            server.onDeinit = {
                serverDidFreeMemory.fulfill()
            }
            memoryExpectatons.append(serverDidFreeMemory)
        }
        coalaServer?.stop()
        coalaClient?.stop()
        coalaServer = nil
        coalaClient = nil
        wait(for: memoryExpectatons, timeout: 1)
        super.tearDown()
    }

}
