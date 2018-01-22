//
//  SRTxStateTests.swift
//  Coala
//
//  Created by Roman on 03/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

extension SRTxState {

    func popBlocks() -> [SRTxBlock] {
        var blocks = [SRTxBlock]()
        while let block = popBlock() {
            blocks.append(block)
        }
        return blocks
    }

}

class SRTxStateTests: XCTestCase {

    func testEmptyData() {
        let state = SRTxState(data: Data(), windowSize: 42, blockSize: 5)
        XCTAssertNil(state.popBlock())
        XCTAssert(state.isCompleted)
    }

    func testSingleByte() {
        let byte = "!".data(using: .utf8)!
        let state = SRTxState(data: byte, windowSize: 42, blockSize: 5)
        let block = state.popBlock()
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.data, byte)
        XCTAssertEqual(block?.number, 0)
        XCTAssertEqual(block?.isMoreComing, false)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 0)
        XCTAssert(state.isCompleted)
        XCTAssertNil(state.popBlock())
        XCTAssert(state.isCompleted)
    }

    func testSingleBlock() {
        let data = "somedata".data(using: .utf8)!
        let state = SRTxState(data: data, windowSize: 3, blockSize: 8)
        let block = state.popBlock()
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.data, data)
        XCTAssertEqual(block?.number, 0)
        XCTAssertEqual(block?.isMoreComing, false)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 0)
        XCTAssert(state.isCompleted)
        XCTAssertNil(state.popBlock())
        XCTAssert(state.isCompleted)
    }

    func testMultipleBlocks() {
        let data = "1234567890".data(using: .utf8)!
        let state = SRTxState(data: data, windowSize: 2, blockSize: 3)
        let blocks = state.popBlocks()
        guard blocks.count == 2 else {
            XCTAssert(false)
            return
        }
        XCTAssertEqual(blocks[0].data, "123".data(using: .utf8))
        XCTAssertEqual(blocks[0].number, 0)
        XCTAssertEqual(blocks[0].isMoreComing, true)
        XCTAssertEqual(blocks[1].data, "456".data(using: .utf8))
        XCTAssertEqual(blocks[1].number, 1)
        XCTAssertEqual(blocks[1].isMoreComing, true)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 1)
        XCTAssertNil(state.popBlock())
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 0)
        let moreBlocks = state.popBlocks()
        guard moreBlocks.count == 2 else {
            XCTAssert(false)
            return
        }
        XCTAssertEqual(moreBlocks[0].data, "789".data(using: .utf8))
        XCTAssertEqual(moreBlocks[0].number, 2)
        XCTAssertEqual(moreBlocks[0].isMoreComing, true)
        XCTAssertEqual(moreBlocks[1].data, "0".data(using: .utf8))
        XCTAssertEqual(moreBlocks[1].number, 3)
        XCTAssertEqual(moreBlocks[1].isMoreComing, false)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 2)
        XCTAssert(state.popBlocks().count == 0)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 3)
        XCTAssert(state.isCompleted)
        XCTAssert(state.popBlocks().count == 0)
        XCTAssert(state.isCompleted)
    }

    func testMultipleBlocksWrongOrder() {
        let data = "1234567890".data(using: .utf8)!
        let state = SRTxState(data: data, windowSize: 2, blockSize: 3)
        let blocks = state.popBlocks()
        guard blocks.count == 2 else {
            XCTAssert(false)
            return
        }
        XCTAssertEqual(blocks[0].data, "123".data(using: .utf8))
        XCTAssertEqual(blocks[0].number, 0)
        XCTAssertEqual(blocks[0].isMoreComing, true)
        XCTAssertEqual(blocks[1].data, "456".data(using: .utf8))
        XCTAssertEqual(blocks[1].number, 1)
        XCTAssertEqual(blocks[1].isMoreComing, true)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 1)
        XCTAssertNil(state.popBlock())
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 0)
        let moreBlocks = state.popBlocks()
        guard moreBlocks.count == 2 else {
            XCTAssert(false)
            return
        }
        XCTAssertEqual(moreBlocks[0].data, "789".data(using: .utf8))
        XCTAssertEqual(moreBlocks[0].number, 2)
        XCTAssertEqual(moreBlocks[0].isMoreComing, true)
        XCTAssertEqual(moreBlocks[1].data, "0".data(using: .utf8))
        XCTAssertEqual(moreBlocks[1].number, 3)
        XCTAssertEqual(moreBlocks[1].isMoreComing, false)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 3)
        XCTAssert(state.popBlocks().count == 0)
        XCTAssertFalse(state.isCompleted)
        try? state.didTransmit(blockNumber: 2)
        XCTAssert(state.isCompleted)
        XCTAssert(state.popBlocks().count == 0)
        XCTAssert(state.isCompleted)
    }

}
