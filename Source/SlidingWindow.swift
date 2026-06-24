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

/// Fixed-size window over a logical index space starting at `offset`.
/// Backed by a ring buffer so `advance()` is O(1) (no array element shifting).
/// Thread-safe via a single `NSLock`: the window is reachable from both the
/// `send`-caller thread (initial `sendMoreData`) and the serial delegate queue
/// (ACK-driven `sendMoreData`), and is a class shared across `TransmitState`
/// struct copies, so the owning dictionary's lock does not cover it.
final class SlidingWindow<T> {

    let size: Int
    private var offset: Int
    private var values: [T?]
    private var head: Int = 0
    private let lock = NSLock()

    init(size: Int, offset: Int = 0) {
        self.size = size
        self.offset = offset
        values = [T?](repeating: nil, count: size)
    }

    private func locked<R>(_ work: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    func getOffset() -> Int {
        return locked { offset }
    }

    var tail: Int {
        return locked { offset + size - 1 }
    }

    func set(value: T, atIndex: Int) throws {
        try locked {
            let windowIndex = atIndex - offset
            guard 0 ..< size ~= windowIndex else {
                if windowIndex < 0 {
                    return
                } else {
                    throw SlidingWindowError.outOfBounds
                }
            }
            values[(head + windowIndex) % size] = value
        }
    }

    func advance() -> T? {
        return locked {
            guard size > 0, values[head] != nil else { return nil }
            let result = values[head]
            values[head] = nil
            head = (head + 1) % size
            offset += 1
            return result
        }
    }

    /// Advances the window (if the front slot is delivered) and returns the new `tail`
    /// — the highest logical index now in the window — in a single lock acquisition.
    /// Returns nil if the front is not yet delivered. Callers that need both the slide
    /// and the resulting index (e.g. `SRTxState.popBlock`) MUST use this instead of a
    /// separate `advance()` + `tail`: the window is reached from the send-caller thread
    /// and the ACK delegate queue, so two separate locked reads can interleave and yield
    /// the same `tail` → a duplicated and a skipped block.
    func advanceReturningTail() -> Int? {
        return locked {
            guard size > 0, values[head] != nil else { return nil }
            values[head] = nil
            head = (head + 1) % size
            offset += 1
            return offset + size - 1
        }
    }

    func getValue(atWindowIndex index: Int) -> T? {
        return locked {
            guard size > 0, 0 ..< size ~= index else { return nil }
            return values[(head + index) % size]
        }
    }

    /// `offset` plus the number of leading window slots (from window index 0)
    /// for which `predicate` holds, computed under one lock acquisition —
    /// a separate offset read could interleave with `advance()` on another
    /// thread and over-count the delivered prefix.
    func deliveredUpperBound(while predicate: (T?) -> Bool) -> Int {
        return locked {
            var count = 0
            while count < size && predicate(values[(head + count) % size]) {
                count += 1
            }
            return offset + count
        }
    }
}

extension SlidingWindow: CustomStringConvertible {

    var description: String {
        return locked {
            let mask: String
            if size < 20 {
                mask = (0 ..< size)
                    .map { values[(head + $0) % size] != nil ? "T" : "_" }
                    .joined()
            } else {
                mask = ""
            }
            return "SlidingWindow<size:\(size), offset:\(offset)>[\(mask)]"
        }
    }
}
