//
//  Coala+Observe.swift
//  Coala
//
//  Created by Roman on 14/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

extension CoAPClient {

    /// Start observing CoAP resource
    /// - parameter url: URL of observed resource
    /// - parameter onUpdate: Closure to called on every resource update
    public func startObserving(url: URL, onUpdate: @escaping Coala.ResponseHandler) {
        var registerMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        let hash = Data(url.absoluteString.data.sha256.prefix(CoAPToken.maxLength))
        registerMessage.token = CoAPToken(value: hash)
        registerMessage.setOption(.observe, value: 0)
        registerMessage.onResponse = onUpdate
        try? send(registerMessage)
    }

    /// Stop observing CoAP resource
    /// - parameter url: URL of observed resource
    public func stopObserving(url: URL, onStop: (() -> Void)? = nil) {
        var registerMessage = CoAPMessage(type: .confirmable, method: .get, url: url)
        let hash = Data(url.absoluteString.data.sha256.prefix(CoAPToken.maxLength))
        registerMessage.token = CoAPToken(value: hash)
        registerMessage.setOption(.observe, value: 1)
        registerMessage.onResponse = { _ in
            onStop?()
        }
        try? send(registerMessage)
    }

}
