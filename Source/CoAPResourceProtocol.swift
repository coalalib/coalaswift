//
//  CoAPResourceProtocol.swift
//  Coala
//
//  Created by Roman on 14/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

public protocol CoAPResourceProtocol {

    var method: CoAPMessage.Method { get }
    var path: String { get }

    func response(forRequest message: CoAPMessage, fromAddress: Address) -> CoAPMessage
}

extension CoAPResourceProtocol {

    func doesMatch(path: String) -> Bool {
        return path.trimmed == self.path.trimmed
    }

    func doesMatch(_ method: CoAPMessage.Method, path: String) -> Bool {
        return method == self.method && doesMatch(path: path)
    }
}

fileprivate extension String {
    var trimmed: String {
        return trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
