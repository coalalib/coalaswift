//
//  Coala.swift
//  Coala
//
//  Created by Roman on 05/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation
import Curve25519

/**
    The main class, exposes most of Coala capabilities
    Is itself a representation of P2P capable CoAP client/server
*/

public class Coala: NSObject {

    /// Response to a CoAP request
    public enum Response {
        case message(message: CoAPMessage, from: Address)   /// Response message from a peer
        case error(error: Error)    /// Error caused by a request (including a delivery timeout)
    }

    /// Response handler to be called on receiving response to a `CoAPMessage`
    public typealias ResponseHandler = (Response) -> Void

    /// Fallback TCP Socket if UDP is blocked by firewall
    private let tcpSocket = GCDAsyncSocket()
    private let defaultTcpPort: UInt16 = 16666
    private let tcpSerializer = CoAPTcpSerializer()
    private var isTcpConnecting = false
    private var tcpProxyHost: String?

    /// Main UDP Socket
    let socket = GCDAsyncUdpSocket()
    let port: UInt16

    private(set) var resources = [CoAPResourceProtocol]()
    let messagePool = CoAPMessagePool()
    var layerStack = LayerStack()

    /// Component, responsible for discovering other compatible peers on the local network
    public let resourceDiscovery = ResourceDiscovery()

    public static let defaultPort: UInt16 = 5683

    /// External logger can be used here
    public static var logger: CoalaLogger? = DefaultLogger()

    static var keyPair = Curve25519.generateKeyPair()

    /// Curve25519 private and public keys pair
    public static var curveKeyPairData: Data {
        get {
            return keyPair.toData()
        }
        set {
            keyPair = ECKeyPair.from(data: newValue) ?? keyPair
        }
    }

    /**
     Initializes a new Coala.

     - parameter port: Custom port, is not sure, use a default port (call `init()` instead)

     - returns: A ready to use Coala instance.
     */
    public init(port: UInt16 = Coala.defaultPort) throws {
        self.port = port
        super.init()
        // Not considering multithreaded processing yet due to complexity of locks during blockwise processing
        let coalaQueue = DispatchQueue(label: "com.ndmsystems.coala", qos: .utility)
        socket.setDelegate(self, delegateQueue: coalaQueue)
        tcpSocket.setDelegate(self, delegateQueue: coalaQueue)
        try start()
        messagePool.coala = self
        resourceDiscovery.startService(coala: self)
    }

    /// Restart Coala.
    public func restart() {
        stop()
        try? start()
    }

    /// Stop listening to all incoming messages
    public func stop() {
        socket.close()
    }

    func start() throws {
        do {
            try socket.bind(toPort: port)
            try socket.beginReceiving()
            try socket.joinMulticastGroup(ResourceDiscovery.multicastAddress)
        } catch let error {
            LogError("Couldn't initiate socket: \(error)")
            throw CoalaError.portIsBusy
        }
    }

    public func startTcpProxying(host: String) throws {
        self.tcpProxyHost = host

        guard !tcpSocket.isConnected && !isTcpConnecting else { return }
        isTcpConnecting = true
        try tcpSocket.connect(toHost: host, onPort: defaultTcpPort)
    }

    public func configureMessagePool(
        expirationTimeout: TimeInterval,
        totalResendCount: Int,
        longRunningUrlPaths: [UriPathConfig]
    ) {
        messagePool.resendTimeInterval = expirationTimeout
        messagePool.maxAttempts = totalResendCount
        messagePool.longRunningUrlPaths = longRunningUrlPaths
    }

    deinit {
        messagePool.stopTimer()
        socket.close()
        tcpSocket.disconnect()
    }

    /// Send CoAPMessage to a reciever specified in `message.url`
    public func send(_ message: CoAPMessage) throws {
        if socket.isClosed() {
            restart()
        }
        guard var address = message.address else {
            throw CoalaError.addressNotSet
        }
        var processedMessage = message
        do {
            try layerStack.run(&processedMessage, coala: self, toAddress: &address)
            let data = try CoAPSerializer.dataWithCoAPMessage(processedMessage)

            if tcpProxyHost != nil {
                let tcpFrame = tcpSerializer.encodeTcpFrame(with: address, data: data)
                tcpSocket.write(tcpFrame, withTimeout: -1, tag: 0)
            } else {
                socket.send(data, toHost: address.host, port: address.port, withTimeout: -1, tag: 0)
            }

            messagePool.push(message: message)
        } catch {
            if !shouldSilentlyIgnore(error) {
                throw error
            }
        }
    }

    public func send(
        _ message: CoAPMessage,
        block2DownloadProgress: ((Data) -> Void)?
    ) throws {
        if let token = message.token {
          layerStack.arqLayer.block2DownloadProgresses[token.description] = block2DownloadProgress
        }
        try send(message)
    }

    /// Add resource to Coala
    public func addResource(_ resource: CoAPResourceProtocol) {
        if let resource = resource as? CoAPResource {
            resource.coala = self
        }
        resources.append(resource)
    }

    /// Remove resources from Coala
    public func removeResources(forPath path: String) {
        while let index = resources.firstIndex(where: { $0.path == path }) {
            if let resource = resources[index] as? CoAPResource {
                resource.coala = nil
            }
            resources.remove(at: index)
        }
    }

    private func decodePayload(from address: Address, payload: Data) {
        var address = address
        guard var message = try? CoAPSerializer.coapMessageWithData(payload)
        else {
            LogError("Error! Can't deserialize data into message")
            return
        }
        message.address = address
        do {
            try layerStack.run(&message, coala: self, fromAddress: &address)
        } catch let error {
            if !shouldSilentlyIgnore(error) {
                LogWarn("Incoming stack interrupted: \(error)")
            }
        }
    }
}

extension Coala: GCDAsyncUdpSocketDelegate {

    public func udpSocket(_ sock: GCDAsyncUdpSocket, didSendDataWithTag tag: Int) {}

    public func udpSocket(
        _ sock: GCDAsyncUdpSocket,
        didNotSendDataWithTag tag: Int,
        dueToError error: Error?
    ) {
        LogError("Coala:\(sock.localPort()) didn't send: \(error?.localizedDescription ?? "")")
    }

    public func udpSocket(_ sock: GCDAsyncUdpSocket,
                          didReceive data: Data,
                          fromAddress address: Data,
                          withFilterContext filterContext: Any?) {
        guard let address = Address(addressData: address)
            else {
                LogError("Error! Message sender unknown")
                return
        }
        decodePayload(from: address, payload: data)
    }

    public func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        guard sock.localPort() != 0 else { return }

        if let error = error {
            LogError("Coala:\(sock.localPort()) did close with error: \(error.localizedDescription)")
        }
    }

}

extension Coala: GCDAsyncSocketDelegate {
    public func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        LogInfo("TCP socket did connected")
        isTcpConnecting = false
        sock.readData(withTimeout: -1, tag: 1)
    }

    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        tcpSerializer.decodeTcpFrame(with: data).forEach {
            decodePayload(from: $0.address, payload: $0.data)
        }
        sock.readData(withTimeout: -1, tag: tag)
    }

    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        isTcpConnecting = false
        tcpSerializer.flushBuffer()
        if let host = tcpProxyHost {
            try? startTcpProxying(host: host)
        }
        if let error = err {
            LogError("TCP socket did disconnect with error: \(error.localizedDescription)")
        }
    }
}

extension Coala {
    func shouldSilentlyIgnore(_ error: Error) -> Bool {
        if let error = error as? ARQLayerError {
            switch error {
            case .arqTransferIncomplete, .splittingToBlocks:
                return true
            default:
                return false
            }
        }
        if let error = error as? SecurityLayer.SecurityLayerError, error == .handshakeInProgress {
            return true
        }
        return false
    }
}

// MARK: - Delivery statistics
extension Coala {
    public func getStatistics(for address: Address, scheme: CoAPMessage.Scheme) -> DeliveryStatistics? {
        messagePool.getStatistics(for: address, scheme: scheme)
    }

    public func getStatistics(for message: CoAPMessage) -> DeliveryStatistics? {
        guard let address = message.address else { return nil }
        return messagePool.getStatistics(for: address, scheme: message.scheme)
    }

    public func flushStatistics(for address: Address, scheme: CoAPMessage.Scheme) {
        messagePool.flushStatistics(for: address, scheme: scheme)
    }

    public func flushAllStatistics() {
        messagePool.flushAllStatistics()
    }
}

public enum CoalaError: LocalizedError {
    case addressNotSet
    case portIsBusy
    public var errorDescription: String? {
        switch self {
        case .portIsBusy:
            return "Port is taken by another application"
        case .addressNotSet:
            return "Message destination not set"
        }
    }
}
