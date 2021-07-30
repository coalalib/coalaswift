//
//  CoAPMessage.swift
//  Coala
//
//  Created by Roman on 06/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

/// CoAP message ID is used to detect duplicates and for optional reliability
/// See more in [CoAP RFC](https://tools.ietf.org/html/rfc7252)
public typealias CoAPMessageId = UInt16

/// CoAPMessage represents a message in [CoAP](https://tools.ietf.org/html/rfc7252#section-2.1)
public struct CoAPMessage {

    /// Reliability of message delivery
    public let type: Reliability

    /// In case of a request indicates the Request `Method`;
    /// in case of a response, a `ResponseCode`
    public var code: Code

    /// CoAP message ID is used to detect duplicates and for optional reliability
    public let messageId: CoAPMessageId

    /// Closure to be called when response is received to the message
    public var onResponse: Coala.ResponseHandler? {
        didSet {
            if token == nil {
                token = CoAPToken.generate()
            }
        }
    }

    /// Data payload delivered in a message.
    /// It is protected by encryption when used with `coaps://` scheme
    public var payload: CoAPMessagePayload?

    var token: CoAPToken?
    var options = [CoAPMessageOption]()
    var address: Address?

    /// URL scheme for message delivery. Use .CoAPSecure scheme to enable encryption
    public var scheme: Scheme {
        get {
            guard
                let rawScheme = getStringOptions(.uriScheme).first?.data,
                let scheme = Scheme(rawValue: Int(data: rawScheme))
            else { return .coap }
            return scheme
        }
        set {
            removeOption(.uriScheme)
            guard newValue != .coap else { return }
            setOption(.uriScheme, value: newValue.rawValue)
        }
    }

    /**
     Initializes a new CoAP message.

     - parameter type: Confirmable, Non-confirmable, Acknowledgement, or Reset message
     - parameter code: CoAP message code
     - parameter messageId: CoAP message ID (optional)

     - returns: A ready to be sent CoAP message.
     */
    public init(type: Reliability, code: Code, messageId: UInt16 = CoAPMessage.randomMessageId()) {
        self.type = type
        self.code = code
        self.messageId = messageId
    }

    /**
     Initializes a new CoAP request message with destination URL.

     - parameter type: Confirmable, Non-confirmable, Acknowledgement, or Reset message
     - parameter method: CoAP request method
     - parameter url: Destination URL (optional)

     - returns: A ready to be sent CoAP request message.
     */
    public init(type: Reliability, method: Method, url: URL? = nil) {
        self.init(type: type, code: .request(method))
        self.url = url
    }

    /**
     Initializes a new CoAP `ACK` delivery confirmation message to another received message.

     - parameter ackTo: Source message to be acknowledged
     - parameter from: Source message address
     - parameter code: Response code

     - returns: A ready to be sent CoAP acknowledgment message.
     */
    public init(ackTo request: CoAPMessage,
                from address: Address? = nil,
                code: ResponseCode) {
        self.init(type: .acknowledgement, code: .response(code), messageId: request.messageId)
        self.url = address?.urlForScheme(scheme: request.scheme)
        self.token = request.token
    }

    /**
     Initializes a new CoAP response message to another request message.

     - parameter type: Confirmable, Non-confirmable, Acknowledgement, or Reset message
     - parameter code: Response code
     - parameter inResponseTo: Request message
     - parameter from: Request message address

     - returns: A ready to be sent CoAP response message.
     */
    public init(type: Reliability,
                code: ResponseCode,
                inResponseTo request: CoAPMessage,
                from address: Address) {
        self.init(type: type, code: .response(code))
        self.url = address.urlForScheme(scheme: request.scheme)
        self.token = request.token
    }

    /// Get [CoAP options](https://tools.ietf.org/html/rfc7252#section-5.10)
    /// for specified option number
    public func getOptions(_ number: CoAPMessageOption.Number) -> [CoAPOptionValue] {
        return options.filter({ $0.number == number }).map({ $0.value })
    }

    /// Set a value to [CoAP option](https://tools.ietf.org/html/rfc7252#section-5.10)
    /// for specified option number
    public mutating func setOption(_ number: CoAPMessageOption.Number, value: CoAPOptionValue?) {
        if let value = value {
            setOption(CoAPMessageOption(number: number, value: value))
        } else {
            removeOption(number)
        }
    }

    /// Remove [CoAP option](https://tools.ietf.org/html/rfc7252#section-5.10)
    /// for specified option number
    public mutating func removeOption(_ number: CoAPMessageOption.Number) {
        options = options.filter({ $0.number != number })
    }

    fileprivate mutating func setOption(_ option: CoAPMessageOption) {
        if !option.repeatable {
            removeOption(option.number)
        }
        options.append(option)
    }

    /// If set, message will be sent via proxy server, specified by `proxyViaAddress`
    public var proxyViaAddress: Address?

    /**
     If set in outgoing coaps:// message, peer's public key will be validated
     during handshake. If not, no validation will be performed

     If present in incoming message, it indicates public key used by peer during handshake
     */
    public var peerPublicKey: Data?
}
