//
//  AESGCM.swift
//  Coala
//
//  Created by Roman on 01/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

struct AESGCM {

    let key: Data
    private let tagLength = 12

    enum AESGCMError: Error {
        case cipherTooShort
        case validationFailed
    }

    func seal(plainText: Data, nonce: Data, additionalAuthenticatedData: Data) throws -> Data {
        let (cypherText, tag) = try CC.GCM.crypt(.encrypt,
                                                 algorithm: .aes,
                                                 data: plainText,
                                                 key: key,
                                                 iv: nonce,
                                                 aData: additionalAuthenticatedData,
                                                 tagLength: tagLength)
        return cypherText + tag
    }

    func open(cipherText: Data, nonce: Data, additionalAuthenticatedData: Data) throws -> Data {
        guard cipherText.count >= tagLength else { throw AESGCMError.cipherTooShort }
        let tagIndex = cipherText.count - tagLength
        let encryptedTag = Data(cipherText.suffix(from: tagIndex))
        let cipherText = Data(cipherText.prefix(upTo: tagIndex))
        let (plainText, decryptedTag) = try CC.GCM.crypt(.decrypt,
                                                         algorithm: .aes,
                                                         data: cipherText,
                                                         key: key,
                                                         iv: nonce,
                                                         aData: additionalAuthenticatedData,
                                                         tagLength: tagLength)
        if encryptedTag != decryptedTag {
            throw AESGCMError.validationFailed
        }
        return plainText
    }

}
