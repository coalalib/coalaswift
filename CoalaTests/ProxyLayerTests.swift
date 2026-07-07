//
//  ProxyLayerTests.swift
//  Coala
//
//  Created by Roman on 01/06/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class ProxyLayerTests: XCTestCase {

    func testProxyMessage() {
        let peer = Address(host: "peer.cloud", port: 42)
        let proxyAddress = Address(host: "proxy.cloud", port: 55)

        var proxiedMessage = CoAPMessage(type: .confirmable, method: .post)
        let url = URL(string: "coaps://\(peer.host):\(peer.port)/path/sub?t=1&u=W")
        proxiedMessage.url = url
        proxiedMessage.proxyViaAddress = proxyAddress
        let proxyLayer = ProxyLayer()
        var destination = proxiedMessage.address!
        do {
          let coala = try Coala(transport: .udp(port: 0))
          defer { coala.stop() }
          try proxyLayer.run(coala: coala, message: &proxiedMessage, toAddress: &destination)
        } catch {
          XCTFail("outbound proxy run should not throw: \(error)")
        }
        XCTAssertNotNil(proxiedMessage.getOptions(.uriPath).first)
        XCTAssertNotNil(proxiedMessage.getOptions(.uriQuery).first)
        let proxyOption = proxiedMessage.getStringOptions(.proxyUri).first
        XCTAssertNotNil(proxyOption)
        XCTAssertEqual(destination, proxyAddress)
    }

    func testProxyError() throws {
        let peer = Address(host: "peer.cloud", port: 42)
        let proxyAddress = Address(host: "proxy.cloud", port: 55)

        var proxiedMessage = CoAPMessage(type: .confirmable, method: .post)
        let url = URL(string: "coaps://\(peer.host):\(peer.port)/path/sub?t=1&u=W")
        proxiedMessage.url = url
        proxiedMessage.setOption(.proxyUri, value: url?.absoluteString)

        let proxyLayer = ProxyLayer()
        var from = proxyAddress
        var ack: CoAPMessage?
        let coala = try Coala(transport: .udp(port: 0))
        defer { coala.stop() }
        // An inbound message carrying a proxyUri option must be rejected.
        XCTAssertThrowsError(try proxyLayer.run(coala: coala,
                                                message: &proxiedMessage,
                                                fromAddress: &from,
                                                ack: &ack))
    }

}
