//
//  ARQStates.swift
//  Coala
//
//  Created by Roman on 18/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

private let bytesFormatter = BinaryByteFormatter()

extension ARQLayer {

    struct TransmitState {
        let token: CoAPToken
        let originalMessage: CoAPMessage
        var selectiveRepeat: SRTxState
        let start = Date()
        var retransmitCount = 0

        init(token: CoAPToken, originalMessage: CoAPMessage, selectiveRepeat: SRTxState) {
            self.token = token
            self.originalMessage = originalMessage
            self.selectiveRepeat = selectiveRepeat
        }

        func logCompleted() {
            let timeInterval = Date().timeIntervalSince(start)
            let bytesTotal = selectiveRepeat.data.count
            let bytesPerSec = Int(Double(bytesTotal) / timeInterval)
            let sizeString = bytesFormatter.string(fromByteCount: Int64(bytesTotal))
            let speedString = bytesFormatter.string(fromByteCount: Int64(bytesPerSec)) + "/s"
            let blockSize = selectiveRepeat.blockSize
            let blocksTotal = bytesTotal / blockSize + (bytesTotal % blockSize != 0 ? 1 : 0)
            let percentLoss = Double(retransmitCount) / Double(blocksTotal + retransmitCount) * 100
            LogInfo("ARQ tx transfer \(token) \(sizeString) at \(speedString), \(percentLoss)% loss")
        }
    }

    struct ReceiveState {
        let token: CoAPToken
        let outboundMessage: CoAPMessage?
        let originalMessage: CoAPMessage
        var selectiveRepeat: SRRxState
        let start = Date()

        func logCompleted() {
            let timeInterval = Date().timeIntervalSince(start)
            let bytesTotal = selectiveRepeat.data?.count ?? 0
            let bytesPerSec = Int(Double(bytesTotal) / timeInterval)
            let sizeString = bytesFormatter.string(fromByteCount: Int64(bytesTotal))
            let speedString = bytesFormatter.string(fromByteCount: Int64(bytesPerSec)) + "/s"
            LogInfo("ARQ rx transfer \(token) \(sizeString) at \(speedString)")
        }
    }

}
