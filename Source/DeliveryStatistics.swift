public struct DeliveryStatistics {
    public let scheme: CoAPMessage.Scheme
    public let address: Address
    public var direct: Counters
    public var proxy: Counters
}

extension DeliveryStatistics {
    public struct Counters {
        public var totalCount: Int
        public var retransmitsCount: Int
    }
}
