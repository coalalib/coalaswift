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
        receiveState = SRRxState(windowSize: 10)
    }

    func testEmptyData() {
        try? receiveState.didReceive(block: Data(), number: 0, windowSize: 10, isMoreComing: false)
        XCTAssertNotNil(receiveState.data)
    }

    func testVariousWindowSizes() {
        let exmpleString = "Lorem ipsum dolor sit amet"
        let blocks = exmpleString.map {
            String($0).data(using: .utf8)!
        }
        for windowSize in 1 ... blocks.count {
            receiveState = SRRxState(windowSize: windowSize)
            for index in 0 ..< blocks.count {
                try? receiveState.didReceive(block: blocks[index],
                                             number: index,
                                             windowSize: windowSize,
                                             isMoreComing: index != blocks.count - 1)
            }
            XCTAssertNotNil(receiveState.data)
            if let data = receiveState.data {
                let string = String(data: data, encoding: .utf8)
                XCTAssertEqual(string, exmpleString)
            }
        }
    }

    func testSequence() {
        let windowSize = 3
        receiveState = SRRxState(windowSize: windowSize)
        try? receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        try? receiveState.didReceive(block: "o".data(using: .utf8)!,
                                     number: 1,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 2,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        try? receiveState.didReceive(block: "l".data(using: .utf8)!,
                                     number: 3,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 4,
                                     windowSize: windowSize,
                                     isMoreComing: false)
        XCTAssertNotNil(receiveState.data)
        if let data = receiveState.data {
            let string = String(data: data, encoding: .utf8)
            XCTAssertEqual(string, "coala")
        }
    }

    func testNonSequence() {
        let windowSize = 3
        receiveState = SRRxState(windowSize: windowSize)
        try? receiveState.didReceive(block: "o".data(using: .utf8)!,
                                     number: 1,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        try? receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 2,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        try? receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 4,
                                     windowSize: windowSize,
                                     isMoreComing: false)
        try? receiveState.didReceive(block: "l".data(using: .utf8)!,
                                     number: 3,
                                     windowSize: windowSize,
                                     isMoreComing: true)
        XCTAssertNotNil(receiveState.data)
        if let data = receiveState.data {
            let string = String(data: data, encoding: .utf8)
            XCTAssertEqual(string, "coala")
        }
    }

    func testOutOfWindow() {
        let windowSize = 3
        receiveState = SRRxState(windowSize: windowSize)
        do {
            try receiveState.didReceive(block: "l".data(using: .utf8)!,
                                        number: 3,
                                        windowSize: windowSize,
                                        isMoreComing: true)
            XCTAssert(false)
        } catch let error {
            XCTAssertEqual(error as? SlidingWindowError, .outOfBounds)
        }
    }

}
