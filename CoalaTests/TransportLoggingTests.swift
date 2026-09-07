import Darwin
import XCTest
@testable import Coala

final class TransportLoggingTests: XCTestCase {

    private var originalLogger: CoalaLogger?
    private var logger: RecordingLogger!
    private var coala: Coala!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLogger = Coala.logger
        logger = RecordingLogger()
        Coala.logger = logger
        coala = try Coala(transport: .udp(port: 0))
    }

    override func tearDown() {
        coala?.stop()
        coala = nil
        Coala.logger = originalLogger
        originalLogger = nil
        logger = nil
        super.tearDown()
    }

    func testSecurityLookupMissIsDebugButAuthenticationFailureIsVisible() {
        coala.logIncomingFailure(SecurityLayer.SecurityLayerError.sourceMessageNotFound,
                                 messageID: 17)
        coala.logIncomingFailure(AESGCM.AESGCMError.validationFailed, messageID: 18)

        XCTAssertEqual(logger.records.map { $0.level }, [.debug, .warning])
        XCTAssertEqual(logger.records[0].message, "Response has no matching request")
        XCTAssertEqual(logger.records[0].context["message_id"] as? Int, 17)
        XCTAssertNil(logger.records[0].context["reason"])
        XCTAssertEqual(logger.records[1].message, "Incoming message processing failed")
        XCTAssertEqual(logger.records[1].context["message_id"] as? Int, 18)
        XCTAssertEqual(logger.records[1].context["reason"] as? String, "validation_failed")
    }

    // Deserialization failures never reach the layer stack; the inbound boundary test below
    // covers them where they actually happen.
    func testKnownInboundFailuresHaveStableTypedContext() {
        coala.logIncomingFailure(AESGCM.AESGCMError.cipherTooShort, messageID: 21)
        coala.logIncomingFailure(SecurityLayer.SecurityLayerError.payloadExpected,
                                 messageID: 22)

        XCTAssertEqual(logger.records.map { $0.level }, [.warning, .warning])
        XCTAssertEqual(logger.records.map { $0.message }, [
            "Incoming message processing failed",
            "Incoming message processing failed"
        ])
        XCTAssertEqual(logger.records[0].context["reason"] as? String, "cipher_too_short")
        XCTAssertEqual(logger.records[1].context["reason"] as? String, "payload_expected")
    }

    func testObserveAndProxyFailuresHaveTypedReasons() {
        let errors: [Error] = [
            ObserveLayer.ObserveLayerError.resourceIsNotObserved,
            ObserveLayer.ObserveLayerError.requestHandledWithNotification,
            ProxyLayer.ProxyLayerError.proxyingNotSupported
        ]
        let messageIDs = [24, 25, 26]
        let reasons = [
            "resource_is_not_observed",
            "request_handled_with_notification",
            "proxying_not_supported"
        ]

        for (error, messageID) in zip(errors, messageIDs) {
            coala.logIncomingFailure(error, messageID: messageID)
        }

        XCTAssertEqual(logger.records.count, errors.count)
        for index in errors.indices {
            let record = logger.records[index]
            XCTAssertEqual(record.level, .warning)
            XCTAssertEqual(record.message, "Incoming message processing failed")
            XCTAssertEqual(record.context["message_id"] as? Int, messageIDs[index])
            XCTAssertEqual(record.context["reason"] as? String, reasons[index])
        }
    }

    func testControlFlowInterruptionsRemainSilent() {
        coala.logIncomingFailure(SecurityLayer.SecurityLayerError.handshakeInProgress,
                                 messageID: 31)
        coala.logIncomingFailure(ARQLayerError.arqTransferIncomplete, messageID: 32)
        coala.logIncomingFailure(ARQLayerError.splittingToBlocks, messageID: 33)

        XCTAssertTrue(logger.records.isEmpty)
    }

    func testResponseLayerClassifiesUnmatchedResponsesAndPreservesObserveGuard() throws {
        let layer = ResponseLayer()
        var address = Address(host: "127.0.0.1", port: 5683)
        var ack: CoAPMessage?
        var unmatched = CoAPMessage(type: .acknowledgement,
                                    code: .response(.content),
                                    messageId: 41)

        try layer.run(coala: coala, message: &unmatched, fromAddress: &address, ack: &ack)

        var observe = CoAPMessage(type: .nonConfirmable,
                                  code: .response(.content),
                                  messageId: 42)
        observe.setOption(.observe, value: 1)
        try layer.run(coala: coala, message: &observe, fromAddress: &address, ack: &ack)

        XCTAssertEqual(logger.records.count, 1)
        XCTAssertEqual(logger.records[0].level, .debug)
        XCTAssertEqual(logger.records[0].message, "Response has no matching request")
        XCTAssertEqual(logger.records[0].context["message_id"] as? Int, 41)
    }

    func testResponseLayerMatchesTokenWhenResponseMessageIDChanges() throws {
        let handled = expectation(description: "response handler called")
        var request = CoAPMessage(type: .confirmable,
                                  method: .get,
                                  url: URL(string: "coap://127.0.0.1:5683/test"))
        request.onResponse = { _ in handled.fulfill() }
        coala.messagePool.push(message: request)
        var response = CoAPMessage(type: .acknowledgement,
                                   code: .response(.changed),
                                   messageId: request.messageId &+ 1)
        response.token = request.token
        var address = Address(host: "127.0.0.1", port: 5683)
        var ack: CoAPMessage?

        try ResponseLayer().run(coala: coala,
                                message: &response,
                                fromAddress: &address,
                                ack: &ack)

        wait(for: [handled], timeout: 2)
        XCTAssertFalse(logger.records.contains { $0.message == "Response has no matching request" })
    }

    func testActualInboundBoundaryClassifiesUnmatchedAndMalformedDatagrams() throws {
        let socket = GCDAsyncUdpSocket(delegate: nil, delegateQueue: DispatchQueue.main)
        let address = loopbackAddressData(port: 5683)
        var unmatched = CoAPMessage(type: .acknowledgement,
                                    code: .response(.content),
                                    messageId: 51)
        unmatched.scheme = .coapSecure
        unmatched.setOption(.proxySecurityId, value: 1)
        let serialized = try CoAPSerializer.dataWithCoAPMessage(unmatched)

        coala.udpSocket(socket, didReceive: serialized,
                        fromAddress: address, withFilterContext: nil)
        coala.udpSocket(socket, didReceive: Data([0x40]),
                        fromAddress: address, withFilterContext: nil)

        let classified = logger.records.filter {
            $0.message == "Response has no matching request"
                || $0.message == "Incoming message could not be deserialized"
        }
        XCTAssertEqual(classified.map { $0.level }, [.debug, .error])
        XCTAssertEqual(classified[0].context["message_id"] as? Int, 51)
        XCTAssertEqual(classified[1].context["reason"] as? String, "header_too_short")
    }

    func testMessagePoolExpirationDoesNotLogRequestContents() {
        var message = CoAPMessage(type: .confirmable,
                                  method: .get,
                                  url: URL(string: "coap://127.0.0.1:5683/private?token=secret"))
        message.payload = "sensitive body"
        coala.messagePool.maxAttempts = 1
        coala.messagePool.push(message: message)

        coala.messagePool.tick()

        let record = logger.records.first { $0.message == "Request expired" }
        XCTAssertEqual(record?.level, .debug)
        XCTAssertEqual(record?.context["message_id"] as? Int, Int(message.messageId))
        XCTAssertFalse(record?.message.contains("secret") ?? true)
        XCTAssertFalse(record?.message.contains("private") ?? true)
        XCTAssertFalse(record?.message.contains("sensitive") ?? true)
    }

    private func loopbackAddressData(port: UInt16) -> Data {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafeBytes(of: &address) { Data($0) }
    }
}

private final class ControlledLoggingSocket: GCDAsyncSocket {
    var initializationError: Error?
    override func connect(toHost host: String, onPort port: UInt16, withTimeout timeout: TimeInterval) throws {
        if let error = initializationError { throw error }
    }
}

extension TransportLoggingTests {
    /// A TCP connect failure is ERROR at every boundary — whether a `set(transport:)`
    /// completion is about to receive it, it was cancelled by `stop()` or a replacement
    /// switch, or nobody is told (internal reconnect, `restart()`). Only the socket fault is
    /// at that level; the caller's own connectivity record stays DEBUG.
    func testTcpConnectFailureIsErrorAtEveryBoundary() throws {
        for boundary in ["success", "failure", "stop", "replacement", "initialization_failure"] {
            var sockets: [ControlledLoggingSocket] = []
            let rawError = NSError(domain: "ControlledSocket", code: 61)
            let client = try Coala(transport: .udp(port: 0)) { delegate, delegateQueue, socketQueue in
                let socket = ControlledLoggingSocket(delegate: delegate, delegateQueue: delegateQueue,
                                                      socketQueue: socketQueue)
                if boundary == "initialization_failure" && sockets.isEmpty { socket.initializationError = rawError }
                sockets.append(socket)
                return socket
            }
            defer { client.stop() }
            let start = logger.records.count
            var completions: [Error?] = []
            do {
                try client.set(transport: .tcp(host: "127.0.0.1", port: 16666)) { completions.append($0) }
                XCTAssertNotEqual(boundary, "initialization_failure")
            } catch {
                XCTAssertEqual(boundary, "initialization_failure")
                guard case CoalaError.portIsBusy = error else { return XCTFail("unchanged mapped throw expected") }
            }
            let ownedSocket = sockets[0]
            switch boundary {
            case "success":
                client.socket(ownedSocket, didConnectToHost: "127.0.0.1", port: 16666)
                XCTAssertEqual(completions.count, 1)
                XCTAssertNil(completions[0])
                client.socketDidDisconnect(ownedSocket, withError: rawError)
            case "failure":
                client.restart() // An in-flight restart must preserve this attempt and its completion.
                client.socketDidDisconnect(ownedSocket, withError: rawError)
                XCTAssertEqual(completions.count, 1)
                XCTAssertTrue(completions[0] as NSError? === rawError)
                client.restart()
            case "stop":
                client.stop()
                XCTAssertEqual(completions.count, 1)
                guard case CoalaError.tcpConnectCancelled? = completions[0] else {
                    return XCTFail("stop must retain its original callback")
                }
                client.restart()
            case "replacement":
                try client.set(transport: .tcp(host: "127.0.0.1", port: 16666)) { completions.append($0) }
                client.socketDidDisconnect(ownedSocket, withError: rawError)
                XCTAssertEqual(completions.count, 1, "stale callback must not consume replacement completion")
            default:
                XCTAssertTrue(completions.isEmpty, "synchronous throw must not also call completion")
                client.restart()
            }
            client.socketDidDisconnect(sockets.last!, withError: rawError)

            let expectedErrors: [String]
            switch boundary {
            case "success":
                // The established session dropped, then the reconnect it issued failed.
                expectedErrors = ["TCP socket disconnected unexpectedly", "TCP connection failed"]
            case "failure":
                // Told first, then the restart attempt nobody is told about fails.
                expectedErrors = ["TCP connection failed", "TCP connection failed"]
            case "initialization_failure":
                expectedErrors = ["Socket initialization failed", "TCP connection failed"]
            default:
                // "stop" cancels the attempt without a socket fault; "replacement" hands the
                // failure to the second switch's completion.
                expectedErrors = ["TCP connection failed"]
            }
            let records = logger.records.dropFirst(start)
            XCTAssertEqual(records.filter { $0.level == .error }.map { $0.message }, expectedErrors, boundary)
            XCTAssertTrue(records.filter { $0.level == .warning }.isEmpty, boundary)
            XCTAssertTrue(records.filter {
                $0.message == "TCP connection failed" || $0.message == "Socket initialization failed"
            }.allSatisfy { $0.level == .error }, boundary)
            if boundary == "replacement" {
                XCTAssertEqual(completions.count, 2, "the replacement completion must receive the failure")
            }
        }
    }

    func testStandaloneTcpInitializationFailureRemainsVisible() throws {
        let error = NSError(domain: "ControlledSocket", code: 61)
        XCTAssertThrowsError(try Coala(transport: .tcp(host: "127.0.0.1", port: 16666)) {
            delegate, delegateQueue, socketQueue in
            let socket = ControlledLoggingSocket(delegate: delegate, delegateQueue: delegateQueue, socketQueue: socketQueue)
            socket.initializationError = error
            return socket
        }) { thrown in
            guard case CoalaError.portIsBusy = thrown else { return XCTFail("unchanged mapped throw expected") }
        }
        XCTAssertEqual(logger.records.filter { $0.message == "Socket initialization failed" }.map { $0.level }, [.error])
    }

    func testInternalRecoveryInitializationFailureRemainsVisible() throws {
        var socket: ControlledLoggingSocket!
        let client = try Coala(transport: .udp(port: 0)) { delegate, delegateQueue, socketQueue in
            socket = ControlledLoggingSocket(delegate: delegate, delegateQueue: delegateQueue, socketQueue: socketQueue)
            return socket
        }
        defer { client.stop() }
        try client.set(transport: .tcp(host: "127.0.0.1", port: 16666)) { _ in }
        client.socket(socket, didConnectToHost: "127.0.0.1", port: 16666)
        let rawError = NSError(domain: "ControlledSocket", code: 61)
        socket.initializationError = rawError
        client.socketDidDisconnect(socket, withError: rawError)
        XCTAssertEqual(logger.records.filter { $0.message == "Socket initialization failed" }.map { $0.level }, [.error])
        XCTAssertEqual(logger.records.filter { $0.message == "TCP socket disconnected unexpectedly" }.map { $0.level }, [.error])
    }

    /// `stop()` produces an error-free disconnect, the one expected transport callback. An
    /// error arriving in the stopped state can only be the peer or the OS closing the socket
    /// as `stop()` ran, so it is reported like any other unrequested disconnect.
    func testStoppedDisconnectIsDebugOnlyWithoutAnError() throws {
        let cases: [(error: Error?, level: LogLevel, message: String)] = [
            (nil, .debug, "TCP socket disconnected"),
            (NSError(domain: "ControlledSocket", code: 54), .error, "TCP socket disconnected unexpectedly")
        ]
        for testCase in cases {
            var socket: ControlledLoggingSocket!
            let client = try Coala(transport: .udp(port: 0)) { delegate, delegateQueue, socketQueue in
                socket = ControlledLoggingSocket(delegate: delegate, delegateQueue: delegateQueue, socketQueue: socketQueue)
                return socket
            }
            try client.set(transport: .tcp(host: "127.0.0.1", port: 16666)) { _ in }
            client.socket(socket, didConnectToHost: "127.0.0.1", port: 16666)
            client.stop()
            let start = logger.records.count
            client.socketDidDisconnect(socket, withError: testCase.error)

            let records = Array(logger.records.dropFirst(start))
            XCTAssertEqual(records.map { $0.message }, [testCase.message])
            XCTAssertEqual(records.first?.level, testCase.level)
            XCTAssertEqual(records.first?.context["tcp_state"] as? String, "stopped")
            XCTAssertEqual(records.first?.context["transport"] as? String, "tcp")
        }
    }
}

private final class LifecycleReentryLogger: CoalaLogger {
    let client: Coala
    var observations = 0
    init(client: Coala) { self.client = client }
    func log(_ message: String, level: LogLevel, asynchronous: Bool) {}
    func log(_ message: String, level: LogLevel, asynchronous: Bool,
             context: [String: Any], file: String, function: String, line: UInt) {
        guard message == "Socket initialization failed" || message == "Transport switch requested" else { return }
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [client] in
            _ = client.transport
            read.signal()
        }
        XCTAssertEqual(read.wait(timeout: .now() + 1), .success, "logger must run outside the lifecycle lock")
        observations += 1
    }
}

extension TransportLoggingTests {
    func testInitializationFailureLoggingAllowsLifecycleReentry() throws {
        let client = try Coala(transport: .udp(port: 0)) { delegate, delegateQueue, socketQueue in
            let socket = ControlledLoggingSocket(delegate: delegate, delegateQueue: delegateQueue, socketQueue: socketQueue)
            socket.initializationError = NSError(domain: "ControlledSocket", code: 61)
            return socket
        }
        defer { client.stop() }
        let reentrantLogger = LifecycleReentryLogger(client: client)
        Coala.logger = reentrantLogger
        defer { Coala.logger = logger }
        XCTAssertThrowsError(try client.set(transport: .tcp(host: "127.0.0.1", port: 16666)) { _ in
            XCTFail("throw must not call completion")
        })
        XCTAssertEqual(reentrantLogger.observations, 2)
    }
}
