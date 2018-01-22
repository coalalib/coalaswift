//
//  BinaryByteFormatter.swift
//  Coala
//
//  Created by Roman on 29/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

open class BinaryByteFormatter: ByteCountFormatter {

    public override init() {
        super.init()
        countStyle = .binary
        allowsNonnumericFormatting = false
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
}
