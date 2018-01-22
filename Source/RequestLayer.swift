//
//  RequestLayer.swift
//  Coala
//
//  Created by Roman on 13/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

struct RequestLayer: InLayer {

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        guard message.type == .confirmable || message.type == .nonConfirmable,
            let path = message.url?.path,
            let method = message.requestMethod
            else { return }

        let resourcesAtPath = coala.resources.filter({ $0.doesMatch(path: path) })
        let resourcesAtPathWithMethod = resourcesAtPath.filter({ $0.doesMatch(method, path: path) })

        guard resourcesAtPathWithMethod.count > 0 else {
            let isMethodWrong = resourcesAtPath.count > 0
            let errorCode: CoAPMessage.ResponseCode = isMethodWrong ? .methodNotAllowed : .notFound
            ack?.code = .response(errorCode)
            return
        }

        for resource in resourcesAtPathWithMethod {
            let resourceResponse = resource.response(forRequest: message, fromAddress: fromAddress)
            if ack != nil {
                ack!.code = resourceResponse.code
                ack!.payload = resourceResponse.payload
                for option in resourceResponse.options {
                    ack!.setOption(option.number, value: option.value)
                }
            } else {
                var separateReponse = CoAPMessage(type: .nonConfirmable, code: resourceResponse.code)
                separateReponse.payload = resourceResponse.payload
                separateReponse.options = resourceResponse.options
                separateReponse.scheme = message.scheme
                separateReponse.address = fromAddress
                try coala.send(separateReponse)
            }
        }
    }
}
