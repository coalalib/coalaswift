//
//  SRTxState.swift
//  Coala
//
//  Created by Roman on 03/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

struct SRTxBlock {
    let number: Int
    let data: Data
    let isMoreComing: Bool
}

final class SRTxState {

    let data: Data
    let blockSize: Int

    private var window: SlidingWindow<Bool>

    init(data: Data, windowSize: Int, blockSize: Int) {
        self.data = data
        self.blockSize = blockSize
        let totalBlocks = data.count / blockSize + (data.count % blockSize != 0 ? 1 : 0)
        let windowSize = min(windowSize, totalBlocks)
        window = SlidingWindow(size: windowSize, offset: -windowSize)
        guard windowSize > 0 else { return }
        for index in -windowSize ... -1 {
            try? window.set(value: true, atIndex: index)
        }
    }

    var isCompleted: Bool {
        var lastDeliveredBlock = window.getOffset()
        var index = 0
        while index < window.size && window.getValue(atWindowIndex: index) == true {
            lastDeliveredBlock += 1
            index += 1
        }
        return lastDeliveredBlock * blockSize >= data.count
    }

    var windowSize: Int {
        return window.size
    }

    func didTransmit(blockNumber: Int) throws {
        try window.set(value: true, atIndex: blockNumber)
    }

    func popBlock() -> SRTxBlock? {
        guard window.advance() != nil else {
            return nil
        }
        let blockNumber = window.tail
        let rangeStart = blockNumber * blockSize
        let rangeEnd = min(rangeStart + blockSize, data.count)
        guard rangeStart < rangeEnd else {
            return nil
        }
        let block = data.subdata(in: rangeStart..<rangeEnd)
        return SRTxBlock(number: blockNumber, data: block, isMoreComing: rangeEnd != data.count)
    }
}
