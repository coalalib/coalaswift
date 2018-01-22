//
//  CoAPConstants.swift
//  Coala
//
//  Created by Roman on 06/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

extension CoAPMessage {

    /// CoAP message type
    public enum Reliability: UInt8 {
        /// Message requiring acknowledgement
        case confirmable
        /// Message not requiring acknowledgement
        case nonConfirmable
        /// Acknowledgement message acknowledges that a specific `.confirmable` message arrived
        case acknowledgement
        /// Reset message indicates that a specific message (`.confirmable` or
        /// `.nonConfirmable`) was received, but some context is missing to
        /// properly process it
        case reset
    }

    /// In case of a request indicates CoAP message's `Method`;
    /// in case of a response, a `ResponseCode`
    public enum Code {
        case request(Method)
        case response(ResponseCode)
    }

    /// CoAP request message method
    public enum Method: CoAPRegistryCode {
        /// GET method retrieves a representation for the information that
        /// currently corresponds to the resource
        case get                        = 0.01
        /// POST method requests that the representation enclosed in the
        /// request be processed
        case post                       = 0.02
        /// PUT method requests that the resource identified by the request
        /// URI be updated or created with the enclosed representation
        case put                        = 0.03
        /// DELETE method requests that the resource identified by the
        /// request URI be deleted
        case delete                     = 0.04
    }

    /// CoAP response message code as specified in 
    /// [RFC7252](https://tools.ietf.org/html/rfc7252#section-12.1.2)
    public enum ResponseCode: CoAPRegistryCode {

        // RFC 7252
        case empty                      = 0.00
        case created                    = 2.01
        case deleted                    = 2.02
        case valid                      = 2.03
        case changed                    = 2.04
        case content                    = 2.05
        case badRequest                 = 4.00
        case unauthorized               = 4.01
        case badOption                  = 4.02
        case forbidden                  = 4.03
        case notFound                   = 4.04
        case methodNotAllowed           = 4.05
        case notAcceptable              = 4.06
        case preconditionFailed         = 4.12
        case requestEntityTooLarge      = 4.13
        case unsupportedContentFormat   = 4.15
        case internalServerError        = 5.00
        case notImplemented             = 5.01
        case badGateway                 = 5.02
        case serviceUnavailable         = 5.03
        case gatewayTimeout             = 5.04
        case proxyingNotSupported       = 5.05

        // RFC 7959
        case continued                  = 2.31
        case requestEntityIncomplete    = 4.08

        public var isError: Bool {
            return rawValue.major >= 4
        }
    }

    public enum Scheme: Int {
        case coap
        case coapSecure

        var string: String {
            switch self {
            case .coap:
                return "coap"
            case .coapSecure:
                return "coaps"
            }
        }

        init?(string: String) {
            let allSchemes: [Scheme] = [.coap, .coapSecure]
            guard let scheme = allSchemes.first(where: { $0.string == string }) else { return nil }
            self = scheme
        }
    }
}

extension CoAPMessage.Code: RawRepresentable, Equatable {

    public var rawValue: UInt8 {
        switch self {
        case .request(let requestMethod):
            return requestMethod.rawValue.integerValue
        case .response(let responseCode):
            return responseCode.rawValue.integerValue
        }
    }

    public init?(rawValue: UInt8) {
        let code = CoAPRegistryCode(integerValue: rawValue)
        if let method = CoAPMessage.Method(rawValue: code) {
            self = .request(method)
            return
        }
        if let response = CoAPMessage.ResponseCode(rawValue: code) {
            self = .response(response)
            return
        }
        return nil
    }
}

public func == (lhs: CoAPMessage.Code, rhs: CoAPMessage.Code) -> Bool {
    return lhs.rawValue == rhs.rawValue
}

extension CoAPMessage.Reliability: CustomStringConvertible {
    public var description: String {
        switch self {
        case .confirmable:
            return "CON"
        case .nonConfirmable:
            return "NON"
        case .acknowledgement:
            return "ACK"
        case .reset:
            return "RST"
        }
    }
}

extension CoAPMessage.Code: CustomStringConvertible {
    public var description: String {
        switch self {
        case .request(let method):
            return "\(method)".uppercased()
        case .response(let code):
            return "\(code.rawValue.major).\(code.rawValue.minor) \(code)"
        }
    }
}
