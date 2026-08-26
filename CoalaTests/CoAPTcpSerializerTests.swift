import XCTest
@testable import Coala

final class CoAPTcpSerializerTests: XCTestCase {

    func testSingleFrameRoundTrips() throws {
        let serializer = CoAPTcpSerializer()
        let address = Address(host: "10.0.0.1", port: 5683)
        let payload = Data([0x40, 0x01, 0x00, 0x01, 0xAA, 0xBB])
        let encoded = try serializer.encodeTcpFrame(with: address, data: payload)
        let frames = serializer.decodeTcpFrame(with: encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, payload)
        XCTAssertEqual(frames.first?.address.host, "10.0.0.1")
        XCTAssertEqual(frames.first?.address.port, 5683)
    }

    /// The frame's size field is 16 bits, so `UInt16(data.count)` traps above
    /// 65535 — a hard crash. On UDP the same oversized message fails soft at the
    /// socket with EMSGSIZE and is merely dropped, so switching transport must
    /// not upgrade a dropped packet into a process kill.
    func testEncodeThrowsWhenPayloadExceedsFrameSizeField() {
        let serializer = CoAPTcpSerializer()
        let address = Address(host: "10.0.0.1", port: 5683)
        let oversized = Data(count: Int(UInt16.max) + 1)

        XCTAssertThrowsError(try serializer.encodeTcpFrame(with: address, data: oversized)) { error in
            guard case CoalaError.tcpFrameTooLarge = error else {
                return XCTFail("expected .tcpFrameTooLarge, got \(error)")
            }
        }
    }

    /// A host that is not a dotted quad cannot be represented in the fixed 4-byte
    /// IPv4 field. Silently encoding 0.0.0.0 makes the proxy forward the datagram
    /// nowhere; the caller should learn the send is impossible instead.
    func testEncodeThrowsForNonIPv4Destination() {
        let serializer = CoAPTcpSerializer()
        let address = Address(host: "localhost", port: 5683)

        XCTAssertThrowsError(try serializer.encodeTcpFrame(with: address, data: Data([0x01]))) { error in
            guard case CoalaError.tcpDestinationNotIPv4 = error else {
                return XCTFail("expected .tcpDestinationNotIPv4, got \(error)")
            }
        }
    }

    func testFrameSplitAcrossTwoChunksReassembles() throws {
        let serializer = CoAPTcpSerializer()
        let address = Address(host: "10.0.0.2", port: 1234)
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let encoded = try serializer.encodeTcpFrame(with: address, data: payload)
        let firstChunk = Data(encoded.prefix(4))
        let secondChunk = Data(encoded.suffix(from: 4))
        XCTAssertEqual(serializer.decodeTcpFrame(with: firstChunk).count, 0)
        let frames = serializer.decodeTcpFrame(with: secondChunk)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, payload)
    }
}
