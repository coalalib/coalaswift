//
//  CoAPObservableResource.swift
//  Coala
//
//  Created by Roman on 11/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

struct CoAPObserver: Hashable {
    let address: Address
    let registerMessage: CoAPMessage
    var hashValue: Int {
        return address.hashValue
    }
}

func == (lhs: CoAPObserver, rhs: CoAPObserver) -> Bool {
    return lhs.address == rhs.address
}

/// Observable CoAP resource, conforming to [CoAP Observer](https://tools.ietf.org/html/rfc7641)
public class ObservableResource: CoAPResource {

    private var observers = Set<CoAPObserver>()
    private(set) var sequenceNumber = 0

    /// Number of active observers, subscribed to the resource
    public var observersCount: Int {
        return observers.count
    }

    /**
     Initializes a new CoAP resource.

     - parameter path: Path to a resource (e.g. `some/resource/path`)
     - parameter handler: Handler to be called when resource is updated.

     - returns: A CoAP resource you should need to add to a `Coala` instance.
     */
    public init(path: String, handler: @escaping (Input) -> (Output)) {
        super.init(method: .get, path: path, handler: handler)
    }

    func add(observer: CoAPObserver) {
        observers.insert(observer)
    }

    func remove(observer: CoAPObserver) {
        observers.remove(observer)
    }

    /// Call this method every time you want to notify observers about resource's state change.
    public func notifyObservers() {
        sequenceNumber += 1
        let notification = self.handler((query: [], payload: nil))
        for observer in observers {
            send(notification: notification, to: observer)
        }
    }

    func send(notification: CoAPResource.Output, to observer: CoAPObserver) {
        var notificationMessage = CoAPMessage(type: .confirmable,
                                              code: .response(notification.0))
        let registerMessage = observer.registerMessage
        notificationMessage.url = observer.address.urlForScheme(scheme: registerMessage.scheme)
        notificationMessage.payload = notification.1
        notificationMessage.token = registerMessage.token
        notificationMessage.setOption(.observe, value: sequenceNumber)
        try? coala?.send(notificationMessage)
    }

}
