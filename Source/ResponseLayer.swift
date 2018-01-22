//
//  ResponseLayer.swift
//  Coala
//
//  Created by Roman on 13/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

struct ResponseLayer: InLayer {

    enum ResponseLayerError: Error {
        case requestHasBeenReset
    }

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        guard message.isResponse else { return }
        guard let sourceMessage = coala.messagePool.getSourceMessageFor(message: message) else {
            guard message.getIntegerOptions(.observe).count == 0 else { return }
            LogWarn("Warning! Pool didn't find outgoing request for message id\(message.messageId)")
            return
        }
        let handler = sourceMessage.onResponse
        let response: Coala.Response
        switch message.type {
        case .reset:
            response = .error(error: ResponseLayerError.requestHasBeenReset)
        default:
            response = .message(message: message, from: fromAddress)
        }
        DispatchQueue.main.async {
            guard coala.messagePool.get(messageId: sourceMessage.messageId) != nil else {
                LogVerbose("ResponseLayer: message \(sourceMessage.messageId) already deleted from pool")
                return
            }
            LogVerbose("ResponseLayer: calling handler")
            handler?(response)
            if !sourceMessage.isMulticast {
                coala.messagePool.remove(message: sourceMessage)
            }
        }
    }
}
