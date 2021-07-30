//
//  CoAPMessage+Utils.swift
//  Coala
//
//  Created by Roman on 10/10/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

extension CoAPMessage {

    var requestMethod: CoAPMessage.Method? {
        switch code {
        case .request(let method):
            return method
        case .response:
            return nil
        }
    }

    public var responseCode: CoAPMessage.ResponseCode? {
        switch code {
        case .request:
            return nil
        case .response(let responseCode):
            return responseCode
        }
    }

    var isRequest: Bool {
        switch code {
        case .request:
            return true
        case .response:
            return false
        }
    }

    var isResponse: Bool {
        switch code {
        case .request, .response(.empty):
            return false
        case .response:
            return true
        }
    }

    /// URL query contained in a message
    public var query: [URLQueryItem]? {
        get {
            let queryOptions = getStringOptions(.uriQuery)
            guard queryOptions.count > 0 else { return nil }
            let queryItems = queryOptions.map { (queryOption: String) -> URLQueryItem in
                let comps = queryOption.components(separatedBy: "=")
                var itemValue = comps.count > 1 ? comps[1] : nil
                if var result = itemValue, comps.count > 2 {
                    for i in 2 ..< comps.count {
                        result += "=\(comps[i])"
                    }
                    itemValue = result
                }
                return URLQueryItem(
                    name: comps.first ?? "",
                    value: itemValue
                )
            }
            return queryItems
        }
        set {
            removeOption(.uriQuery)
            guard let queryItems = newValue else { return }
            for item in queryItems {
                setOption(.uriQuery, value: "\(item.name)=\(item.value ?? "")")
            }
        }
    }

    /// URL of message destination
    public var url: URL? {
        get {
            let port = getIntegerOptions(.uriPort).first ?? UInt(address?.port ?? Coala.defaultPort)
            guard let host = getStringOptions(.uriHost).first ?? address?.host
                else { return nil }
            var components = URLComponents()
            components.scheme = scheme.string
            components.host = host
            components.port = Int(port)
            components.path = getStringOptions(.uriPath).joined(separator: "/")
            if !components.path.hasPrefix("/") {
                components.path.insert("/", at: components.path.startIndex)
            }

            let percentEncodingQuery: String? = query?.compactMap {
                let key = $0.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                let value = $0.value?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                guard let key = key, let value = value else { return nil }
                return key + "=" + value
            }
            .joined(separator: "&")
            .replacingOccurrences(of: "+", with: "%2b")
            
            components.percentEncodedQuery = percentEncodingQuery

            return components.url
        }
        set {
            removeOption(.uriHost)
            removeOption(.uriPort)
            removeOption(.uriPath)
            removeOption(.uriQuery)
            if let urlScheme = newValue?.scheme, let scheme = Scheme(string: urlScheme) {
                self.scheme = scheme
            }
            if var pathComponents = newValue?.pathComponents {
                if pathComponents.first == "/" {
                    pathComponents.removeFirst()
                }
                for component in pathComponents {
                    setOption(.uriPath, value: component.removingPercentEncoding)
                }
            }
            if let queryComponents = newValue?.query?.components(separatedBy: "&") {
                for component in queryComponents {
                    setOption(.uriQuery, value: component.removingPercentEncoding)
                }
            }
            if let host = newValue?.host {
                let port = newValue?.port ?? Int(Coala.defaultPort)
                address = Address(host: host, port: UInt16(port))
            } else {
                address = nil
            }
        }
    }

}

// Convenience option getters

extension CoAPMessage {

    public func getStringOptions(_ number: CoAPMessageOption.Number) -> [String] {
        return getOptions(number).map({ String(data: $0.data) })
    }

    public func getIntegerOptions(_ number: CoAPMessageOption.Number) -> [UInt] {
        return getOptions(number).map({ UInt(data: $0.data) })
    }

    public func getOpaqueOptions(_ number: CoAPMessageOption.Number) -> [Data] {
        return getOptions(number).map({ $0.data })
    }

    public static func randomMessageId() -> UInt16 {
        // https://tools.ietf.org/html/rfc7252#section-4
        return UInt16(1 + arc4random_uniform(65535))
    }

}
