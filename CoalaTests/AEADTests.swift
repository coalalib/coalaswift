//
//  AEADTests.swift
//  Coala
//
//  Created by Roman on 02/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

private let peerKey =   "bdd1cf3e4a5d0d1c009be633da60a372".dataFromHexadecimalString() ?? Data()
private let myKey =     "6e486ac093054578dc5308b966b9ff28".dataFromHexadecimalString() ?? Data()
private let peerIV =    "799212a9".dataFromHexadecimalString() ?? Data()
private let myIV =      "b3efe5ce".dataFromHexadecimalString() ?? Data()

class AEADTests: XCTestCase {

    let aead = AEAD(peerKey: peerKey, myKey: myKey, peerIV: peerIV, myIV: myIV)

    func testNonce() {
        let nonce = AEAD.makeNonce(iVector: peerIV, counter: 256)
        XCTAssertEqual(nonce, "799212a90001000000000000".dataFromHexadecimalString())
    }

    func testSeal() {
        let plainText = "The quick, brown fox jumps over a lazy dog.".data
        let aData = "88e564a2e6b64a356efd11".dataFromHexadecimalString()
        do {
            let data = try aead.seal(plainText: plainText, counter: 300, associatedData: aData)
            let expectedData = ("066770c836b2c0a745adaeef33005392a6dd02c85a5047149a051dfb6d" +
                "d15f840083c407154e04f76d878cb42973e72f4c3e10b9a67cf3").dataFromHexadecimalString()
            XCTAssertEqual(data, expectedData)
        } catch let error {
            print(error)
            XCTAssert(false)
        }
    }

    func testOpen() {
        let cipherText = ("1616888d96446e598e31fb3dafe855018bddf93cca9401f42fed6d19dc49ef4c" +
            "f816dddd741ccf2af09eeecbd3f867982e2a602d67cc78").dataFromHexadecimalString() ?? Data()
        let aData = "88e564a2e6b64a356efd11".dataFromHexadecimalString()
        do {
            let data = try aead.open(cipherText: cipherText, counter: 400, associatedData: aData)
            XCTAssertEqual(data.string, "The quick, brown fox jumps over a lazy dog.")
        } catch let error {
            print(error)
            XCTAssert(false)
        }
    }

}
