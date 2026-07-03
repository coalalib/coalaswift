//
//  CoAPMessageSerializationSpecDummy.swift
//  KeeneticCloudTests
//
//  Created by Evgen on 29/08/2019.
//  Copyright © 2019 Keenetic. All rights reserved.
//

import Foundation
@testable import Coala

enum CoAPMessageSerializationSpecDummy: String, CaseIterable {
  case coapUrl = "CoAPMessageDummyCoapUrl"
  case coapsUrl = "CoAPMessageDummyCoapsUrl"

  case messageIdRegular = "CoAPMessageDummyMessageIdRegular"
  case messageIdMin = "CoAPMessageDummyMessageIdMin"
  case messageIdMax = "CoAPMessageDummyMessageIdMax"

  case absentToken =  "CoAPMessageDummyAbsentToken"
  case existingToken =  "CoAPMessageDummyExistingToken"

  case typeConfirmable = "CoAPMessageDummyTypeConfirmable"
  case typeNonConfirmable = "CoAPMessageDummyTypeNonConfirmable"
  case typeAcknowledgement = "CoAPMessageDummyTypeAcknowledgement"
  case typeReset = "CoAPMessageDummyTypeReset"

  case codeRequestGet = "CoAPMessageDummyCodeRequestGet"
  case codeRequestPost = "CoAPMessageDummyCodeRequestPost"
  case codeRequestPut = "CoAPMessageDummyCodeRequestPut"
  case codeRequestDelete = "CoAPMessageDummyCodeRequestDelete"

  case codeResponseEmpty = "CoAPMessageDummyCodeResponseEmpty"
  case codeResponseCreated = "CoAPMessageDummyCodeResponseCreated"
  case codeResponseDeleted = "CoAPMessageDummyCodeResponseDeleted"
  case codeResponseValid = "CoAPMessageDummyCodeResponseValid"
  case codeResponseChanged = "CoAPMessageDummyCodeResponseChanged"
  case codeResponseContent = "CoAPMessageDummyCodeResponseContent"
  case codeResponseBadRequest = "CoAPMessageDummyCodeResponseBadRequest"
  case codeResponseUnauthorized = "CoAPMessageDummyCodeResponseUnauthorized"
  case codeResponseBadOption = "CoAPMessageDummyCodeResponseBadOption"
  case codeResponseForbidden = "CoAPMessageDummyCodeResponseForbidden"
  case codeResponseNotFound = "CoAPMessageDummyCodeResponseNotFound"
  case codeResponseMethodNotAllowed = "CoAPMessageDummyCodeResponseMethodNotAllowed"
  case codeResponseNotAcceptable = "CoAPMessageDummyCodeResponseNotAcceptable"
  case codeResponsePreconditionFailed = "CoAPMessageDummyCodeResponsePreconditionFailed"
  case codeResponseRequestEntityTooLarge = "CoAPMessageDummyCodeResponseRequestEntityTooLarge"
  case codeResponseUnsupportedContentFormat = "CoAPMessageDummyCodeResponseUnsupportedContentFormat"
  case codeResponseInternalServerError = "CoAPMessageDummyCodeResponseInternalServerError"
  case codeResponseNotImplemented = "CoAPMessageDummyCodeResponseNotImplemented"
  case codeResponseBadGateway = "CoAPMessageDummyCodeResponseBadGateway"
  case codeResponseServiceUnavailable = "CoAPMessageDummyCodeResponseServiceUnavailable"
  case codeResponseGatewayTimeout = "CoAPMessageDummyCodeResponseGatewayTimeout"
  case codeResponseProxyingNotSupported = "CoAPMessageDummyCodeResponseProxyingNotSupported"
  case codeResponseContinued = "CoAPMessageDummyCodeResponseContinued"
  case codeResponseRequestEntityIncomplete = "CoAPMessageDummyCodeResponseRequestEntityIncomplete"
  case codeResponseInvalidCode = "CoAPMessageDummyCodeResponseInvalidCode"

  case optionsAllPossible = "CoAPMessageDummyOptionsAllPossible"
  case optionsRepeatable = "CoAPMessageDummyOptionsRepeatable"
  case optionsNoneRepeatable = "CoAPMessageDummyOptionsNoneRepeatable"
  case optionsIntValue = "CoAPMessageDummyOptionsIntValue"
  case optionsMaxIntValue = "CoAPMessageDummyOptionsMaxIntValue"
  case optionsMinIntValue = "CoAPMessageDummyOptionsMinIntValue"
  case optionsStringValue = "CoAPMessageDummyOptionsStringValue"
  case optionsDataValue = "CoAPMessageDummyOptionsDataValue"

  case payloadData = "CoAPMessageDummyPayloadData"
  case payloadString = "CoAPMessageDummyPayloadString"

  case validCoapVersion = "CoAPMessageDummyValidCoapVersion"
  case invalidCoapVersion = "CoAPMessageDummyInvalidCoapVersion"

  var deserializationOnly: Bool {
    switch self {
    case .existingToken, .codeResponseInvalidCode:
      return true
    default:
      return false
    }
  }

  var serializationFail: Bool {
    switch self {
    case .invalidCoapVersion:
      return true
    default:
      return false
    }
  }

  static var serializableCases: [CoAPMessageSerializationSpecDummy] {
    return CoAPMessageSerializationSpecDummy.allCases.filter({!$0.deserializationOnly && !$0.serializationFail})
  }

  var message: CoAPMessage {
    let defaultMessageId = UInt16.max
    switch self {
    case .coapUrl:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.url = URL(string: "cops://192.168.0.1/info")
      return message
    case .coapsUrl:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.url = URL(string: "coaps://192.168.0.1/info")
      return message
    case .messageIdRegular:
      let expectedMessageId: CoAPMessageId = 3232
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: expectedMessageId)
    case .messageIdMin:
      let expectedMessageId: CoAPMessageId = UInt16.min
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: expectedMessageId)
    case .messageIdMax:
      let expectedMessageId: CoAPMessageId = UInt16.max
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: expectedMessageId)
    case .absentToken:
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
    case .existingToken:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.onResponse = { _ in }
      return message
    case .typeConfirmable:
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
    case .typeNonConfirmable:
      return CoAPMessage(type: .nonConfirmable, code: .request(.get), messageId: defaultMessageId)
    case .typeAcknowledgement:
      return CoAPMessage(type: .acknowledgement, code: .request(.get), messageId: defaultMessageId)
    case .typeReset:
      return CoAPMessage(type: .reset, code: .request(.get), messageId: defaultMessageId)
    case .codeRequestGet:
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
    case .codeRequestPost:
      return CoAPMessage(type: .confirmable, code: .request(.post), messageId: defaultMessageId)
    case .codeRequestPut:
      return CoAPMessage(type: .confirmable, code: .request(.put), messageId: defaultMessageId)
    case .codeRequestDelete:
      return CoAPMessage(type: .confirmable, code: .request(.delete), messageId: defaultMessageId)
    case .codeResponseEmpty:
      return CoAPMessage(type: .confirmable, code: .response(.empty), messageId: defaultMessageId)
    case .codeResponseCreated:
      return CoAPMessage(type: .confirmable, code: .response(.created), messageId: defaultMessageId)
    case .codeResponseDeleted:
      return CoAPMessage(type: .confirmable, code: .response(.deleted), messageId: defaultMessageId)
    case .codeResponseValid:
      return CoAPMessage(type: .confirmable, code: .response(.valid), messageId: defaultMessageId)
    case .codeResponseChanged:
      return CoAPMessage(type: .confirmable, code: .response(.changed), messageId: defaultMessageId)
    case .codeResponseContent:
      return CoAPMessage(type: .confirmable, code: .response(.content), messageId: defaultMessageId)
    case .codeResponseBadRequest:
      return CoAPMessage(type: .confirmable, code: .response(.badRequest), messageId: defaultMessageId)
    case .codeResponseUnauthorized:
      return CoAPMessage(type: .confirmable, code: .response(.unauthorized), messageId: defaultMessageId)
    case .codeResponseBadOption:
      return CoAPMessage(type: .confirmable, code: .response(.badOption), messageId: defaultMessageId)
    case .codeResponseForbidden:
      return CoAPMessage(type: .confirmable, code: .response(.forbidden), messageId: defaultMessageId)
    case .codeResponseNotFound:
      return CoAPMessage(type: .confirmable, code: .response(.notFound), messageId: defaultMessageId)
    case .codeResponseMethodNotAllowed:
      return CoAPMessage(type: .confirmable, code: .response(.methodNotAllowed), messageId: defaultMessageId)
    case .codeResponseNotAcceptable:
      return CoAPMessage(type: .confirmable, code: .response(.notAcceptable), messageId: defaultMessageId)
    case .codeResponsePreconditionFailed:
      return CoAPMessage(type: .confirmable, code: .response(.preconditionFailed), messageId: defaultMessageId)
    case .codeResponseRequestEntityTooLarge:
      return CoAPMessage(type: .confirmable, code: .response(.requestEntityTooLarge), messageId: defaultMessageId)
    case .codeResponseUnsupportedContentFormat:
      return CoAPMessage(type: .confirmable, code: .response(.unsupportedContentFormat), messageId: defaultMessageId)
    case .codeResponseInternalServerError:
      return CoAPMessage(type: .confirmable, code: .response(.internalServerError), messageId: defaultMessageId)
    case .codeResponseNotImplemented:
      return CoAPMessage(type: .confirmable, code: .response(.notImplemented), messageId: defaultMessageId)
    case .codeResponseBadGateway:
      return CoAPMessage(type: .confirmable, code: .response(.badGateway), messageId: defaultMessageId)
    case .codeResponseServiceUnavailable:
      return CoAPMessage(type: .confirmable, code: .response(.serviceUnavailable), messageId: defaultMessageId)
    case .codeResponseGatewayTimeout:
      return CoAPMessage(type: .confirmable, code: .response(.gatewayTimeout), messageId: defaultMessageId)
    case .codeResponseProxyingNotSupported:
      return CoAPMessage(type: .confirmable, code: .response(.proxyingNotSupported), messageId: defaultMessageId)
    case .codeResponseContinued:
      return CoAPMessage(type: .confirmable, code: .response(.continued), messageId: defaultMessageId)
    case .codeResponseRequestEntityIncomplete:
      return CoAPMessage(type: .confirmable, code: .response(.requestEntityIncomplete), messageId: defaultMessageId)
    case .codeResponseInvalidCode:
      // using just for deserialization. Message have to be invalid. This message is superfluous
      return CoAPMessage(type: .confirmable, code: .response(.requestEntityIncomplete), messageId: defaultMessageId)
    case .optionsAllPossible:
      let optionTypes: [CoAPMessageOption.Number] = [.ifMatch,
                                                     .uriHost,
                                                     .eTag,
                                                     .ifNoneMatch,
                                                     .observe,
                                                     .uriPort,
                                                     .locationPath,
                                                     .uriPath,
                                                     .contentFormat,
                                                     .maxAge,
                                                     .uriQuery,
                                                     .accept,
                                                     .locationQuery,
                                                     .block2,
                                                     .block1,
                                                     .proxyUri,
                                                     .proxyScheme,
                                                     .proxySecurityId,
                                                     .size1,
                                                     .uriScheme,
                                                     .handshakeType,
                                                     .sessionNotFound,
                                                     .sessionExpired,
                                                     .coapsUri,
                                                     .selectiveRepeatWindowSize]
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      for optionType in optionTypes {
        message.setOption(optionType, value: "test")
      }
      return message
    case .optionsRepeatable:
      let repeatableOptionTypes: [CoAPMessageOption.Number] = [.ifMatch,
                                                               .eTag,
                                                               .locationPath,
                                                               .uriPath,
                                                               .uriQuery,
                                                               .locationQuery]
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      for repeatableOptionType in repeatableOptionTypes {
        for _ in 0 ..< 2 {
          message.setOption(repeatableOptionType, value: "test")
        }
      }
      return message
    case .optionsNoneRepeatable:
      let noneRepeatableOptionTypes: [CoAPMessageOption.Number] = [.uriHost,
                                                                   .ifNoneMatch,
                                                                   .observe,
                                                                   .uriPort,
                                                                   .contentFormat,
                                                                   .maxAge,
                                                                   .accept,
                                                                   .block2,
                                                                   .block1,
                                                                   .proxyUri,
                                                                   .proxyScheme,
                                                                   .proxySecurityId,
                                                                   .size1,
                                                                   .uriScheme,
                                                                   .handshakeType,
                                                                   .sessionNotFound,
                                                                   .sessionExpired,
                                                                   .coapsUri,
                                                                   .selectiveRepeatWindowSize]
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      for noneRepeatableOptionType in noneRepeatableOptionTypes {
        for _ in 0 ..< 2 {
          message.setOption(noneRepeatableOptionType, value: "test")
        }
      }
      return message
    case .optionsIntValue:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.setOption(.accept, value: 100)
      return message
    case .optionsMaxIntValue:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.setOption(.accept, value: UInt.max)
      return message
    case .optionsMinIntValue:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.setOption(.accept, value: UInt.min)
      return message
    case .optionsStringValue:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.setOption(.accept, value: "test")
      return message
    case .optionsDataValue:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.setOption(.accept, value: "test".data)
      return message
    case .payloadData:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.payload = "test".data
      return message
    case .payloadString:
      var message = CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
      message.payload = "test"
      return message
    case .validCoapVersion:
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
    case .invalidCoapVersion:
      return CoAPMessage(type: .confirmable, code: .request(.get), messageId: defaultMessageId)
    }
  }

  var gaugeData: Data {
    let testsBunlde = Bundle(for: CoAPMessageDummyBundleToken.self)
    if let fileUrl = testsBunlde.url(forResource: self.rawValue, withExtension: ".bin") {
      do {
        return try Data(contentsOf: fileUrl)
      } catch {
        assertionFailure("CoAPMessageSerialization. Can't read dummy data for \(self.rawValue)")
        return Data()
      }
    } else {
      assertionFailure("CoAPMessageSerialization. There is no dummy data for \(self.rawValue)")
      return Data()
    }
  }

}

/// Anchors `Bundle(for:)` to the CoalaTests bundle for loading `.bin` fixtures.
final class CoAPMessageDummyBundleToken {}
