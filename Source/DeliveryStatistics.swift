public struct DeliveryStatistics {
    public let scheme: CoAPMessage.Scheme
    public let address: Address
    public var direct: Counters
    public var proxy: Counters

    public init(scheme: CoAPMessage.Scheme, address: Address, direct: Counters, proxy: Counters) {
        self.scheme = scheme
        self.address = address
        self.direct = direct
        self.proxy = proxy
    }
}

extension DeliveryStatistics {
    public struct Counters {
        public var totalCount: Int
        public var retransmitsCount: Int

        public init(totalCount: Int, retransmitsCount: Int) {
            self.totalCount = totalCount
            self.retransmitsCount = retransmitsCount
        }
    }
}
