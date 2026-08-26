import Foundation
import Testing
@testable import Coala

/// Frame format: M(1B, 77) | IPv4(4B) | port(2B) | size(2B) | payload(size B)
@Suite("CoAP TCP frame serialization")
struct CoAPTcpSerializerFramingTests {

  @Test("encoded frame layout is delimiter | IPv4 | port | size | payload")
  func encodedFrameLayout() throws {
    let payload = Data([0xAA, 0xBB, 0xCC])
    let encoded = try CoAPTcpSerializer().encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    // 5683 == 0x1633, size 3 == 0x0003, both big-endian on the wire
    #expect(encoded == Data([77, 10, 0, 0, 1, 0x16, 0x33, 0x00, 0x03]) + payload)
  }

  @Test("a single frame round-trips through encode and decode")
  func singleFrameRoundTrip() throws {
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x40, 0x01, 0x30, 0x39, 0xFF, 0xAA])
    let address = Address(host: "192.168.1.42", port: 16333)
    let frames = serializer.decodeTcpFrame(
      with: try serializer.encodeTcpFrame(with: address, data: payload))
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
    #expect(frames.first?.address == address)
  }

  @Test("two frames in one chunk decode to two messages in order")
  func twoFramesInOneChunk() throws {
    let serializer = CoAPTcpSerializer()
    let first = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 1111), data: Data([0x01]))
    let second = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.2", port: 2222), data: Data([0x02, 0x03]))
    let frames = serializer.decodeTcpFrame(with: first + second)
    #expect(frames.count == 2)
    #expect(frames.first?.data == Data([0x01]))
    #expect(frames.first?.address == Address(host: "10.0.0.1", port: 1111))
    #expect(frames.last?.data == Data([0x02, 0x03]))
    #expect(frames.last?.address == Address(host: "10.0.0.2", port: 2222))
  }

  @Test("a frame split across three feeds is reassembled on the last feed")
  func frameSplitAcrossThreeFeeds() throws {
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x0A, 0x0B, 0x0C, 0x0D])
    let encoded = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    #expect(serializer.decodeTcpFrame(with: Data(encoded.prefix(2))).isEmpty)
    #expect(serializer.decodeTcpFrame(with: Data(encoded.dropFirst(2).prefix(4))).isEmpty)
    let frames = serializer.decodeTcpFrame(with: Data(encoded.dropFirst(6)))
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
  }

  @Test("a complete frame is delivered and the trailing partial one is kept for the next feed")
  func trailingPartialFrameRetained() throws {
    let serializer = CoAPTcpSerializer()
    let firstPayload = Data([0x11, 0x22])
    let secondPayload = Data([0x33, 0x44, 0x55])
    let first = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 1111), data: firstPayload)
    let second = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.2", port: 2222), data: secondPayload)

    let firstBatch = serializer.decodeTcpFrame(with: first + second.prefix(5))
    #expect(firstBatch.count == 1)
    #expect(firstBatch.first?.data == firstPayload)

    let secondBatch = serializer.decodeTcpFrame(with: Data(second.dropFirst(5)))
    #expect(secondBatch.count == 1)
    #expect(secondBatch.first?.data == secondPayload)
    #expect(secondBatch.first?.address == Address(host: "10.0.0.2", port: 2222))
  }

  @Test("flushBuffer discards a partially buffered frame")
  func flushBufferDiscardsPartialState() throws {
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x66, 0x77])
    let encoded = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    #expect(serializer.decodeTcpFrame(with: Data(encoded.prefix(4))).isEmpty)
    serializer.flushBuffer()
    // Without the flush the stale prefix would corrupt this frame.
    let frames = serializer.decodeTcpFrame(with: encoded)
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
  }

  @Test("a leading non-delimiter byte is skipped and the next frame decodes")
  func recoversFromLeadingGarbageByte() throws {
    let serializer = CoAPTcpSerializer()
    let valid = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: Data([0x01, 0x02]))
    let frames = serializer.decodeTcpFrame(with: Data([0x00]) + valid)
    #expect(frames.count == 1)
    #expect(frames.first?.data == Data([0x01, 0x02]))
    #expect(frames.first?.address == Address(host: "10.0.0.1", port: 5683))
  }

  @Test("garbage bytes with no delimiter are dropped so a later frame decodes")
  func recoversAfterGarbageOnlyChunk() throws {
    let serializer = CoAPTcpSerializer()
    let valid = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.2", port: 2222), data: Data([0x09]))
    #expect(serializer.decodeTcpFrame(with: Data([0x00, 0x01, 0x02])).isEmpty)
    let frames = serializer.decodeTcpFrame(with: valid)
    #expect(frames.count == 1)
    #expect(frames.first?.data == Data([0x09]))
  }

  @Test("a non-IPv4 host is rejected rather than encoded as 0.0.0.0")
  func nonIPv4HostIsRejected() throws {
    // A non-dotted-quad host cannot be represented in the 4-byte IPv4 field.
    // Encoding 0.0.0.0 kept the stream aligned but had the proxy forward the
    // datagram nowhere, silently. Throwing emits no bytes at all, so alignment
    // is preserved for the stronger reason and the caller learns of the failure.
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])

    #expect(throws: CoalaError.self) {
      try serializer.encodeTcpFrame(with: Address(host: "localhost", port: 5683), data: payload)
    }

    // Nothing was buffered by the failed encode, so a subsequent valid frame
    // still decodes cleanly.
    let valid = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    let frames = serializer.decodeTcpFrame(with: valid)
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
  }

  @Test("a payload larger than the 16-bit size field is rejected, not truncated")
  func oversizedPayloadIsRejected() {
    let serializer = CoAPTcpSerializer()
    #expect(throws: CoalaError.self) {
      try serializer.encodeTcpFrame(
        with: Address(host: "10.0.0.1", port: 5683), data: Data(count: Int(UInt16.max) + 1))
    }
  }

  @Test("a payload exactly at the 16-bit limit still encodes")
  func maximumSizedPayloadEncodes() throws {
    let serializer = CoAPTcpSerializer()
    let payload = Data(count: Int(UInt16.max))
    let encoded = try serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    #expect(encoded.count == 9 + Int(UInt16.max))
    let frames = serializer.decodeTcpFrame(with: encoded)
    #expect(frames.count == 1)
    #expect(frames.first?.data.count == Int(UInt16.max))
  }
}
