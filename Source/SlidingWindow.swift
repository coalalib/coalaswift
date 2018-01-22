//
//  SlidingWindow.swift
//  Coala
//
//  Created by Roman on 03/08/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import Foundation

enum SlidingWindowError: Error {
    case outOfBounds
}

class SlidingWindow<T> {

    let size: Int
    fileprivate var offset: Int
    fileprivate var values: [T?]

    private let accessQueue = DispatchQueue(label: "SlidingWindowAccess", attributes: .concurrent)

    fileprivate func write<T>(execute work: () throws -> T) rethrows -> T {
        return try accessQueue.sync(flags: .barrier, execute: work)
    }

    fileprivate func read<T>(execute work: () throws -> T) rethrows -> T {
        return try accessQueue.sync(execute: work)
    }

    init(size: Int, offset: Int = 0) {
        self.size = size
        self.offset = offset
        values = [T?](repeating: nil, count: size)
    }

    func getOffset() -> Int {
        return read {
            return offset
        }
    }

    var tail: Int {
        return read {
            return offset + size - 1
        }
    }

    func set(value: T, atIndex: Int) throws {
        try write {
            let windowIndex = atIndex - offset
            guard 0 ..< size ~= windowIndex else {
                if windowIndex < 0 {
                    return
                } else {
                    throw SlidingWindowError.outOfBounds
                }
            }
            self.values[windowIndex] = value
        }
    }

    func advance() -> T? {
        return write {
            guard values.first is T else { return nil }
            values.append(nil)
            offset += 1
            return values.removeFirst()
        }
    }

    func getValue(atWindowIndex: Int) -> T? {
        return read {
            return values[atWindowIndex]
        }
    }
}

extension SlidingWindow: CustomStringConvertible {

    var description: String {
        let zeroIndex = offset < 0 ? -offset : 0
        let valuesMask = values.count < 20 ? values.suffix(from: zeroIndex).map({ $0 != nil ? "T" : "_" }).joined() : ""
        return read { "SlidingWindow<size:\(size), offset:\(offset)>[\(valuesMask)]" }
    }

}
