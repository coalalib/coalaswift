import XCTest
@testable import Coala

/// End-to-end ARQ block transfers between two real Coala instances over UDP
/// loopback: block2 download (server → client, separate-response split of a
/// large piggybacked ACK) and block1 upload (client → server). Exercises
/// SRTx/SRRx, SlidingWindow, the message pool TokenIndex under many
/// same-token pushes, and the progress callback path.
final class ARQIntegrationTests: XCTestCase {

    private var server: Coala!
    private var client: Coala!
    private var serverPort: UInt16 = 0

    private func makeCoala(ports: Range<UInt16>) -> (Coala, UInt16)? {
        for port in ports {
            if let coala = try? Coala(transport: .udp(port: port)) {
                return (coala, port)
            }
        }
        return nil
    }

    override func setUpWithError() throws {
        let (server, serverPort) = try XCTUnwrap(makeCoala(ports: 15683..<15703))
        let (client, _) = try XCTUnwrap(makeCoala(ports: 15703..<15723))
        self.server = server
        self.serverPort = serverPort
        self.client = client
        // Keep pool resends out of the transfer window so the test is deterministic.
        client.configureMessagePool(expirationTimeout: 5, totalResendCount: 6)
        server.configureMessagePool(expirationTimeout: 5, totalResendCount: 6)
    }

    override func tearDown() {
        client?.stop()
        server?.stop()
        client = nil
        server = nil
        super.tearDown()
    }

    func testBlock2DownloadReassemblesLargePayloadAndReportsProgress() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 251) })
        server.addResource(CoAPResource(method: .get, path: "large") { _ in
            (.content, payload)
        })

        var request = CoAPMessage(type: .confirmable,
                                  method: .get,
                                  url: URL(string: "coap://127.0.0.1:\(serverPort)/large"))
        let received = expectation(description: "download completes")
        let progress = Synchronized<[Int]>(value: [])
        request.onResponse = { response in
            guard case .message(let message, _) = response else {
                XCTFail("Expected message, got error response")
                return
            }
            XCTAssertEqual(message.payload?.data, payload)
            received.fulfill()
        }
        try client.send(request, block2DownloadProgress: { partial in
            progress.mutate { $0.append(partial.count) }
        })

        wait(for: [received], timeout: 10)
        // Progress reports the contiguous prefix: non-decreasing, bounded by the payload.
        let counts = progress.value
        XCTAssertFalse(counts.isEmpty)
        XCTAssertEqual(counts, counts.sorted())
        XCTAssertLessThanOrEqual(counts.last ?? 0, payload.count)
    }

    func testBlock1UploadDeliversFullPayloadToResource() throws {
        let payload = Data((0..<6_000).map { UInt8($0 % 253) })
        let receivedOnServer = Synchronized<Data?>(value: nil)
        server.addResource(CoAPResource(method: .post, path: "upload") { input in
            receivedOnServer.mutate { $0 = input.payload?.data }
            return (.changed, "ok")
        })

        var request = CoAPMessage(type: .confirmable,
                                  method: .post,
                                  url: URL(string: "coap://127.0.0.1:\(serverPort)/upload"))
        request.payload = payload
        let responded = expectation(description: "upload acknowledged")
        request.onResponse = { response in
            guard case .message = response else {
                XCTFail("Expected message, got error response")
                return
            }
            responded.fulfill()
        }
        try client.send(request)

        wait(for: [responded], timeout: 10)
        XCTAssertEqual(receivedOnServer.value, payload)
    }
}
