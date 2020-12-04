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
        let ipData = Data(address.host.split(separator: ".").compactMap { UInt8($0) })
        let portData = Data(UInt16(address.port).byteArrayLittleEndian)
        let sizeData = Data(UInt16(data.count).byteArrayLittleEndian)
        let passedData = delimeterData + ipData + portData + sizeData + data
        return passedData
    }

    public func decodeTcpFrame(with data: Data) -> [Frame] {
        buffer.append(data)

        var frames = [Frame]()
        var pos = 0

        while !buffer.isEmpty && buffer.readBytesAt(&pos, length: 1) == delimeterByte {
            let ip = buffer.readBytesAt(&pos, length: 4)
            let portData = buffer.readBytesAt(&pos, length: 2)
            let sizeData = buffer.readBytesAt(&pos, length: 2)

            let port: UInt16 = portData.withUnsafeBytes { $0.load(as: UInt16.self) }.byteSwapped
            let size: UInt16 = sizeData.withUnsafeBytes { $0.load(as: UInt16.self) }.byteSwapped
            let length = Int(size)

            guard buffer.count > length + pos else { return frames }
            let coapData = buffer.readDataAt(&pos, length: length)

            let addressString = ip.map { String($0) }.joined(separator: ".")
            let address = Address(host: addressString, port: port)

            frames.append(.init(address: address, data: coapData))
            buffer.removeSubrange(0..<pos)

            pos = 0
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
