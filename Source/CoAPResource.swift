//
//  CoAPResource.swift
//  Coala
//
//  Created by Roman on 06/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

/// CoAP resource
public class CoAPResource: CoAPResourceProtocol {

    /// Resource gets URL query and optional payload as input
    public typealias Input = (query: [URLQueryItem], payload: CoAPMessagePayload?)

    /// Resource must output a response code and optional payload
    public typealias Output = (CoAPMessage.ResponseCode, CoAPMessagePayload?)

    /// CoAP method, resource responds to (`.get`, `.post`, `.put` or `.delete`)
    public let method: CoAPMessage.Method

    /// Path to a resource (e.g. `some/resource/path`)
    public let path: String

    let handler: (Input) -> (Output)
    weak var coala: Coala?

    /**
     Initializes a new CoAP resource.

     - parameter method: CoAP method, resource responds to (`.get`, `.post`, `.put` or `.delete`)
     - parameter path: Path to a resource (e.g. `some/resource/path`)
     - parameter handler: Handler to be called when receiving a request to the resource

     - returns: A CoAP resource you should need to add to a `Coala` instance.
     */
    public init(method: CoAPMessage.Method, path: String, handler: @escaping (Input) -> (Output)) {
        self.method = method
        self.path = path
        self.handler = handler
    }

    /// Describes how response message is costructed. 
    /// `CoAPResource` class produces piggybacked response using `ACK` messages.
    public func response(forRequest message: CoAPMessage, fromAddress: Address) -> CoAPMessage {
        var query = [URLQueryItem]()
        if let url = message.url,
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            query = comps.queryItems ?? []
        }
        let response = handler((query: query, payload: message.payload))
        var responseMessage = CoAPMessage(ackTo: message,
                                          from: fromAddress,
                                          code: response.0)
        responseMessage.payload = response.1
        return responseMessage
    }

}
