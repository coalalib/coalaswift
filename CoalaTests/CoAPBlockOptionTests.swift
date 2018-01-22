//
//  CoAPBlockOptionTests.swift
//  Coala
//
//  Created by Roman on 22/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class CoAPBlockOptionTests: XCTestCase {

    func testZeroBlockOptionToData() {
        let blockOption = CoAPBlockOption(num: 0, mFlag: false, szx: .size16)
        let data = blockOption.value.data
        XCTAssert(data.count == 0)
    }

    func test1ByteBlockOptionToData() {
        let blockOption = CoAPBlockOption(num: 0, mFlag: true, szx: .size16)
        let data = blockOption.value.data
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(UInt(data: data), 0b00001000)
    }

    func test2ByteBlockOptionToData() {
        let blockOption = CoAPBlockOption(num: 0b10110, mFlag: true, szx: .size128)
        let data = blockOption.value.data
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(UInt(data: data), 0b0000000101101011)
    }

    func test3ByteBlockOptionToData() {
        let blockOption = CoAPBlockOption(num: 0b1101101101101, mFlag: false, szx: .size1024)
        let data = blockOption.value.data
        XCTAssertEqual(data.count, 3)
        XCTAssertEqual(UInt(data: data), 0b000000011011011011010110)
    }

    func testZeroDataToBlockOption() {
        let data = Data()
        let blockOption = data.blockOption()
        XCTAssertEqual(blockOption?.num, 0)
        XCTAssertEqual(blockOption?.mFlag, false)
        XCTAssertEqual(blockOption?.szx, .size16)
    }

    func test1ByteDataToBlockOption() {
        let data = UInt(0b00001000).data
        let blockOption = data.blockOption()
        XCTAssertEqual(blockOption?.num, 0)
        XCTAssertEqual(blockOption?.mFlag, true)
        XCTAssertEqual(blockOption?.szx, .size16)
    }

    func test2ByteDataToBlockOption() {
        let data = UInt(0b0000000101101011).data
        let blockOption = data.blockOption()
        XCTAssertEqual(blockOption?.num, 0b10110)
        XCTAssertEqual(blockOption?.mFlag, true)
        XCTAssertEqual(blockOption?.szx, .size128)
    }

    func test3ByteDataToBlockOption() {
        let data = UInt(0b000000011011011011010110).data
        let blockOption = data.blockOption()
        XCTAssertEqual(blockOption?.num, 0b1101101101101)
        XCTAssertEqual(blockOption?.mFlag, false)
        XCTAssertEqual(blockOption?.szx, .size1024)
    }

}
