//
//  SRReceiveState.swift
//  Coala
//
//  Created by Roman on 02/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

final class SRRxState {

    /// Final assembled payload, set once blocks 0...finalBlockNumber are all present.
    private(set) var data: Data?

    /// Contiguous received prefix, in block order. Used for progress reporting.
    /// (Previously an arrival-order concatenation that double-counted duplicates.)
    private(set) var accumulator = Data()

    /// Out-of-order blocks waiting for a gap to fill; cleared as the prefix advances.
    private var pending: [Int: Data] = [:]

    /// Index of the next block needed to extend the contiguous prefix.
    private var frontier = 0

    /// Final block number (block carrying M=0), once seen.
    private var finalBlockNumber: Int?

    func didReceive(block: Data, number: Int, isFinalBlock: Bool) {
        guard number >= frontier else { return }      // already consumed → duplicate
        guard pending[number] == nil else { return }  // duplicate not yet consumed

        if isFinalBlock {
            finalBlockNumber = number
        }
        // Non-conformant sender: ignore blocks past the declared final block,
        // so the delivered payload is exactly blocks 0...finalBlockNumber.
        if let finalBlockNumber = finalBlockNumber, number > finalBlockNumber { return }

        if number == frontier {
            accumulator.append(block)
            frontier += 1
            while finalBlockNumber.map({ frontier <= $0 }) ?? true,
                let next = pending.removeValue(forKey: frontier) {
                    accumulator.append(next)
                    frontier += 1
            }
        } else {
            pending[number] = block
        }

        if let finalBlockNumber = finalBlockNumber, frontier == finalBlockNumber + 1 {
            data = accumulator
        }
    }
}
