import Foundation
import Testing
@testable import Coala

/// Frame format: M(1B, 77) | IPv4(4B) | port(2B) | size(2B) | payload(size B)
@Suite("CoAP TCP frame serialization")
struct CoAPTcpSerializerFramingTests {

  @Test("encoded frame layout is delimiter | IPv4 | port | size | payload")
  func encodedFrameLayout() {
    let payload = Data([0xAA, 0xBB, 0xCC])
    let encoded = CoAPTcpSerializer().encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    // 5683 == 0x1633, size 3 == 0x0003, both big-endian on the wire
    #expect(encoded == Data([77, 10, 0, 0, 1, 0x16, 0x33, 0x00, 0x03]) + payload)
  }

  @Test("a single frame round-trips through encode and decode")
  func singleFrameRoundTrip() {
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x40, 0x01, 0x30, 0x39, 0xFF, 0xAA])
    let address = Address(host: "192.168.1.42", port: 16333)
    let frames = serializer.decodeTcpFrame(
      with: serializer.encodeTcpFrame(with: address, data: payload))
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
    #expect(frames.first?.address == address)
  }

  @Test("two frames in one chunk decode to two messages in order")
  func twoFramesInOneChunk() {
    let serializer = CoAPTcpSerializer()
    let first = serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 1111), data: Data([0x01]))
    let second = serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.2", port: 2222), data: Data([0x02, 0x03]))
    let frames = serializer.decodeTcpFrame(with: first + second)
    #expect(frames.count == 2)
    #expect(frames.first?.data == Data([0x01]))
    #expect(frames.first?.address == Address(host: "10.0.0.1", port: 1111))
    #expect(frames.last?.data == Data([0x02, 0x03]))
    #expect(frames.last?.address == Address(host: "10.0.0.2", port: 2222))
  }

  @Test("a frame split across three feeds is reassembled on the last feed")
  func frameSplitAcrossThreeFeeds() {
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x0A, 0x0B, 0x0C, 0x0D])
    let encoded = serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    #expect(serializer.decodeTcpFrame(with: Data(encoded.prefix(2))).isEmpty)
    #expect(serializer.decodeTcpFrame(with: Data(encoded.dropFirst(2).prefix(4))).isEmpty)
    let frames = serializer.decodeTcpFrame(with: Data(encoded.dropFirst(6)))
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
  }

  @Test("a complete frame is delivered and the trailing partial one is kept for the next feed")
  func trailingPartialFrameRetained() {
    let serializer = CoAPTcpSerializer()
    let firstPayload = Data([0x11, 0x22])
    let secondPayload = Data([0x33, 0x44, 0x55])
    let first = serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 1111), data: firstPayload)
    let second = serializer.encodeTcpFrame(
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
  func flushBufferDiscardsPartialState() {
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x66, 0x77])
    let encoded = serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: payload)
    #expect(serializer.decodeTcpFrame(with: Data(encoded.prefix(4))).isEmpty)
    serializer.flushBuffer()
    // Without the flush the stale prefix would corrupt this frame.
    let frames = serializer.decodeTcpFrame(with: encoded)
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
  }

  @Test("a leading non-delimiter byte is skipped and the next frame decodes")
  func recoversFromLeadingGarbageByte() {
    let serializer = CoAPTcpSerializer()
    let valid = serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.1", port: 5683), data: Data([0x01, 0x02]))
    let frames = serializer.decodeTcpFrame(with: Data([0x00]) + valid)
    #expect(frames.count == 1)
    #expect(frames.first?.data == Data([0x01, 0x02]))
    #expect(frames.first?.address == Address(host: "10.0.0.1", port: 5683))
  }

  @Test("garbage bytes with no delimiter are dropped so a later frame decodes")
  func recoversAfterGarbageOnlyChunk() {
    let serializer = CoAPTcpSerializer()
    let valid = serializer.encodeTcpFrame(
      with: Address(host: "10.0.0.2", port: 2222), data: Data([0x09]))
    #expect(serializer.decodeTcpFrame(with: Data([0x00, 0x01, 0x02])).isEmpty)
    let frames = serializer.decodeTcpFrame(with: valid)
    #expect(frames.count == 1)
    #expect(frames.first?.data == Data([0x09]))
  }

  @Test("a non-IPv4 host still produces a structurally valid, decodable frame")
  func nonIPv4HostProducesValidFrame() {
    // A non-dotted-quad host cannot be represented in the 4-byte IPv4 field,
    // but the frame must stay structurally intact (4 IP bytes) so it decodes
    // and the stream does not desync; the address degrades to 0.0.0.0.
    let serializer = CoAPTcpSerializer()
    let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    let encoded = serializer.encodeTcpFrame(
      with: Address(host: "localhost", port: 5683), data: payload)
    #expect(encoded.count == 1 + 4 + 2 + 2 + 6) // IPv4 field is always 4 bytes
    let frames = serializer.decodeTcpFrame(with: encoded)
    #expect(frames.count == 1)
    #expect(frames.first?.data == payload)
    #expect(frames.first?.address.port == 5683)
  }
}
