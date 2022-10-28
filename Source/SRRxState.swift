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

final class SRRxState {

    /// Final loaded data result
    private(set) var data: Data?

    /// Unsorted number of blocks to calculate progress
    private(set) var accumulator = Data()

    /// Intermediate result of received data, should be sorted according index after
    /// receiving final block
    private var receivedData: [Int: Data] = [:]

    /// Final block number needed to check for transmission is ended
    private var finalBlockNumber: Int?
  
    func didReceive(block: Data, number: Int, isFinalBlock: Bool) throws {
        accumulator.append(block)
        receivedData[number] = block

        if isFinalBlock {
            finalBlockNumber = number
        }

        // if we receive all data, then prepare result
        if finalBlockNumber == receivedData.count - 1 {
            data = receivedData
              .sorted { $0.key < $1.key }
              .reduce(into: Data(), { partialResult, item in
                  partialResult.append(item.value)
              })
        }
    }
}
