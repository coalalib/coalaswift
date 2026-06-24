import XCTest
@testable import Coala

final class CoAPTcpSerializerTests: XCTestCase {

    func testSingleFrameRoundTrips() {
        let serializer = CoAPTcpSerializer()
        let address = Address(host: "10.0.0.1", port: 5683)
        let payload = Data([0x40, 0x01, 0x00, 0x01, 0xAA, 0xBB])
        let encoded = serializer.encodeTcpFrame(with: address, data: payload)
        let frames = serializer.decodeTcpFrame(with: encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, payload)
        XCTAssertEqual(frames.first?.address.host, "10.0.0.1")
        XCTAssertEqual(frames.first?.address.port, 5683)
    }

    func testFrameSplitAcrossTwoChunksReassembles() {
        let serializer = CoAPTcpSerializer()
        let address = Address(host: "10.0.0.2", port: 1234)
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let encoded = serializer.encodeTcpFrame(with: address, data: payload)
        let firstChunk = Data(encoded.prefix(4))
        let secondChunk = Data(encoded.suffix(from: 4))
        XCTAssertEqual(serializer.decodeTcpFrame(with: firstChunk).count, 0)
        let frames = serializer.decodeTcpFrame(with: secondChunk)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.data, payload)
    }
}
