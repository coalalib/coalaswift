//
//  Response+Utils.swift
//  Coala
//
//  Created by Roman on 20/11/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

extension Coala.Response {

    public var isError: Bool {
        switch self {
        case .message:
            return false
        case .error:
            return true
        }
    }

}
