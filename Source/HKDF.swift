//
//  HKDF.swift
//  Coala
//
//  Created by Roman on 02/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

class HKDF {

    let hash: CC.HMACAlg
    let inputKeyingMaterial: Data
    let salt: Data
    let info: Data
    let outputLength: Int

    init(hash: CC.HMACAlg,
         inputKeyingMaterial: Data,
         salt: Data,
         info: Data,
         outputLength: Int) {
        self.hash = hash
        self.inputKeyingMaterial = inputKeyingMaterial
        self.salt = salt
        self.info = info
        self.outputLength = outputLength
    }

    func extract() -> Data {
        return CC.HMAC(inputKeyingMaterial, alg: hash, key: salt)
    }

    func expand() -> Data {
        let n = UInt8(ceil(Double(outputLength) / Double(hash.digestLength)))
        let t = Array(1...n).reduce((t: Data(), ti: Data()), { prev, idx in
            let ti = CC.HMAC(prev.ti + info + Data([idx]), alg: hash, key: pseudoRandomKey)
            return (t: prev.t + ti, ti: ti)
        }).t
        return Data(t.prefix(upTo: outputLength))
    }

    lazy var pseudoRandomKey: Data = self.extract()
    lazy var outputKeyingMaterial: Data = self.expand()
}
