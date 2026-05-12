//
//  SRRxStateTests.swift
//  Coala
//
//  Created by Roman on 02/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class SRRxStateTests: XCTestCase {

    var receiveState: SRRxState!

    override func setUp() {
        super.setUp()
        receiveState = SRRxState()
    }

    func testEmptyData() {
        try? receiveState.didReceive(block: Data(), number: 0, isFinalBlock: true)
        XCTAssertNotNil(receiveState.data)
    }

    func testVariousWindowSizes() {
        let exmpleString = "Lorem ipsum dolor sit amet"
        let blocks = exmpleString.map {
            String($0).data(using: .utf8)!
        }
        for windowSize in 1 ... blocks.count {
            receiveState = SRRxState()
            for index in 0 ..< blocks.count {
                try? receiveState.didReceive(block: blocks[index],
                                             number: index,
                                             isFinalBlock: index == blocks.count - 1)
            }
            XCTAssertNotNil(receiveState.data)
            if let data = receiveState.data {
                let string = String(data: data, encoding: .utf8)
                XCTAssertEqual(string, exmpleString)
            }
        }
    }

    func testSequence() {
        receiveState = SRRxState()
        try? receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     isFinalBlock: false)
        try? receiveState.didReceive(block: "o".data(using: .utf8)!,
                                     number: 1,
                                     isFinalBlock: false)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 2,
                                     isFinalBlock: false)
        try? receiveState.didReceive(block: "l".data(using: .utf8)!,
                                     number: 3,
                                     isFinalBlock: false)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 4,
                                     isFinalBlock: true)
        XCTAssertNotNil(receiveState.data)
        if let data = receiveState.data {
            let string = String(data: data, encoding: .utf8)
            XCTAssertEqual(string, "coala")
        }
    }

    func testNonSequence() {
        receiveState = SRRxState()
        try? receiveState.didReceive(block: "o".data(using: .utf8)!,
                                     number: 1,
                                     isFinalBlock: false)
        try? receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     isFinalBlock: false)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 2,
                                     isFinalBlock: false)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 4,
                                     isFinalBlock: true)
        try? receiveState.didReceive(block: "l".data(using: .utf8)!,
                                     number: 3,
                                     isFinalBlock: false)
        XCTAssertNotNil(receiveState.data)
        if let data = receiveState.data {
            let string = String(data: data, encoding: .utf8)
            XCTAssertEqual(string, "coala")
        }
    }

    func testDataIsNilBeforeFinalBlock() {
        receiveState = SRRxState()
        try? receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     isFinalBlock: false)
        XCTAssertNil(receiveState.data)
    }

}
