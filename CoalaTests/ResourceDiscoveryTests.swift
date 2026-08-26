import XCTest
@testable import Coala

final class ResourceDiscoveryTests: XCTestCase {

    /// A non-routable TEST-NET-1 address (RFC 5737): the TCP connect never
    /// completes, so the socket stays pending instead of spinning through
    /// connection-refused reconnects for the lifetime of the test.
    private func makeTcpCoala() throws -> Coala {
        return try Coala(transport: .tcp(host: "192.0.2.1", port: 16666))
    }

    /// Multicast discovery is deliberately skipped on TCP, but `run` must still
    /// call its completion. `GUMServiceDiscovery` clears `isDiscovering` only
    /// from that callback, so returning silently latches discovery off for the
    /// rest of the session and stale LAN peers are never flushed.
    func testRunOnTcpTransportStillCallsCompletion() throws {
        let coala = try makeTcpCoala()

        var received: [Address: CoAPMessage]?
        coala.resourceDiscovery.run(path: "info", timeout: 0.5) { received = $0 }

        XCTAssertNotNil(received, "completion must fire even though discovery is skipped on TCP")
        XCTAssertEqual(received?.count, 0)
    }

    /// Registering the discovery resource is object setup, not socket setup.
    /// Doing it from `setupSocket` re-appends it on every transport switch —
    /// `addResource` does not de-duplicate — so the fallback leaves the peer
    /// answering `/info` once per switch it has ever made.
    func testTransportSwitchDoesNotDuplicateTheDiscoveryResource() throws {
        let coala = try makeTcpCoala()
        let discoveryResources = {
            coala.resources.filter { $0.path == ResourceDiscovery.path }.count
        }
        XCTAssertEqual(discoveryResources(), 1, "sanity: registered exactly once at init")

        try coala.set(transport: .tcp(host: "192.0.2.2", port: 16666), completion: { _ in })

        XCTAssertEqual(discoveryResources(), 1, "transport switch must not re-register it")
    }
}
