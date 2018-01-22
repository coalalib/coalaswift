//
//  SRReceiveState.swift
//  Coala
//
//  Created by Roman on 02/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

enum SRRxError: Error {
    case windowSizeChangeNotYetSupported
}

class SRRxState {

    init(windowSize: Int) {
        window = SlidingWindow(size: windowSize)
    }

    private var accumulator = Data()
    private let window: SlidingWindow<Data>
    private var lastBlockNumber: Int?

    var data: Data? {
        let offset = window.getOffset()
        let isTransferCompleted = offset - 1 == lastBlockNumber
        return isTransferCompleted ? accumulator : nil
    }

    func didReceive(block: Data, number: Int, windowSize: Int, isMoreComing: Bool) throws {
        if window.size != windowSize {
            throw SRRxError.windowSizeChangeNotYetSupported
        }
        try window.set(value: block, atIndex: number)
        if !isMoreComing {
            lastBlockNumber = number
        }
        while let firstBlock = window.advance() {
            accumulator.append(firstBlock)
        }
    }
}
