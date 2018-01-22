//
//  CoAPSerializerTests.swift
//  Coala
//
//  Created by Roman on 07/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class CoAPSerializerTests: XCTestCase {

    func testConPostSerialization() {
        let message = CoAPMessage(type: .confirmable, method: .post)
        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testNonGetSerialization() {
        let message = CoAPMessage(type: .nonConfirmable, method: .get)
        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testAckContentSerialization() {
        let message = CoAPMessage(type: .acknowledgement, code: .response(.content))
        guard let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testOptionFieldConversion() {
        for number in [UInt16]([0, 9, 13, 268, 270, 1024, 65535]) {
            let optionField = CoAPSerializer.optionFieldWithValue(number)
            var pos = 0
            let value = try? CoAPSerializer.getOptionFieldValue(optionField.halfByte,
                                                                data: optionField.extendedData,
                                                                pos: &pos)
            XCTAssertEqual(number, value)
        }
    }

    func testLongOptionOverflow() {
        var message = CoAPMessage(type: .nonConfirmable, method: .get)
        let overflowString = String(repeating: "#", count: 65536)
        message.setOption(.contentFormat, value: overflowString)
        do {
            _ = try CoAPSerializer.dataWithCoAPMessage(message)
        } catch let error {
            let serializationError = error as? CoAPSerializer.SerializationError
            XCTAssertEqual(serializationError, .optionValueTooLong)
            return
        }
        XCTAssert(false)
    }

    func testUrlSerialization() {
        let url = URL(string: "coap://10.70.10.70:5544/method?query=2")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            var deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        deserializedMessage.address = message.address
        XCTAssertEqual(message.type, deserializedMessage.type)
        XCTAssertEqual(message.code, deserializedMessage.code)
        XCTAssertEqual(message.messageId, deserializedMessage.messageId)
        XCTAssertEqual(message.token, deserializedMessage.token)
        XCTAssertEqual(message.url, deserializedMessage.url)
    }

    func testUrlQuerySerialization() {
        let url = URL(string: "coap://10.70.10.70:5544/method/submethod?query1=2&query2=abc")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            var deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        deserializedMessage.address = message.address
        XCTAssertEqual(message.url, deserializedMessage.url)
        XCTAssertEqual(deserializedMessage.getOptions(.uriPath).count, 2)
        XCTAssertEqual(deserializedMessage.getOptions(.uriPath)[0].data.string, "method")
        XCTAssertEqual(deserializedMessage.getOptions(.uriPath)[1].data.string, "submethod")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery).count, 2)
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[0].data.string, "query1=2")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[1].data.string, "query2=abc")
    }

    func testToken() {
        let url = URL(string: "coap://10.70.10.70:5544/method?query=2")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        message.token = CoAPToken(value: "123".data)
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            let deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        XCTAssertEqual(message.token, deserializedMessage.token)
    }

    func testTooLongToken() {
        let url = URL(string: "coap://10.70.10.70:5544/method?query=2")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        message.token = CoAPToken(value: "veryverylongtoken".data)
        do {
            _ = try CoAPSerializer.dataWithCoAPMessage(message)
        } catch let error {
            let serializeError = error as? CoAPSerializer.SerializationError
            XCTAssertEqual(serializeError, .wrongTokenLength)
            return
        }
        XCTAssert(false)
    }

    func testSpecialChars() {
        let url = URL(string: "coap://10.70.10.70:5544/method/submethod")
        var message = CoAPMessage(type: .reset, method: .delete, url: url)
        message.query = [
            URLQueryItem(name: "at", value: "@"),
            URLQueryItem(name: "quest", value: "?"),
            URLQueryItem(name: "amp", value: "&"),
            URLQueryItem(name: "perc", value: "%")
        ]
        guard url != nil,
            let serializedData = try? CoAPSerializer.dataWithCoAPMessage(message),
            var deserializedMessage = try? CoAPSerializer.coapMessageWithData(serializedData)
            else {
                XCTAssert(false)
                return
        }
        deserializedMessage.address = message.address
        let expectedURL = "coap://10.70.10.70:5544/method/submethod?at=@&quest=?&amp=%26&perc=%25"
        XCTAssertEqual(message.url?.absoluteString, expectedURL)
        XCTAssertEqual(message.url, deserializedMessage.url)
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery).count, 4)
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[0].data.string, "at=@")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[1].data.string, "quest=?")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[2].data.string, "amp=&")
        XCTAssertEqual(deserializedMessage.getOptions(.uriQuery)[3].data.string, "perc=%")
    }
}
