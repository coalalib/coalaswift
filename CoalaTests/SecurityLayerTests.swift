import XCTest
@testable import Coala

/// Core SecurityLayer paths: plain-coap pass-through, coaps without a session
/// (outbound queueing / inbound sessionNotFound reply) and incoming handshake
/// handling. Uses a real Coala on a loopback UDP port; replies that the layer
/// sends through `coala.send` are captured with a raw UDP socket and
/// deserialized. XCTest keeps these serial (Synchronized pool wedges under
/// parallel Swift Testing), and all pool reads are polled because the
/// `Synchronized` setter is an async barrier.
final class SecurityLayerTests: XCTestCase {

    private var coala: Coala!
    private var layer: SecurityLayer!

    private func makeCoala(ports: Range<UInt16>) -> Coala? {
        for port in ports {
            if let coala = try? Coala(transport: .udp(port: port)) {
                return coala
            }
        }
        return nil
    }

    override func setUpWithError() throws {
        coala = try XCTUnwrap(makeCoala(ports: 15763..<15783))
        layer = SecurityLayer()
    }

    override func tearDown() {
        coala?.stop()
        coala = nil
        layer = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func pendingMessages() -> [CoAPMessage] {
        return layer?.pendingMessages.value ?? []
    }

    /// Polls until `condition` is true or the timeout elapses.
    private func waitFor(_ description: String,
                         timeout: TimeInterval = 2,
                         condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), description)
    }

    // MARK: - Outbound

    func testOutboundPlainCoapMessageIsLeftUntouched() throws {
        var message = CoAPMessage(type: .confirmable,
                                  method: .get,
                                  url: URL(string: "coap://127.0.0.1:9/x"))
        message.payload = Data([0x01, 0x02, 0x03])
        let before = try CoAPSerializer.dataWithCoAPMessage(message)
        var toAddress = Address(host: "127.0.0.1", port: 9)

        try layer.run(coala: coala, message: &message, toAddress: &toAddress)

        let after = try CoAPSerializer.dataWithCoAPMessage(message)
        XCTAssertEqual(after, before, "plain coap:// message must pass through unmodified")
        XCTAssertEqual(pendingMessages().count, 0)
    }

    func testOutboundCoapsWithoutSessionThrowsAndQueuesMessage() {
        var message = CoAPMessage(type: .confirmable,
                                  method: .get,
                                  url: URL(string: "coaps://127.0.0.1:9/x"))
        let messageId = message.messageId
        var toAddress = Address(host: "127.0.0.1", port: 9)

        XCTAssertThrowsError(try layer.run(coala: coala,
                                           message: &message,
                                           toAddress: &toAddress)) { error in
            XCTAssertEqual(error as? SecurityLayer.SecurityLayerError, .handshakeInProgress)
        }

        waitFor("message must be queued until the handshake completes") {
            self.pendingMessages().count == 1
        }
        XCTAssertEqual(pendingMessages().first?.messageId, messageId)
    }

    // MARK: - Inbound

    func testInboundCoapsWithoutSessionRepliesSessionNotFoundAndThrows() throws {
        let receiver = try XCTUnwrap(UDPReceiver())
        var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: 42)
        message.scheme = .coapSecure
        var fromAddress = Address(host: "127.0.0.1", port: receiver.port)
        var ack: CoAPMessage?

        XCTAssertThrowsError(try layer.run(coala: coala,
                                           message: &message,
                                           fromAddress: &fromAddress,
                                           ack: &ack)) { error in
            XCTAssertEqual(error as? SecurityLayer.SecurityLayerError, .sessionNotEstablished)
        }

        let datagram = try XCTUnwrap(receiver.receive(timeout: 2),
                                     "peer must be told that the session was not found")
        let reply = try CoAPSerializer.coapMessageWithData(datagram)
        XCTAssertEqual(reply.getIntegerOptions(.sessionNotFound).first, 1)
        XCTAssertEqual(reply.type, .acknowledgement)
        XCTAssertEqual(reply.messageId, 42)
        XCTAssertEqual(reply.responseCode, .unauthorized)
    }

    // MARK: - Incoming handshake

    func testIncomingHandshakeGetRespondsWithOwnPublicKeyAndThrows() throws {
        let receiver = try XCTUnwrap(UDPReceiver())
        var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: 7)
        message.setOption(.handshakeType, value: 1)
        message.payload = Data.randomData(length: 32) // peer's Curve25519 public key
        let fromAddress = Address(host: "127.0.0.1", port: receiver.port)

        XCTAssertThrowsError(try layer.handleIncomingHandshake(coala: coala,
                                                               message: message,
                                                               fromAddress: fromAddress)) { error in
            XCTAssertEqual(error as? SecurityLayer.SecurityLayerError, .handshakeInProgress)
        }

        let datagram = try XCTUnwrap(receiver.receive(timeout: 2),
                                     "handshake response must be sent to the peer")
        let reply = try CoAPSerializer.coapMessageWithData(datagram)
        XCTAssertEqual(reply.getIntegerOptions(.handshakeType).first, 2)
        XCTAssertEqual(reply.messageId, 7)
        XCTAssertEqual(reply.responseCode, .content)
        XCTAssertEqual(reply.payload?.data, Coala.keyPair.publicKey(),
                       "handshake response must carry our own public key")
    }

    func testIncomingHandshakeWithoutPayloadThrowsPayloadExpected() {
        var message = CoAPMessage(type: .confirmable, code: .request(.get))
        message.setOption(.handshakeType, value: 1)
        let fromAddress = Address(host: "127.0.0.1", port: 9)

        XCTAssertThrowsError(try layer.handleIncomingHandshake(coala: coala,
                                                               message: message,
                                                               fromAddress: fromAddress)) { error in
            XCTAssertEqual(error as? SecurityLayer.SecurityLayerError, .payloadExpected)
        }
    }
}

/// Minimal non-blocking UDP listener on an ephemeral loopback port,
/// used to capture datagrams that SecurityLayer sends via `coala.send`.
private final class UDPReceiver {

    private let fd: Int32
    let port: UInt16

    init?() {
        let socketFd = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFd >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // ephemeral
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(socketFd)
            return nil
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFd, $0, &length)
            }
        }
        guard named == 0 else {
            close(socketFd)
            return nil
        }

        let flags = fcntl(socketFd, F_GETFL, 0)
        _ = fcntl(socketFd, F_SETFL, flags | O_NONBLOCK)

        fd = socketFd
        port = UInt16(bigEndian: boundAddress.sin_port)
    }

    /// Polls the socket until a datagram arrives or the timeout elapses.
    func receive(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                return Data(buffer[0..<count])
            }
            usleep(20_000)
        }
        return nil
    }

    deinit {
        close(fd)
    }
}
