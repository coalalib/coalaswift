//
//  CoAPDiscoveryResource.swift
//  Coala
//
//  Created by Roman on 14/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

class CoAPDiscoveryResource: CoAPResource {

    override func response(forRequest message: CoAPMessage, fromAddress: Address) -> CoAPMessage {
        var response = super.response(forRequest: message, fromAddress: fromAddress)
        response.setOption(.contentFormat, value: 40)
        return response
    }

}
