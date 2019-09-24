//
//  ReliabilityLayer.swift
//  Coala
//
//  Created by Roman on 13/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

struct ReliabilityLayer: InLayer {

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        switch message.type {
        case .confirmable:
            ack = CoAPMessage(ackTo: message, from: fromAddress, code: .empty)
        case .acknowledgement, .reset:
            guard message.code != .response(.empty), message.getOptions(.selectiveRepeatWindowSize).first != nil else {
                return
            }
            coala.messagePool.didTransmitMessage(messageId: message.messageId)
        case .nonConfirmable:
            break
        }
    }
}
