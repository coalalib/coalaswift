/// TCP frame format for proxying
///    M - 1B
///    IP - 4B
///    PORT - 2B
///    SIZE - 2B
///    MESSAGE - SIZE B

final class CoAPTcpSerializer {

    struct Frame {
        let address: Address
        let data: Data
    }

    private let delimeterByte: [UInt8] = [77]
    private var buffer = Data()

    public func encodeTcpFrame(with address: Address, data: Data) -> Data {
        let delimeterData = Data(delimeterByte)
        // The IPv4 field is a fixed 4 bytes. A host that is not a dotted quad
        // (e.g. "localhost") cannot be represented, so fall back to 0.0.0.0
        // rather than emitting a short header that desyncs the decoder.
        let octets = address.host.split(separator: ".").compactMap { UInt8($0) }
        let ipData = Data(octets.count == 4 ? octets : [0, 0, 0, 0])
        let portData = Data(UInt16(address.port).byteArrayLittleEndian)
        let sizeData = Data(UInt16(data.count).byteArrayLittleEndian)
        let passedData = delimeterData + ipData + portData + sizeData + data
        return passedData
    }

    public func decodeTcpFrame(with data: Data) -> [Frame] {
        buffer.append(data)

        var frames = [Frame]()

        while !buffer.isEmpty {
            // Resync: if the stream is misaligned (corruption or a dropped byte),
            // drop leading bytes up to the next delimiter instead of stalling the
            // buffer forever. A buffer with no delimiter at all is pure garbage.
            guard let delimiterIndex = buffer.firstIndex(of: delimeterByte[0]) else {
                buffer.removeAll()
                return frames
            }
            if delimiterIndex != 0 {
                buffer.removeSubrange(0..<delimiterIndex)
            }

            var pos = 1 // consume the delimiter byte
            guard let ipBytes = buffer.readBytesIfPossible(pos: &pos, length: 4),
                  let portBytes = buffer.readBytesIfPossible(pos: &pos, length: 2),
                  let sizeBytes = buffer.readBytesIfPossible(pos: &pos, length: 2)
            else {
                return frames
            }

            let port: UInt16 = portBytes.withUnsafeBytes { $0.load(as: UInt16.self) }.byteSwapped
            let size: UInt16 = sizeBytes.withUnsafeBytes { $0.load(as: UInt16.self) }.byteSwapped
            let length = Int(size)

            guard buffer.count >= length + pos else { return frames }
            let coapData = buffer.readDataAt(&pos, length: length)

            let addressString = ipBytes.map { String($0) }.joined(separator: ".")
            let address = Address(host: addressString, port: port)

            frames.append(.init(address: address, data: coapData))
            buffer.removeSubrange(0..<pos)
        }
        return frames
    }

    public func flushBuffer() {
        buffer.removeAll()
    }
}

private extension UInt16 {
    var byteArrayLittleEndian: [UInt8] {
        return [
            UInt8((self & 0xFF00) >> 8),
            UInt8(self & 0x00FF)
        ]
    }
}
