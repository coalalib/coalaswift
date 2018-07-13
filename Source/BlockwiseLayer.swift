//
//  BlockwiseLayer.swift
//  Coala
//
//  Created by Roman on 13/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

class BlockwiseLayer: InLayer, OutLayer {

    private struct State {
        var accumulator = Data()
        var outgoingMessage: CoAPMessage?
        var options: [CoAPMessageOption] = []
        var expectedNextNum: UInt = 0
    }

    private var stateForToken: [CoAPToken: State] = [:]

    private func setState(_ state: State?, forToken token: CoAPToken?) {
        guard let token = token else { return }
        stateForToken[token] = state
    }

    private func getState(forToken token: CoAPToken?) -> State? {
        guard let token = token else { return nil }
        return stateForToken[token]
    }

    func clearState(forToken token: CoAPToken?) {
        guard let token = token else { return }
        stateForToken[token] = nil
    }

    // MARK: Message processing

    enum BlockwiseError: Error {
        case unexpectedEmptyPayload, blockTransferIncomplete, unexpectedMessage, outOfOrder
    }

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        if let block1 = message.block1Option {
            try processBlock1(option: block1, coala: coala, message: &message, address: fromAddress, ack: &ack)
        }
        if let block2 = message.block2Option {
            try processBlock2(option: block2, coala: coala, message: &message, address: fromAddress, ack: &ack)
        }
    }

    private func getDataFromMessageSegment(_ message: inout CoAPMessage,
                                           blockOption: CoAPBlockOption,
                                           stop: inout Bool) throws {
        var state: State
        if blockOption.num == 0 {
            state = State()
            state.options = message.options.filter({ !$0.isBlock })
        } else if let stateForMessage = getState(forToken: message.token) {
            state = stateForMessage
        } else {
            throw BlockwiseError.unexpectedMessage
        }
        guard let payload = message.payload else { throw BlockwiseError.unexpectedEmptyPayload }
        guard state.expectedNextNum == blockOption.num else { throw BlockwiseError.outOfOrder }
        state.accumulator += payload.data
        state.expectedNextNum = blockOption.num + 1
        guard blockOption.mFlag else {
            // transfer finished
            let blockOptions = message.options.filter({ $0.isBlock })
            message.payload = state.accumulator
            message.options = state.options
            message.options.append(contentsOf: blockOptions)
            stop = true
            clearState(forToken: message.token)
            return
        }
        setState(state, forToken: message.token)
    }

    private func processBlock1(option: CoAPBlockOption,
                               coala: Coala,
                               message: inout CoAPMessage,
                               address: Address,
                               ack: inout CoAPMessage?) throws {
        switch message.code {
        case .request:
            // Descriptive usage
            ack?.setOption(.block1, value: option.value)
            var stop = false
            try getDataFromMessageSegment(&message, blockOption: option, stop: &stop)
            if stop {
                return
            }
            ack?.code = .response(.continued)

            // Do not pass message further down the stack
            throw BlockwiseError.blockTransferIncomplete
        case .response:
            // Control usage
            // Server confirmed receiving the block
            // or requested another size
            guard option.mFlag else {
                // transfer finished
                return
            }
            try proceedToNextBlock(block1: option,
                                   block2: nil,
                                   coala: coala,
                                   message: message,
                                   address: address)

            // Do not pass message further down the stack
            throw BlockwiseError.blockTransferIncomplete
        }
    }

    private func processBlock2(option: CoAPBlockOption,
                               coala: Coala,
                               message: inout CoAPMessage,
                               address: Address,
                               ack: inout CoAPMessage?) throws {
        switch message.code {
        case .request:
            // Control usage
            // To influence the block size used in a response, the requester MAY
            // use the Block2 Option on the initial request
            guard option.num > 0
                else {
                    // Any further block-wise
                    // requests for blocks beyond the first one MUST indicate the same block
                    // size that was used by the server in the response for the first
                    // request that gave a desired size using a Block2 Option.
                    // Ignore it.
                    return
            }
            // client requested specific block size
            // Server must use it for further responses (or smaller one)

            // Send next part here
            let state = getState(forToken: message.token)
            guard let lastSentBlockMessage = state?.outgoingMessage else {
                    LogWarn("Unexpected block message - no outgoing message in stack")
                    throw BlockwiseError.unexpectedMessage
            }

            var nextBlockMessage = CoAPMessage(type: lastSentBlockMessage.type,
                                               code: lastSentBlockMessage.code,
                                               messageId: message.messageId)
            nextBlockMessage.payload = lastSentBlockMessage.payload
            nextBlockMessage.options = lastSentBlockMessage.options
            nextBlockMessage.block1Option = nil
            nextBlockMessage.token = lastSentBlockMessage.token
            BlockwiseLayer.trimOutgoingMessage(&nextBlockMessage, blockOption: option, coala: coala)
            try coala.send(nextBlockMessage)

            // Do not pass message further down the stack
            throw BlockwiseError.blockTransferIncomplete
        case .response:
            // Descriptive usage
            var stop = false
            try getDataFromMessageSegment(&message, blockOption: option, stop: &stop)
            if stop {
                return
            }
            try proceedToNextBlock(block1: nil,
                                   block2: option,
                                   coala: coala,
                                   message: message,
                                   address: address)

            // Do not pass message further down the stack
            throw BlockwiseError.blockTransferIncomplete
        }
    }

    private func proceedToNextBlock(block1: CoAPBlockOption?,
                                    block2: CoAPBlockOption?,
                                    coala: Coala,
                                    message: CoAPMessage,
                                    address: Address) throws {
        let pool = coala.messagePool
        let previousMessage: CoAPMessage
        if let poolMessage = pool.getSourceMessageFor(message: message) {
            previousMessage = poolMessage
        } else {
            if block2?.num == 0 {
                var fakeGetMessage = CoAPMessage(type: .confirmable,
                                                 code: .request(.get),
                                                 messageId: message.messageId)
                fakeGetMessage.token = message.token
                pool.push(message: fakeGetMessage)
                previousMessage = fakeGetMessage
            } else {
                throw BlockwiseError.unexpectedMessage
            }
        }
        let prevState = getState(forToken: message.token)
        pool.remove(message: previousMessage)
        setState(prevState, forToken: message.token)
        var moreMessage = CoAPMessage(type: previousMessage.type, code: previousMessage.code)
        moreMessage.options = previousMessage.options
        moreMessage.token = previousMessage.token
        moreMessage.onResponse = previousMessage.onResponse
        moreMessage.payload = previousMessage.payload
        moreMessage.url = moreMessage.url ?? address.urlForScheme(scheme: message.scheme)
        moreMessage.proxyViaAddress = previousMessage.proxyViaAddress
        if let block1 = block1 {
            let moreOption = CoAPBlockOption(num: block1.num + 1, mFlag: false, szx: block1.szx)
            moreMessage.block1Option = moreOption
        }
        if let block2 = block2 {
            let moreOption = CoAPBlockOption(num: block2.num + 1, mFlag: false, szx: block2.szx)
            moreMessage.block2Option = moreOption
        }
        // https://tools.ietf.org/html/draft-ietf-core-block-21#section-3.3
        // no payload for requests with Block2 with NUM != 0
        // Block1 transfer finished, proceeding to block2. Payload is not relevant anymore
        if let block2 = moreMessage.block2Option, block2.num > 0 {
            moreMessage.payload = nil
            moreMessage.block1Option = nil
        }
        try coala.send(moreMessage)
    }

    static func passBlock1Option(_ message: inout CoAPMessage, fromMessage: CoAPMessage) {
        if fromMessage.isRequest && fromMessage.block2Option == nil {
            message.block1Option = fromMessage.block1Option
        }
    }

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        let blockOption = message.isRequest ? message.block1Option : message.block2Option
        BlockwiseLayer.trimOutgoingMessage(&message,
                                           blockOption: blockOption,
                                           coala: coala)
    }

    static let blockSize = CoAPBlockOption.BlockSize.size1024
    static func trimOutgoingMessage(_ message: inout CoAPMessage,
                                    blockOption requestedOption: CoAPBlockOption?,
                                    coala: Coala) {

        guard let payload = message.payload, payload.data.count > blockSize.value
            else { return }

        var rangeStart = 0
        if let requestedOption = requestedOption {
            rangeStart = Int(requestedOption.num) * blockSize.value
        }
        let rangeEnd = min(rangeStart + blockSize.value, payload.data.count)
        let moreDataLeft = rangeEnd < payload.data.count

        let layers = coala.layerStack.inLayers
        if let layer = layers.first(where: { $0 is BlockwiseLayer }) as? BlockwiseLayer {
            var state = layer.getState(forToken: message.token) ?? State()
            state.outgoingMessage = moreDataLeft ? message : nil
            layer.setState(state, forToken: message.token)
        }

        message.payload = payload.data.subdata(in: rangeStart..<rangeEnd)
        let blockOption = CoAPBlockOption(num: requestedOption?.num ?? 0,
                                          mFlag: moreDataLeft,
                                          szx: blockSize)

        if message.isRequest {
            message.block1Option = blockOption
        } else {
            message.block2Option = blockOption
        }
    }

}

fileprivate extension CoAPMessageOption {
    var isBlock: Bool {
        return number == .block1 || number == .block2
    }
}
