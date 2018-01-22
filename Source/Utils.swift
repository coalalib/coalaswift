//
//  Utils.swift
//  Coala
//
//  Created by Roman on 14/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

public func MD5(_ data: Data) -> Data {
    return CC.digest(data, alg: .md5)
}

extension Data {

    var hexDescription: String {
        return reduce("") {$0 + String(format: "%02x", $1)}
    }

    public static func randomData(length: Int) -> Data {
        var rnd = [UInt8](repeating: 0, count: length)
        arc4random_buf(&rnd, length)
        let data = Data(bytes: &rnd, count: length)
        return data
    }

    public var sha256: Data {
        return CC.digest(self, alg: .sha256)
    }
}

extension Coala {

    public var arqWindowSize: Int {
        get {
            return layerStack.arqLayer.defaultSendWindowSize
        }
        set {
            layerStack.arqLayer.defaultSendWindowSize = newValue
        }
    }

}
