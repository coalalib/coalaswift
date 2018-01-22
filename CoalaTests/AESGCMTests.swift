//
//  AesGcmTests.swift
//  Coala
//
//  Created by Roman on 31/10/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class AesGcmTests: XCTestCase {

    func testGcmAvailable() {
        let gcmAvailable: Bool = CC.GCM.available()
        XCTAssert(gcmAvailable)
    }

    let key = "7CF5919725AD47A9873A2E449984CB4D".dataFromHexadecimalString() ?? Data()
    let nonce = "139B03C8CA7973584969EE50".dataFromHexadecimalString() ?? Data()
    let aData = "F0D859E9".dataFromHexadecimalString() ?? Data()
    let referencePlainText = "The quick, brown fox jumps over a lazy dog.".data
    let referenceCipherText = ("462cc3bbaf3798940a07f25e056d8a34a49be521fdf709f2ab5ef987aa7b92" +
        "4520fdf125a9473b35c5d2f2cb32e50c83d72cbdb451d6c1").dataFromHexadecimalString() ?? Data()

    func testReferenceEncrypt() {
        let encryptor = AESGCM(key: key)
        do {
            let cipherText = try encryptor.seal(plainText: referencePlainText,
                                                nonce: nonce,
                                                additionalAuthenticatedData: aData)
            XCTAssertEqual(cipherText, referenceCipherText)
        } catch let error {
            print(error)
            XCTAssert(false)
        }
    }

    func testReferenceDecrypt() {
        let decryptor = AESGCM(key: key)
        do {
            let plainText = try decryptor.open(cipherText: referenceCipherText,
                                               nonce: nonce,
                                               additionalAuthenticatedData: aData)
            XCTAssertEqual(plainText, referencePlainText)
        } catch let error {
            print(error)
            XCTAssert(false)
        }
    }

    func testEmptyData() {
        let encryptor = AESGCM(key: key)
        let decryptor = AESGCM(key: key)
        do {
            let cipherText = try encryptor.seal(plainText: Data(),
                                                nonce: nonce,
                                                additionalAuthenticatedData: aData)
            let plainText = try decryptor.open(cipherText: cipherText,
                                               nonce: nonce,
                                               additionalAuthenticatedData: aData)
            XCTAssertEqual(plainText.count, 0)
        } catch let error {
            print(error)
            XCTAssert(false)
        }
    }

    func testLargeData() {
        let encryptor = AESGCM(key: key)
        let decryptor = AESGCM(key: key)
        let largeData = Data.randomData(length: 5000)
        let largeAdditionalData = Data.randomData(length: 500)
        do {
            let cipherText = try encryptor.seal(plainText: largeData,
                                                nonce: nonce,
                                                additionalAuthenticatedData: largeAdditionalData)
            let plainText = try decryptor.open(cipherText: cipherText,
                                               nonce: nonce,
                                               additionalAuthenticatedData: largeAdditionalData)
            XCTAssertEqual(plainText, largeData)
        } catch let error {
            print(error)
            XCTAssert(false)
        }
    }

    func testCorruptedCipherText() {
        var corruptedCipherText = referenceCipherText
        corruptedCipherText[10] += 1
        let decryptor = AESGCM(key: key)
        do {
            _ = try decryptor.open(cipherText: corruptedCipherText,
                                   nonce: nonce,
                                   additionalAuthenticatedData: aData)
            XCTAssert(false)
        } catch let error {
            XCTAssertEqual(error as? AESGCM.AESGCMError, .validationFailed)
        }
    }

    func testCorruptedNonce() {
        var corruptedNonce = nonce
        corruptedNonce[10] += 1
        let decryptor = AESGCM(key: key)
        do {
            _ = try decryptor.open(cipherText: referenceCipherText,
                                   nonce: corruptedNonce,
                                   additionalAuthenticatedData: aData)
            XCTAssert(false)
        } catch let error {
            XCTAssertEqual(error as? AESGCM.AESGCMError, .validationFailed)
        }
    }

    func testCorruptedAuthenticatedData() {
        var corruptedAuthData = aData
        corruptedAuthData[2] += 1
        let decryptor = AESGCM(key: key)
        do {
            _ = try decryptor.open(cipherText: referenceCipherText,
                                   nonce: nonce,
                                   additionalAuthenticatedData: corruptedAuthData)
            XCTAssert(false)
        } catch let error {
            XCTAssertEqual(error as? AESGCM.AESGCMError, .validationFailed)
        }
    }

}
