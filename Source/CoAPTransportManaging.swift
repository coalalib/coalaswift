import Foundation

/// Management/introspection surface of a CoAP transport that NDMAPI's
/// GUMService needs beyond message passing (spec §4.3): restart, message-pool
/// configuration, delivery statistics and local resource discovery.
///
/// Deliberately separate from `CoAPTransport`: NDMAPITests' MockCoala must
/// keep failing the cast (as `as? Coala` fails today) so those paths stay
/// no-ops with zero mock changes.
public protocol CoAPTransportManaging: AnyObject {

    func restart()

    func configureMessagePool(expirationTimeout: TimeInterval, totalResendCount: Int)
    func configureMessagePoolTimeouts(for urlPaths: [UriPathConfig])

    func getStatistics(for address: Address, scheme: CoAPMessage.Scheme) -> DeliveryStatistics?
    func getStatistics(for message: CoAPMessage) -> DeliveryStatistics?
    func flushStatistics(for address: Address, scheme: CoAPMessage.Scheme)
    func flushAllStatistics()

    /// Mirrors `ResourceDiscovery.run(path:timeout:completion:)`
    /// (ResourceDiscovery.swift:46): NON multicast GET, responses keyed by
    /// responder address, completion once after `timeout`.
    func discoverResources(
        path: String,
        timeout: TimeInterval,
        completion: @escaping ([Address: CoAPMessage]) -> Void
    )
}

extension Coala: CoAPTransportManaging {

    public func discoverResources(
        path: String,
        timeout: TimeInterval,
        completion: @escaping ([Address: CoAPMessage]) -> Void
    ) {
        resourceDiscovery.run(path: path, timeout: timeout, completion: completion)
    }
}
