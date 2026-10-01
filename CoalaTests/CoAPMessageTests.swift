//
//  CoAPMessageTests.swift
//  Coala
//
//  Created by Roman on 21/12/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class CoAPMessageTests: XCTestCase {

    func testSetUrlTwice() {
        let url = URL(string: "coaps://some.server.com:4488/somepath?query=42&query2=33")!
        var message = CoAPMessage(type: .confirmable, method: .get, url: url)
        message.url = url
        XCTAssertEqual(message.url, url)
    }

    /// Requests in flight must never share a messageId: the pool keys exchanges by it,
    /// and two random ids colliding delivered one request's answer to another (KMA-1162).
    func testGeneratedMessageIdsAreDistinctAndNeverZero() {
        let ids = (0..<2000).map { _ in CoAPMessage(type: .confirmable, code: .request(.get)).messageId }

        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains(0))
    }

    func testMessageIdCounterWrapsPastZero() {
        XCTAssertEqual(CoAPMessage.nextMessageId(after: 1), 2)
        XCTAssertEqual(CoAPMessage.nextMessageId(after: 65534), 65535)
        XCTAssertEqual(CoAPMessage.nextMessageId(after: 65535), 1)
    }

}
