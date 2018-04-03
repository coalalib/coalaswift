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
          try proxyLayer.run(coala: Coala(), message: &proxiedMessage, toAddress: &destination)
        } catch {
          XCTAssert(false)
        }
        XCTAssertNotNil(proxiedMessage.getOptions(.uriPath).first)
        XCTAssertNotNil(proxiedMessage.getOptions(.uriQuery).first)
        let proxyOption = proxiedMessage.getStringOptions(.proxyUri).first
        XCTAssertNotNil(proxyOption)
        XCTAssertEqual(destination, proxyAddress)
    }

    func testProxyError() {
        let peer = Address(host: "peer.cloud", port: 42)
        let proxyAddress = Address(host: "proxy.cloud", port: 55)

        var proxiedMessage = CoAPMessage(type: .confirmable, method: .post)
        let url = URL(string: "coaps://\(peer.host):\(peer.port)/path/sub?t=1&u=W")
        proxiedMessage.url = url
        proxiedMessage.setOption(.proxyUri, value: url?.absoluteString)

        let proxyLayer = ProxyLayer()
        var from = proxyAddress
        var ack: CoAPMessage?
        do {
            try proxyLayer.run(coala: Coala(),
                               message: &proxiedMessage,
                               fromAddress: &from,
                               ack: &ack)
        } catch {
            XCTAssert(true)
            return
        }
        XCTAssert(false)
    }

}
