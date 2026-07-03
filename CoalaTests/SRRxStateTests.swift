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
        receiveState.didReceive(block: Data(), number: 0, isFinalBlock: true)
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
                receiveState.didReceive(block: blocks[index],
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
        receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     isFinalBlock: false)
        receiveState.didReceive(block: "o".data(using: .utf8)!,
                                     number: 1,
                                     isFinalBlock: false)
        receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 2,
                                     isFinalBlock: false)
        receiveState.didReceive(block: "l".data(using: .utf8)!,
                                     number: 3,
                                     isFinalBlock: false)
        receiveState.didReceive(block: "a".data(using: .utf8)!,
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
        receiveState.didReceive(block: "o".data(using: .utf8)!,
                                     number: 1,
                                     isFinalBlock: false)
        receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     isFinalBlock: false)
        receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 2,
                                     isFinalBlock: false)
        receiveState.didReceive(block: "a".data(using: .utf8)!,
                                     number: 4,
                                     isFinalBlock: true)
        receiveState.didReceive(block: "l".data(using: .utf8)!,
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
        receiveState.didReceive(block: "c".data(using: .utf8)!,
                                     number: 0,
                                     isFinalBlock: false)
        XCTAssertNil(receiveState.data)
    }

    func testDuplicateBlockDoesNotCorruptAccumulator() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: false)
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: false) // duplicate
        receiveState.didReceive(block: "b".data(using: .utf8)!, number: 1, isFinalBlock: true)
        XCTAssertEqual(String(data: receiveState.accumulator, encoding: .utf8), "ab")
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "ab")
    }

    func testAccumulatorIsContiguousPrefixUnderReordering() {
        receiveState = SRRxState()
        // gap: block 1 arrives before block 0 → no prefix yet
        receiveState.didReceive(block: "y".data(using: .utf8)!, number: 1, isFinalBlock: false)
        XCTAssertEqual(receiveState.accumulator, Data())
        // block 0 arrives → prefix becomes "xy"
        receiveState.didReceive(block: "x".data(using: .utf8)!, number: 0, isFinalBlock: false)
        XCTAssertEqual(String(data: receiveState.accumulator, encoding: .utf8), "xy")
    }

    func testPrematureFinalWithHoleStaysIncomplete() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: false)
        receiveState.didReceive(block: "c".data(using: .utf8)!, number: 2, isFinalBlock: true) // final, but 1 missing
        XCTAssertNil(receiveState.data)
        receiveState.didReceive(block: "b".data(using: .utf8)!, number: 1, isFinalBlock: false)
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "abc")
    }

    /// A non-conformant sender can mark an early block final (M=0) while
    /// higher-numbered blocks are already buffered. The transfer must complete
    /// (not hang) and must deliver exactly blocks 0...finalBlockNumber —
    /// buffered blocks past the declared end are ignored, not appended.
    func testFinalBlockArrivingAfterHigherBlocksCompletesTruncated() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "c".data(using: .utf8)!, number: 2, isFinalBlock: false)
        receiveState.didReceive(block: "b".data(using: .utf8)!, number: 1, isFinalBlock: false)
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: true)
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "a")
    }

    func testBlockArrivingAfterDeclaredFinalIsIgnored() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: true)
        receiveState.didReceive(block: "x".data(using: .utf8)!, number: 1, isFinalBlock: false)
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "a")
    }

    func testRetransmittedFinalBlockKeepsDataStable() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: false)
        receiveState.didReceive(block: "b".data(using: .utf8)!, number: 1, isFinalBlock: true)
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "ab")
        receiveState.didReceive(block: "b".data(using: .utf8)!, number: 1, isFinalBlock: true) // retransmit
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "ab")
    }

    func testEmptyFinalBlockCompletesTransfer() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: false)
        receiveState.didReceive(block: Data(), number: 1, isFinalBlock: true)
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "a")
    }

    /// The progress accumulator must also stop at the declared final block — the
    /// app's progress callback receives the accumulator.
    func testAccumulatorTruncatedWhenFinalArrivesBelowBufferedBlocks() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "y".data(using: .utf8)!, number: 1, isFinalBlock: false)
        receiveState.didReceive(block: "x".data(using: .utf8)!, number: 0, isFinalBlock: true)
        XCTAssertEqual(String(data: receiveState.accumulator, encoding: .utf8), "x")
        XCTAssertEqual(receiveState.data.flatMap { String(data: $0, encoding: .utf8) }, "x")
    }

    func testStrayBlocksAfterCompletionDoNotMutateData() {
        receiveState = SRRxState()
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: true)
        let completed = receiveState.data
        receiveState.didReceive(block: "z".data(using: .utf8)!, number: 5, isFinalBlock: false)
        receiveState.didReceive(block: "a".data(using: .utf8)!, number: 0, isFinalBlock: true) // dup
        XCTAssertEqual(receiveState.data, completed)
    }

    /// Deterministic heavy reordering: evens ascending, then odds descending with
    /// the final block delivered mid-batch. Reassembly must be byte-exact.
    func testHeavilyReorderedTransferReassemblesExactly() {
        receiveState = SRRxState()
        let count = 100
        let expected = Data((0..<count).map { UInt8($0) })
        let evens = stride(from: 0, to: count, by: 2)
        let oddsDescending = stride(from: count - 1, through: 1, by: -2)
        for number in Array(evens) + Array(oddsDescending) {
            receiveState.didReceive(block: Data([UInt8(number)]),
                                    number: number,
                                    isFinalBlock: number == count - 1)
        }
        XCTAssertEqual(receiveState.data, expected)
    }

}
