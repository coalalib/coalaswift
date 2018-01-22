//
//  LayerStack.swift
//  Coala
//
//  Created by Roman on 13/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

protocol InLayer {
    func run(coala: Coala, message: inout CoAPMessage, fromAddress: inout Address, ack: inout CoAPMessage?) throws
}

protocol OutLayer {
    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws
}

struct LayerStack {

    let securityLayer = SecurityLayer()
    let reliabilityLayer = ReliabilityLayer()
    let blockwiseLayer = BlockwiseLayer()
    let requestLayer = RequestLayer()
    let responseLayer = ResponseLayer()
    let observeLayer = ObserveLayer()
    let proxyLayer = ProxyLayer()
    let logLayer = LogLayer()
    let arqLayer = ARQLayer()

    let inLayers: [InLayer]
    let outLayers: [OutLayer]

    init() {
        self.inLayers = [
            proxyLayer,
            securityLayer,
            logLayer,
            reliabilityLayer,
            arqLayer,
            blockwiseLayer,
            observeLayer,
            requestLayer,
            responseLayer
        ]
        self.outLayers = [
            observeLayer,
            arqLayer,
            blockwiseLayer,
            logLayer,
            securityLayer,
            proxyLayer
        ]
    }

    func run(_ message: inout CoAPMessage, coala: Coala, toAddress: inout Address) throws {
        for layer in outLayers {
            try layer.run(coala: coala, message: &message, toAddress: &toAddress)
        }
    }

    func run(_ message: inout CoAPMessage, coala: Coala, fromAddress: inout Address) throws {
        var ack: CoAPMessage?
        var stackError: Error?
        do {
            for layer in inLayers {
                try layer.run(coala: coala, message: &message, fromAddress: &fromAddress, ack: &ack)
            }
        } catch let error { stackError = error }
        if let ackMessage = ack {
            try coala.send(ackMessage)
        }
        if let error = stackError {
            throw error
        }
    }
}
