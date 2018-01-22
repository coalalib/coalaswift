//
//  CoAPBlockOption.swift
//  Coala
//
//  Created by Roman on 22/09/16.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

//    0
//    0 1 2 3 4 5 6 7
//    +-+-+-+-+-+-+-+-+
//    |  NUM  |M| SZX |
//    +-+-+-+-+-+-+-+-+
//
//    0                   1
//    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
//    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//    |          NUM          |M| SZX |
//    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//
//    0                   1                   2
//    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3
//    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//    |                   NUM                 |M| SZX |
//    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

struct CoAPBlockOption {

    enum BlockSize: UInt {
        case size16
        case size32
        case size64
        case size128
        case size256
        case size512
        case size1024

        var value: Int {
            return 1 << (Int(rawValue) + 4)
        }
    }

    let num: UInt
    let mFlag: Bool
    let szx: BlockSize
}

extension CoAPBlockOption {

    var value: CoAPOptionValue {
        let m: UInt = mFlag ? 1 : 0
        return num << 4 | m << 3 | szx.rawValue
    }
}

extension CoAPOptionValue {

    func blockOption() -> CoAPBlockOption? {
        let value = UInt(data: self.data)
        guard let blockSize = CoAPBlockOption.BlockSize(rawValue: value & 0b111)
            else { return nil }
        return CoAPBlockOption(num: value >> 4,
                               mFlag: (value >> 3) & 1 == 1,
                               szx: blockSize)
    }
}

extension CoAPMessage {

    var block1Option: CoAPBlockOption? {
        get {
            return getOptions(.block1).first?.blockOption()
        }
        set {
            setOption(.block1, value: newValue?.value)
        }
    }

    var block2Option: CoAPBlockOption? {
        get {
            return getOptions(.block2).first?.blockOption()
        }
        set {
            setOption(.block2, value: newValue?.value)
        }
    }
}

extension CoAPBlockOption: CustomStringConvertible {
    var description: String {
        return "\(num)/\(mFlag ? 1 : 0)/\(szx.value)"
    }
}
