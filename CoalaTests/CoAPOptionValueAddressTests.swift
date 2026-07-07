import Foundation
import Testing
@testable import Coala

@Suite("CoAP option values and addresses")
struct CoAPOptionValueAddressTests {

  // MARK: - UInt <-> Data option coding

  @Test("UInt round-trips through big-endian data with leading zeros stripped", arguments: [
    (UInt(0), Data()),
    (UInt(1), Data([1])),
    (UInt(256), Data([1, 0])),
    (UInt.max, Data(repeating: 0xFF, count: MemoryLayout<UInt>.size)),
  ])
  func uintDataRoundTrip(value: UInt, data: Data) {
    #expect(value.data == data)
    #expect(UInt(data: data) == value)
  }

  @Test("data longer than UInt yields the UInt.max sentinel")
  func oversizedDataYieldsSentinel() {
    #expect(UInt(data: Data(repeating: 0, count: MemoryLayout<UInt>.size + 1)) == UInt.max)
  }

  // MARK: - Critical options

  @Test("odd option numbers are critical, even ones are elective", arguments: [
    (CoAPMessageOption.Number.uriHost, true),
    (.eTag, false),
    (.uriPath, true),
    (.contentFormat, false),
  ])
  func criticalOptionNumbers(number: CoAPMessageOption.Number, expected: Bool) {
    #expect(CoAPMessageOption(number: number, value: 0).critical == expected)
  }

  // MARK: - Address

  @Test("Address(string:) parses host:port")
  func addressFromString() {
    let address = Address(string: "h:5683")
    #expect(address?.host == "h")
    #expect(address?.port == 5683)
  }

  // "::1:5683" locks in the current limitation: IPv6 literals are unsupported.
  @Test("malformed address strings yield nil", arguments: [
    "h", "h:x", "h:70000", "::1:5683",
  ])
  func malformedAddressStrings(string: String) {
    #expect(Address(string: string) == nil)
  }

  @Test("Address(url:) requires an explicit port")
  func addressFromUrlRequiresExplicitPort() {
    #expect(Address(url: URL(string: "coap://h.com/a")) == nil)
    #expect(Address(url: URL(string: "coap://h.com:1234/a")) == Address(host: "h.com", port: 1234))
  }
}
