import Foundation
import Testing
@testable import Coala

@Suite("CoAP registry codes")
struct CoAPCodeTests {

  static let allMethods: [CoAPMessage.Method] = [.get, .post, .put, .delete]

  static let allResponseCodes: [CoAPMessage.ResponseCode] = [
    .empty, .created, .deleted, .valid, .changed, .content,
    .badRequest, .unauthorized, .badOption, .forbidden, .notFound,
    .methodNotAllowed, .notAcceptable, .preconditionFailed,
    .requestEntityTooLarge, .unsupportedContentFormat,
    .internalServerError, .notImplemented, .badGateway,
    .serviceUnavailable, .gatewayTimeout, .proxyingNotSupported,
    .continued, .requestEntityIncomplete,
  ]

  @Test("4.15 packs into 0x8F (3-bit major, 5-bit minor)")
  func unsupportedContentFormatPacksInto0x8F() {
    #expect(CoAPMessage.ResponseCode.unsupportedContentFormat.rawValue.integerValue == 0x8F)
  }

  @Test("method codes round-trip through integerValue", arguments: Self.allMethods)
  func methodRoundTrip(method: CoAPMessage.Method) {
    let integer = method.rawValue.integerValue
    #expect(CoAPRegistryCode(integerValue: integer) == method.rawValue)
    #expect(CoAPMessage.Code(rawValue: integer) == .request(method))
  }

  @Test("response codes round-trip through integerValue", arguments: Self.allResponseCodes)
  func responseCodeRoundTrip(code: CoAPMessage.ResponseCode) {
    let integer = code.rawValue.integerValue
    #expect(CoAPRegistryCode(integerValue: integer) == code.rawValue)
    #expect(CoAPMessage.Code(rawValue: integer) == .response(code))
  }

  @Test("an unassigned code byte yields a nil Code")
  func unassignedCodeByteYieldsNil() {
    #expect(CoAPMessage.Code(rawValue: 0xFF) == nil)
  }

  @Test("registry code description formats as major.two-digit-minor")
  func registryCodeDescription() {
    #expect(CoAPMessage.ResponseCode.methodNotAllowed.rawValue.description == "4.05")
    #expect(CoAPMessage.Method.get.rawValue.description == "0.01")
    // Code.description interpolates minor without the zero padding
    // that CoAPRegistryCode.description applies.
    #expect("\(CoAPMessage.Code.response(.methodNotAllowed))" == "4.5 methodNotAllowed")
  }

  @Test("isError is true starting from the 4.xx class", arguments: [
    (CoAPMessage.ResponseCode.content, false),
    (.continued, false),
    (.badRequest, true),
    (.internalServerError, true),
  ])
  func isErrorBoundary(code: CoAPMessage.ResponseCode, expected: Bool) {
    #expect(code.isError == expected)
  }
}
