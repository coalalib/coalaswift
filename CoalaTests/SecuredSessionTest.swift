//
//  SecuredSessionTest.swift
//  Coala
//
//  Created by Roman on 03/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class SecuredSessionTests: XCTestCase {

    func testDuplex() {
        let session1 = SecuredSession(incoming: false)
        let session2 = SecuredSession(incoming: true)
        try? session1.start(peerPublicKey: session2.publicKey)
        try? session2.start(peerPublicKey: session1.publicKey)
        let plainText = "The quick, brown fox jumps over a lazy dog.".data
        let counter: UInt16 = 1000
        let aead1 = session1.aead!
        let aead2 = session2.aead!
        do {
            let cipher1 = try aead1.seal(plainText: plainText, counter: counter)
            let plain2 = try aead2.open(cipherText: cipher1, counter: counter)
            XCTAssertEqual(plainText, plain2)
            let cipher2 = try aead2.seal(plainText: plainText, counter: counter)
            let plain1 = try aead1.open(cipherText: cipher2, counter: counter)
            XCTAssertEqual(plainText, plain1)
            XCTAssertNotEqual(cipher1, cipher2)
        } catch let error {
            print(error)
            XCTAssert(false)
        }
    }

}
