//
//  ARQLayer.swift
//  Coala
//
//  Created by Roman on 02/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

enum ARQLayerError: Error {
    case negativeBlockNumber
    case splittingToBlocks
    case arqTransferIncomplete
    case payloadExpected
    case nonMessage
    case tokenMissing
    case blockAckHandlingFailed
    case unexpectedAck
}

final class ARQLayer {

    weak var coala: Coala?

    var rxStates = Synchronized<[CoAPToken: ReceiveState]>(value: [:])
    var txStates = Synchronized<[CoAPToken: TransmitState]>(value: [:])

    let blockSize = CoAPBlockOption.BlockSize.size1024
    var defaultSendWindowSize = 70

    var block2DownloadProgresses: [String: ((Data) -> Void)?] = [:]
  
    func send(block: SRTxBlock, originalMessage: CoAPMessage, token: CoAPToken, windowSize: Int) throws {
        guard block.number >= 0 else {
            throw ARQLayerError.negativeBlockNumber
        }
        var blockMessage = CoAPMessage(type: originalMessage.type, code: originalMessage.code)
        blockMessage.options = originalMessage.options
        let blockOption = CoAPBlockOption(num: UInt(block.number), mFlag: block.isMoreComing, szx: blockSize)
        blockMessage.setOption(originalMessage.isRequest ? .block1 : .block2, value: blockOption.value)
        blockMessage.setOption(.selectiveRepeatWindowSize, value: windowSize)
        blockMessage.token = token
        blockMessage.payload = block.data
        blockMessage.address = originalMessage.address
        blockMessage.proxyViaAddress = originalMessage.proxyViaAddress
        blockMessage.onResponse = { [weak self] response in
            switch response {
            case .message:
                // Block message should not be passed down the stack
                LogDebug("blockMessage \(blockMessage.messageId) was not deleted from pool")
                self?.fail(withError: ARQLayerError.blockAckHandlingFailed, forToken: token)
            case .error(let error):
                LogVerbose("Block #\(block.number) failed")
                self?.fail(withError: error, forToken: token)
            }
        }
        try coala?.send(blockMessage)
    }

    func sendMoreData(forToken: CoAPToken) throws {
        while let state = txStates.value[forToken],
            let block = state.selectiveRepeat.popBlock() {
                let windowSize = state.selectiveRepeat.windowSize
                try send(block: block,
                         originalMessage: state.originalMessage,
                         token: forToken,
                         windowSize: windowSize)
                self.txStates.value[forToken] = state
        }
    }

    func didTransmit(blockNumber: Int, forToken: CoAPToken, retransmits: Int) throws {
        guard let state = txStates.value[forToken] else { return }
        try state.selectiveRepeat.didTransmit(blockNumber: blockNumber)
        txStates.value[forToken]?.retransmitCount += retransmits
        try sendMoreData(forToken: forToken)
    }

    func fail(withError error: Error, forToken token: CoAPToken) {
        if let state = txStates.value[token] {
            state.originalMessage.onResponse?(.error(error: error))
        }
        self.rxStates.value.removeValue(forKey: token)
        self.txStates.value.removeValue(forKey: token)
    }
}

extension ARQLayer: InLayer {

    // swiftlint:disable:next function_body_length
    func process(incomingMessage: inout CoAPMessage,
                 block: CoAPBlockOption,
                 blockNumber: CoAPMessageOption.Number,
                 windowSize: Int,
                 ack: inout CoAPMessage?) throws {
        guard let token = incomingMessage.token else { throw ARQLayerError.tokenMissing }
        defer {
            incomingMessage.removeOption(blockNumber)
        }
        switch incomingMessage.type {
        case .acknowledgement, .reset:
            // Transmit ACK
            let timesSent = coala?.messagePool.timesSent(messageId: incomingMessage.messageId) ?? 0
            let retransmitCount = timesSent > 0 ? timesSent - 1 : 0
            try didTransmit(blockNumber: Int(block.num), forToken: token, retransmits: retransmitCount)
            coala?.messagePool.remove(messageWithId: incomingMessage.messageId)

            guard let state = txStates.value[token] else {
                throw ARQLayerError.unexpectedAck
            }

            if state.selectiveRepeat.isCompleted == true {
                txStates.value.removeValue(forKey: token)
                LogVerbose("ARQ: Transmit complete, pushing to message pool original tx message" +
                    " \(state.originalMessage.messageId)")
                state.logCompleted()
                coala?.messagePool.push(message: state.originalMessage)
                return
            }

        case .confirmable:
            // Receive CON
            guard let payload = incomingMessage.payload?.data else {
                throw ARQLayerError.payloadExpected
            }

            var rxState: ReceiveState!
            rxState = rxStates.value[token]
            if rxState == nil {
                LogVerbose("ARQLayer: creating SRRxState")
                let outboundMessage = coala?.messagePool.get(token: token)
                
                rxState = ReceiveState(
                    token: token,
                    outboundMessage: outboundMessage,
                    originalMessage: incomingMessage,
                    selectiveRepeat: .init()
                )
                self.rxStates.value[token] = rxState
            }

            try rxState.selectiveRepeat.didReceive(
                block: payload,
                number: Int(block.num),
                isFinalBlock: !block.mFlag
            )

            if let existingProgress = block2DownloadProgresses[token.description] {
                existingProgress?(rxState.selectiveRepeat.accumulator)
            }

            ack?.setOption(blockNumber, value: block.value)
            ack?.setOption(.selectiveRepeatWindowSize, value: windowSize)
            ack?.proxyViaAddress = incomingMessage.proxyViaAddress
            ack?.setOption(.proxySecurityId, value: incomingMessage.getOptions(.proxySecurityId).first)
          
            // when receive next block2 message, than we need to reset message pool metrics
            // for original message to prevent it expiration
            if let outboundMessage = rxStates.value[token]?.outboundMessage {
                coala?.messagePool.flushPoolMetrics(for: outboundMessage)
            }

            if let data = rxState.selectiveRepeat.data {
                LogVerbose("ARQ: Receive complete, passing message \(incomingMessage.messageId) along")
                rxState.logCompleted()
                if let outboundMessage = rxState.outboundMessage {
                    LogVerbose("ARQ: pushing outboundMessage \(outboundMessage.messageId) to stack")
                    coala?.messagePool.push(message: outboundMessage)
                }
                incomingMessage.payload = data
                incomingMessage.options = rxState.originalMessage.options
                self.rxStates.value.removeValue(forKey: token)
                self.block2DownloadProgresses[token.description] = nil
                return
            } else {
                ack?.code = .response(.continued)
            }
        case .nonConfirmable:
            throw ARQLayerError.nonMessage
        }
        throw ARQLayerError.arqTransferIncomplete
    }

    func run(coala: Coala, message: inout CoAPMessage, fromAddress: inout Address, ack: inout CoAPMessage?) throws {
        self.coala = coala // layer is always owned by one coala instance, tbd: do not pass coala as a parameter

        guard message.block1Option != nil || message.block2Option != nil,
            let windowSizeData = message.getOptions(.selectiveRepeatWindowSize).first?.data
            else { return }

        let windowSize = Int(data: windowSizeData)
        let blockOptions: [CoAPMessageOption.Number] = [.block1, .block2]
        try blockOptions.forEach {
            if let block = message.getOptions($0).first?.blockOption() {
                try process(incomingMessage: &message,
                            block: block,
                            blockNumber: $0,
                            windowSize: windowSize,
                            ack: &ack)
            }
        }
    }
}

extension ARQLayer: OutLayer {

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        self.coala = coala // layer is always owned by one coala instance, tbd: do not pass coala as a parameter
        guard let token = message.token,
            let payload = message.payload,
            payload.data.count > blockSize.value else {
                // Message payload is not large, ignore it
                return
        }
        // Payload is too large for one message, it needs to be split into blocks

        LogVerbose("ARQ: removing original message \(message.messageId) from pool")
        coala.messagePool.remove(message: message)
        var largeConMessage: CoAPMessage
        switch message.type {
        case .acknowledgement, .reset:
            // ARQ cannot send piggybacked response, every block message needs to be CON
            // Performing separate response sequence:
            // 1. Send empty ACK
            // 2. Send result itself
            var emptyAck = CoAPMessage(ackTo: message, from: toAddress, code: .empty)
            emptyAck.proxyViaAddress = message.proxyViaAddress
            emptyAck.block1Option = message.block1Option
            let windowOption = message.getOptions(.selectiveRepeatWindowSize).first
            emptyAck.setOption(.selectiveRepeatWindowSize, value: windowOption)
            try coala.send(emptyAck)
        // swiftlint:disable:next fallthrough
        fallthrough
        case .nonConfirmable:
            largeConMessage = CoAPMessage(type: .confirmable, code: message.code)
            largeConMessage.options = message.options
            largeConMessage.removeOption(.block1)       // block1 option already passed in empty ACK
            largeConMessage.payload = message.payload
            largeConMessage.address = message.address
            largeConMessage.proxyViaAddress = message.proxyViaAddress
        case .confirmable:
            largeConMessage = message
        }
        LogVerbose("ARQLayer: creating SRTxState")
        let srState = SRTxState(data: payload.data, windowSize: defaultSendWindowSize, blockSize: Int(blockSize.value))
        txStates.value[token] = TransmitState(token: token,
                                        originalMessage: largeConMessage,
                                        selectiveRepeat: srState)
        try sendMoreData(forToken: token)

        LogVerbose("ARQ: splitting message \(message.messageId) to blocks")
        throw ARQLayerError.splittingToBlocks
    }
}
