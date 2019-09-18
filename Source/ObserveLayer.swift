//
//  ObserveLayer.swift
//  Coala
//
//  Created by Roman on 11/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

final class ObserveLayer: InLayer, OutLayer {

    enum ObserveAction: UInt {
        case register
        case deregister
    }

    var observedResourcesRegistry = ObservedResourcesRegistry()

    enum ObserveLayerError: Error {
        case resourceIsNotObserved
        case requestHandledWithNotification
    }

    func run(coala: Coala,
             message: inout CoAPMessage,
             fromAddress: inout Address,
             ack: inout CoAPMessage?) throws {
        switch message.code {
        case .request(let method):
            try processRequest(method: method,
                               coala: coala,
                               message: message,
                               fromAddress: fromAddress,
                               ack: &ack)
        case .response(.empty):
            break
        case .response(let code):
            try processResponse(code: code,
                                coala: coala,
                                message: message,
                                fromAddress: fromAddress,
                                ack: &ack)
        }
    }

    func processRequest(method: CoAPMessage.Method,
                        coala: Coala,
                        message: CoAPMessage,
                        fromAddress: Address,
                        ack: inout CoAPMessage?) throws {
        guard method == .get,
            let path = message.url?.path,
            let observeOption = message.getIntegerOptions(.observe).first,
            let observeAction = ObserveAction(rawValue: observeOption) else { return }
        for resource in coala.resources.filter({ $0.doesMatch(method, path: path) }) {
            if let observableResource = resource as? ObservableResource {
                let observer = CoAPObserver(address: fromAddress, registerMessage: message)
                switch observeAction {
                case .register:
                    observableResource.add(observer: observer)
                    let notification = observableResource.handler((query: [], payload: nil))
                    ack?.code = .response(notification.0)
                    ack?.payload = notification.1
                    ack?.setOption(.observe, value: observableResource.sequenceNumber)
                    throw ObserveLayerError.requestHandledWithNotification
                case .deregister:
                    observableResource.remove(observer: observer)
                }
            }
        }
    }

    func processResponse(code: CoAPMessage.ResponseCode,
                         coala: Coala,
                         message: CoAPMessage,
                         fromAddress: Address,
                         ack: inout CoAPMessage?) throws {
        guard let token = message.token else { return }
        let observeOption = message.getIntegerOptions(.observe).first
        if observedResourcesRegistry.resource(forToken: token) != nil {
            // Original register message should not receive response
            // Only way to ensure it here is to
            coala.messagePool.remove(message: message)
            let maxAge = message.getIntegerOptions(.maxAge).first
            let notification = ObserverNotification(message: message,
                                                    from: fromAddress,
                                                    sequenceNumber: observeOption,
                                                    maxAge: maxAge)
            observedResourcesRegistry.didReceive(notification: notification, forToken: token)
            if observeOption == nil || code.rawValue.major != 2 {
                observedResourcesRegistry.didStopObservingResource(forToken: token)
            }
            ack?.setOption(.observe, value: observeOption)
        } else if observeOption != nil {
            // We are not observing resource for this token
            // But server thinks we are, since it has sent us this notification
            var reset = CoAPMessage(type: .reset,
                                    code: .response(.notFound),
                                    messageId: message.messageId)
            reset.url = fromAddress.urlForScheme(scheme: message.scheme)
            reset.token = message.token
            ack = reset
            throw ObserveLayerError.resourceIsNotObserved
        }
    }

    func run(coala: Coala, message: inout CoAPMessage, toAddress: inout Address) throws {
        guard message.isRequest,
            let token = message.token,
            let observeOption = message.getIntegerOptions(.observe).first,
            let observeAction = ObserveAction(rawValue: observeOption),
            let url = message.url
            else { return }
        switch observeAction {
        case .register:
            guard let handler = message.onResponse else { return }
            let resource = ObservedResource(url: url, coala: coala, handler: handler)
            observedResourcesRegistry.didStartObserving(resource: resource, forToken: token)
        case .deregister:
            observedResourcesRegistry.didStopObservingResource(forToken: token)
        }
    }
}
