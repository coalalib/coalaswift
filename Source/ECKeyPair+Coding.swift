//
//  ECKeyPair+Coding.swift
//  Coala
//
//  Created by Roman on 26/10/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation
import Curve25519

extension ECKeyPair {

    func toData() -> Data {
        return NSKeyedArchiver.archivedData(withRootObject: self)
    }

    static func from(data: Data) -> ECKeyPair? {
        return NSKeyedUnarchiver.unarchiveObject(with: data) as? ECKeyPair
    }
}
