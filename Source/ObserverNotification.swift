//
//  ObserverNotification.swift
//  Coala
//
//  Created by Roman on 23/11/2016.
//  Copyright © 2016 NDM Systems. All rights reserved.
//

import Foundation

struct ObserverNotification {
    let message: CoAPMessage
    let from: Address
    let sequenceNumber: UInt?
    let maxAge: UInt?
}
