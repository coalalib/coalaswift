//
//  ResourceDiscovery.swift
//  Coala
//
//  Created by Roman on 20/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

extension CoAPMessage {
    var isMulticast: Bool {
        return address?.host == ResourceDiscovery.multicastAddress
    }
}

public class ResourceDiscovery {

    private let timeout: TimeInterval = 0.5
    private weak var coala: Coala?

    static let multicastAddress = "224.0.0.187"
    static let path = "info"
    private let discoveryQueue = DispatchQueue(label: "com.ndmsystems.discoveryQueue", qos: .utility)

    func startService(coala: Coala) {
        let resource = CoAPDiscoveryResource(method: .get,
                                             path: ResourceDiscovery.path) { [weak self] _ in
            let resources = self?.coala?.resources.map({"<\($0.path)>"}).joined(separator: ",")
            return (.content, resources)
        }
        coala.addResource(resource)
        self.coala = coala
    }

    public struct DiscoveredPeer {
        public let address: Address
        public let supportedMethods: [String]
    }

    public func run(path: String, timeout: TimeInterval, completion: @escaping ([Address: CoAPMessage]) -> Void) {
        let address = ResourceDiscovery.multicastAddress
        let url = URL(string: "coap://\(address):\(Coala.defaultPort)")?.appendingPathComponent(path)
        var message = CoAPMessage(type: .nonConfirmable, method: .get, url: url)
        var responses = [Address: CoAPMessage]()
        message.onResponse = { result in
            switch result {
            case let .message(message, from): responses[from] = message
            case .error: break
            }
        }
        _ = try? coala?.send(message)
        discoveryQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let myIp = self?.coala?.getWiFiAddress() {
                let filteredResponses = responses.filter { $0.key.host != myIp }
                completion(filteredResponses)
            } else {
                completion(responses)
            }
        }
    }

    public func run(completion: @escaping ([DiscoveredPeer]) -> Void) {
        run(timeout: timeout, port: Coala.defaultPort, completion: completion)
    }

    private func run(timeout: TimeInterval,
                     path: String = ResourceDiscovery.path,
                     port: UInt16,
                     completion: @escaping ([DiscoveredPeer]) -> Void) {
        let address = ResourceDiscovery.multicastAddress
        var url = URL(string: "coap://\(address):\(port)")
        url?.appendPathComponent(path)
        var message = CoAPMessage(type: .nonConfirmable, method: .get, url: url)
        var discoveredPeers =  [Address: DiscoveredPeer]()
        message.onResponse = { result in
            switch result {
            case .message(let message, let from):
                var methods = [String]()
                methods.append(message.payload?.string ?? "")
                let peer = DiscoveredPeer(address: from, supportedMethods: methods)
                discoveredPeers[peer.address] = peer
            case .error:
                break
            }
        }
        _ = try? coala?.send(message)
        discoveryQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let myIp = self?.coala?.getWiFiAddress() {
                let filteredPeers = Array(discoveredPeers.values).filter { $0.address.host != myIp }
                completion(filteredPeers)
            } else {
                completion(Array(discoveredPeers.values))
            }
        }
    }

}
