//
//  CoAPMockResource.swift
//  Coala
//
//  Created by Roman on 14/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Coala

struct CoAPMockResource: CoAPResourceProtocol {

    typealias Handler = (CoAPMessage) -> (CoAPMessage)

    let method: CoAPMessage.Method
    let path: String
    let handler: Handler

    init(method: CoAPMessage.Method, path: String, handler: @escaping Handler) {
        self.method = method
        self.path = path
        self.handler = handler
    }

    func response(forRequest message: CoAPMessage, fromAddress: Address) -> CoAPMessage {
        var responseMessage = handler(message)
        var urlComponents = URLComponents()
        if let existingUrl = responseMessage.url,
            let comps = URLComponents(url: existingUrl, resolvingAgainstBaseURL: true) {
            urlComponents = comps
        }
        urlComponents.host = fromAddress.host
        urlComponents.port = Int(fromAddress.port)
        responseMessage.url = urlComponents.url
        return responseMessage
    }
}
