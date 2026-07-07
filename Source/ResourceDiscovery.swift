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
    private let discoveryQueue = DispatchQueue(
        label: "com.ndmsystems.discoveryQueue",
        qos: .utility
    )

    func startService(coala: Coala) {
        let resource = CoAPDiscoveryResource(
          method: .get,
          path: ResourceDiscovery.path
        ) { [weak self] _ in
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

    public func run(
        path: String,
        timeout: TimeInterval,
        completion: @escaping ([Address: CoAPMessage]) -> Void
    ) {
        guard case .udp = coala?.transport else { return }

        let address = ResourceDiscovery.multicastAddress

        let url = URL(string: "coap://\(address):\(Coala.defaultPort)")?
          .appendingPathComponent(path)

        var message = CoAPMessage(type: .nonConfirmable, method: .get, url: url)

        let responses = Synchronized(value: [Address: CoAPMessage]())

        message.onResponse = { result in
            switch result {
            case let .message(message, from):
              responses.mutate { $0[from] = message }

            case .error:
              break
            }
        }

        _ = try? coala?.send(message)

        discoveryQueue.asyncAfter(
            deadline: .now() + timeout
        ) { [weak self] in
  
            if let myIp = self?.coala?.getWiFiAddress() {

                let filteredResponses = responses.value.filter { $0.key.host != myIp }
                completion(filteredResponses)

            } else {
              completion(responses.value)
            }
        }
    }

}
