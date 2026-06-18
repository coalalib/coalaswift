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

    func hash(into hasher: inout Hasher) {
        hasher.combine(address)
    }
}

func == (lhs: CoAPObserver, rhs: CoAPObserver) -> Bool {
    return lhs.address == rhs.address
}

/// Observable CoAP resource, conforming to [CoAP Observer](https://tools.ietf.org/html/rfc7641)
public class ObservableResource: CoAPResource {

    // Bug 5 fix: protect observers and sequenceNumber with a serial queue so that
    // add/remove (delegate queue) and notifyObservers (any thread) don't race.
    private let observersQueue = DispatchQueue(label: "com.ndmsystems.coala.observableResource",
                                               qos: .default)
    private var _observers = Set<CoAPObserver>()
    private var _sequenceNumber = 0

    /// Number of active observers, subscribed to the resource
    public var observersCount: Int {
        return observersQueue.sync { _observers.count }
    }

    // Expose sequenceNumber as a thread-safe computed property to preserve the
    // existing API used by ObserveLayer (observableResource.sequenceNumber).
    var sequenceNumber: Int {
        return observersQueue.sync { _sequenceNumber }
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
        observersQueue.sync { _observers.insert(observer) }
    }

    func remove(observer: CoAPObserver) {
        observersQueue.sync { _observers.remove(observer) }
    }

    /// Call this method every time you want to notify observers about resource's state change.
    public func notifyObservers() {
        // Increment sequenceNumber and capture a snapshot of observers atomically,
        // then iterate the snapshot outside the lock to avoid deadlock.
        let (snapshot, currentSeq): (Set<CoAPObserver>, Int) = observersQueue.sync {
            _sequenceNumber += 1
            return (_observers, _sequenceNumber)
        }
        let notification = self.handler((query: [], payload: nil))
        for observer in snapshot {
            send(notification: notification, to: observer, sequenceNumber: currentSeq)
        }
    }

    func send(notification: CoAPResource.Output, to observer: CoAPObserver, sequenceNumber: Int) {
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
