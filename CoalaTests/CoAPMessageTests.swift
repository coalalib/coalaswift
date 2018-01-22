//
//  CoAPMessageTests.swift
//  Coala
//
//  Created by Roman on 21/12/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
import Coala

class CoAPMessageTests: XCTestCase {

    func testSetUrlTwice() {
        let url = URL(string: "coaps://some.server.com:4488/somepath?query=42&query2=33")!
        var message = CoAPMessage(type: .confirmable, method: .get, url: url)
        message.url = url
        XCTAssertEqual(message.url, url)
    }

}
