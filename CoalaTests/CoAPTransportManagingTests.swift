import XCTest
import Coala   // deliberately NOT @testable: this suite proves PUBLIC access,
               // which is exactly what the out-of-module RustCoala facade gets.

/// Phase 6 seam contract (spec §4.3): Coala satisfies the new management
/// protocol via existing members, and the boundary value types the facade
/// must synthesize are publicly constructible.
final class CoAPTransportManagingTests: XCTestCase {

    func testCoalaConformsToCoAPTransportManaging() throws {
        let coala = try Coala(transport: .udp(port: 0))
        XCTAssertNotNil(coala as CoAPTransportManaging)
        coala.stop()
    }

    func testDeliveryStatisticsArePubliclyConstructible() {
        // Same construction the RustCoala facade performs from FFI counters.
        let stats = DeliveryStatistics(
            scheme: .coap,
            address: Address(host: "1.2.3.4", port: 5683),
            direct: .init(totalCount: 3, retransmitsCount: 1),
            proxy: .init(totalCount: 0, retransmitsCount: 0)
        )
        XCTAssertEqual(stats.direct.totalCount, 3)
        XCTAssertEqual(stats.direct.retransmitsCount, 1)
    }

    func testDoesMatchIsPublicAndTrims() {
        let resource = CoAPResource(method: .get, path: "/info") { _ in (.content, nil) }
        XCTAssertTrue(resource.doesMatch(path: "info"))          // slash-trim parity
        XCTAssertTrue(resource.doesMatch(.get, path: "info/"))
        XCTAssertFalse(resource.doesMatch(.post, path: "info"))
    }

    func testObserveMethodsAreProtocolRequirements() throws {
        // Dynamic dispatch through the protocol existential must resolve
        // (compile-time proof; behavior is covered by ObservedResourcesRegistryTests).
        let coala: CoAPClient = try Coala(transport: .udp(port: 0))
        coala.stopObserving(url: URL(string: "coap://127.0.0.1:1/none")!, onStop: nil)
        (coala as? Coala)?.stop()
    }
}
