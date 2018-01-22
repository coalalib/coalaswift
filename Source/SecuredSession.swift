//
//  SecuredSession.swift
//  Coala
//
//  Created by Roman on 03/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Curve25519

class SecuredSession {

    let incoming: Bool
    var aead: AEAD?

    private(set) var peerPublicKey: Data?

    init(incoming: Bool) {
        self.incoming = incoming
    }

    var publicKey: Data {
        return Coala.keyPair.publicKey()
    }

    enum SecuredSessionError: Error {
        case curve25519SharedSecretGenerationFailed
    }

    func start(peerPublicKey: Data) throws {
        self.peerPublicKey = peerPublicKey
        var sharedSecret: Data!
        SwiftTryCatch.tryRun({
            sharedSecret = Curve25519.generateSharedSecret(fromPublicKey: peerPublicKey,
                                                           andKeyPair: Coala.keyPair)
        }, catchRun: nil, finallyRun: nil)
        guard sharedSecret != nil else {
            throw SecuredSessionError.curve25519SharedSecretGenerationFailed
        }
        let hkdf = HKDF(sharedSecret: sharedSecret, salt: Data(), info: Data())
        if incoming {
            aead = AEAD(peerKey: hkdf.myKey,
                        myKey: hkdf.peerKey,
                        peerIV: hkdf.myIV,
                        myIV: hkdf.peerIV)
        } else {
            aead = AEAD(peerKey: hkdf.peerKey,
                        myKey: hkdf.myKey,
                        peerIV: hkdf.peerIV,
                        myIV: hkdf.myIV)
        }
    }

}
