import Foundation
import Testing
@testable import Coala

// RFC: https://tools.ietf.org/html/rfc7252#section-3

@Suite("CoAP message serialization")
struct CoAPMessageSerializationTests {

  typealias Dummy = CoAPMessageSerializationSpecDummy

  // MARK: - Deserialization: URL scheme

  @Test("wrong-scheme url deserializes to the coap scheme")
  func wrongUrlScheme() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.coapUrl.gaugeData)
    #expect(message.scheme == .coap)
  }

  @Test("coaps url deserializes to the coapSecure scheme")
  func coapsUrlScheme() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.coapsUrl.gaugeData)
    #expect(message.scheme == .coapSecure)
  }

  // MARK: - Deserialization: message id

  @Test("message id is decoded from raw header bytes")
  func messageIdFromRawBytes() {
    let bytes: [UInt8] = [12, 12, 12, 12, 12]
    let decodedMessageId = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    #expect(decodedMessageId == 3084)
  }

  @Test("message id boundary values round-trip", arguments: [
    (Dummy.messageIdRegular, CoAPMessageId(3232)),
    (Dummy.messageIdMin, CoAPMessageId(UInt16.min)),
    (Dummy.messageIdMax, CoAPMessageId(UInt16.max)),
  ])
  func messageId(dummy: Dummy, expected: CoAPMessageId) throws {
    let message = try CoAPSerializer.coapMessageWithData(dummy.gaugeData)
    #expect(message.messageId == expected)
  }

  // MARK: - Deserialization: token

  @Test("a message without a token deserializes to a nil token")
  func absentToken() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.absentToken.gaugeData)
    #expect(message.token == nil)
  }

  @Test("a message with a token deserializes to a non-nil token")
  func existingToken() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.existingToken.gaugeData)
    #expect(message.token != nil)
  }

  // MARK: - Deserialization: type (was sharedExamples "coap message with type")

  @Test("message type round-trips through deserialization", arguments: [
    Dummy.typeConfirmable, .typeNonConfirmable, .typeAcknowledgement, .typeReset,
  ])
  func messageType(dummy: Dummy) throws {
    let message = try CoAPSerializer.coapMessageWithData(dummy.gaugeData)
    #expect(message.type == dummy.message.type)
  }

  // MARK: - Deserialization: code (was sharedExamples "coap message with code")

  @Test("message code round-trips through deserialization", arguments: [
    Dummy.codeRequestGet, .codeRequestPost, .codeRequestPut, .codeRequestDelete,
    .codeResponseEmpty, .codeResponseCreated, .codeResponseDeleted, .codeResponseValid,
    .codeResponseChanged, .codeResponseContent, .codeResponseBadRequest, .codeResponseUnauthorized,
    .codeResponseBadOption, .codeResponseForbidden, .codeResponseNotFound, .codeResponseMethodNotAllowed,
    .codeResponseNotAcceptable, .codeResponsePreconditionFailed, .codeResponseRequestEntityTooLarge,
    .codeResponseUnsupportedContentFormat, .codeResponseInternalServerError, .codeResponseNotImplemented,
    .codeResponseBadGateway, .codeResponseServiceUnavailable, .codeResponseGatewayTimeout,
    .codeResponseProxyingNotSupported, .codeResponseContinued, .codeResponseRequestEntityIncomplete,
  ])
  func messageCode(dummy: Dummy) throws {
    let message = try CoAPSerializer.coapMessageWithData(dummy.gaugeData)
    #expect(message.code == dummy.message.code)
  }

  // MARK: - Deserialization: options

  @Test("all option types deserialize")
  func allOptionTypes() throws {
    let dummy = Dummy.optionsAllPossible
    let message = try CoAPSerializer.coapMessageWithData(dummy.gaugeData)
    #expect(message.options.count == dummy.message.options.count)
  }

  @Test("integer option value deserializes", arguments: [
    (Dummy.optionsIntValue, UInt(100)),
    (Dummy.optionsMaxIntValue, UInt.max),
    (Dummy.optionsMinIntValue, UInt.min),
  ])
  func integerOption(dummy: Dummy, value: UInt) throws {
    let message = try CoAPSerializer.coapMessageWithData(dummy.gaugeData)
    #expect(message.getIntegerOptions(.accept).first == value)
  }

  @Test("string option value deserializes")
  func stringOption() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.optionsStringValue.gaugeData)
    #expect(message.getStringOptions(.accept).first == "test")
  }

  @Test("opaque (data) option value deserializes")
  func dataOption() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.optionsDataValue.gaugeData)
    #expect(message.getOpaqueOptions(.accept).first == "test".data)
  }

  // MARK: - Deserialization: payload

  @Test("data payload deserializes")
  func dataPayload() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.payloadData.gaugeData)
    #expect(message.payload?.data == "test".data)
  }

  @Test("string payload deserializes")
  func stringPayload() throws {
    let message = try CoAPSerializer.coapMessageWithData(Dummy.payloadString.gaugeData)
    #expect(message.payload?.string == "test")
  }

  // MARK: - Deserialization: errors

  @Test("a too-short message throws headerTooShort")
  func shortMessageThrows() {
    #expect {
      _ = try CoAPSerializer.coapMessageWithData("0".data)
    } throws: { error in
      guard let error = error as? CoAPSerializer.DeserializationError else { return false }
      if case .headerTooShort = error { return true }
      return false
    }
  }

  @Test("a message with an unknown code throws unknownCode")
  func unknownCodeThrows() {
    #expect {
      _ = try CoAPSerializer.coapMessageWithData(Dummy.codeResponseInvalidCode.gaugeData)
    } throws: { error in
      guard let error = error as? CoAPSerializer.DeserializationError else { return false }
      if case .unknownCode = error { return true }
      return false
    }
  }

  // MARK: - Serialization

  @Test("serializable messages serialize to their gauge data",
        arguments: CoAPMessageSerializationSpecDummy.serializableCases)
  func serialization(dummy: Dummy) throws {
    let checkData = try CoAPSerializer.dataWithCoAPMessage(dummy.message)
    #expect(checkData == dummy.gaugeData)
  }

  @Test("an invalid CoAP version does not match the gauge data")
  func invalidVersionDoesNotMatch() throws {
    let dummy = Dummy.invalidCoapVersion
    let checkData = try CoAPSerializer.dataWithCoAPMessage(dummy.message)
    #expect(checkData != dummy.gaugeData)
  }
}
