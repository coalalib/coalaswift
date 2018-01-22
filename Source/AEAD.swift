//
//  AEAD.swift
//  Coala
//
//  Created by Roman on 02/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

class AEAD {

    private let encryptor, decryptor: AESGCM
    let peerIV, myIV: Data

    init(peerKey: Data, myKey: Data, peerIV: Data, myIV: Data) {
        encryptor = AESGCM(key: myKey)
        decryptor = AESGCM(key: peerKey)
        self.peerIV = peerIV
        self.myIV = myIV
    }

    func open(cipherText: Data, counter: UInt16, associatedData: Data? = nil) throws -> Data {
        return try decryptor.open(cipherText: cipherText,
                                  nonce: AEAD.makeNonce(iVector: peerIV, counter: counter),
                                  additionalAuthenticatedData: associatedData ?? Data())
    }

    func seal(plainText: Data, counter: UInt16, associatedData: Data? = nil) throws -> Data {
        return try encryptor.seal(plainText: plainText,
                                  nonce: AEAD.makeNonce(iVector: myIV, counter: counter),
                                  additionalAuthenticatedData: associatedData ?? Data())
    }

    static func makeNonce(iVector: Data, counter: UInt16) -> Data {
        var counter = counter.littleEndian
        let counterLength = 8
        let counterData = Data(bytes: &counter, count: MemoryLayout<UInt16>.size)
        let zeros = Data(count: counterLength - MemoryLayout<UInt16>.size)
        return iVector + counterData + zeros
    }

}
