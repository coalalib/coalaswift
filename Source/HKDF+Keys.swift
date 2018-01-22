//
//  HKDF+Keys.swift
//  Coala
//
//  Created by Roman on 03/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

private let keyLength = 16
private let ivLength = 4

extension HKDF {

    convenience init(sharedSecret: Data, salt: Data, info: Data) {
        self.init(hash: .sha256,
                  inputKeyingMaterial: sharedSecret,
                  salt: salt,
                  info: info,
                  outputLength: keyLength * 2 + ivLength * 2)
    }

    var peerKey: Data {
        return outputKeyingMaterial.subdata(in: 0 ..< keyLength)
    }

    var myKey: Data {
        return outputKeyingMaterial.subdata(in: keyLength ..< keyLength * 2)
    }

    var peerIV: Data {
        return outputKeyingMaterial.subdata(in: keyLength * 2 ..< keyLength * 2 + ivLength)
    }

    var myIV: Data {
        return outputKeyingMaterial.subdata(in: keyLength * 2 + 4 ..< keyLength * 2 + ivLength * 2)
    }
}
