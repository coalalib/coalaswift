//
//  Curve25519Tests.swift
//  Coala
//
//  Created by Roman on 31/10/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
import Coala
import Curve25519

class Curve25519Tests: XCTestCase {

    func testKeyPair() {
        let keyPair1 = Curve25519.generateKeyPair()
        let keyPair2 = Curve25519.generateKeyPair()
        let sharedSecret1 = Curve25519.generateSharedSecret(fromPublicKey: keyPair2.publicKey(),
                                                            andKeyPair: keyPair1)
        let sharedSecret2 = Curve25519.generateSharedSecret(fromPublicKey: keyPair1.publicKey(),
                                                            andKeyPair: keyPair2)
        XCTAssertEqual(keyPair1.publicKey().count, 32)
        XCTAssertEqual(keyPair2.publicKey().count, 32)
        XCTAssertNotEqual(keyPair1.publicKey(), keyPair2.publicKey())
        XCTAssertEqual(sharedSecret1, sharedSecret2)
    }

}
