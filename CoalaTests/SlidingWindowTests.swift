import XCTest
@testable import Coala

final class SlidingWindowTests: XCTestCase {

    func testInitialStateOffsetAndTail() {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        XCTAssertEqual(window.getOffset(), 0)
        XCTAssertEqual(window.tail, 2)
        XCTAssertNil(window.getValue(atWindowIndex: 0))
        XCTAssertNil(window.getValue(atWindowIndex: 2))
    }

    func testSetAndGetValue() throws {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        try window.set(value: true, atIndex: 1)
        XCTAssertEqual(window.getValue(atWindowIndex: 1), true)
        XCTAssertNil(window.getValue(atWindowIndex: 0))
    }

    func testSetAboveWindowThrows() {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        XCTAssertThrowsError(try window.set(value: true, atIndex: 3)) { error in
            XCTAssertEqual(error as? SlidingWindowError, .outOfBounds)
        }
    }

    func testSetBelowOffsetIsSilentNoOp() {
        let window = SlidingWindow<Bool>(size: 3, offset: 2)
        XCTAssertNoThrow(try window.set(value: true, atIndex: 1)) // window index -1
        XCTAssertNil(window.getValue(atWindowIndex: 0))
    }

    func testAdvanceReturnsNilWhenFrontEmpty() {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        XCTAssertNil(window.advance())
        XCTAssertEqual(window.getOffset(), 0)
    }

    func testAdvanceSlidesWhenFrontDelivered() throws {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        try window.set(value: true, atIndex: 0)
        XCTAssertEqual(window.advance(), true)
        XCTAssertEqual(window.getOffset(), 1)
        XCTAssertEqual(window.tail, 3)
    }

    func testAdvanceConsumesContiguousDeliveredBlocks() throws {
        let window = SlidingWindow<Bool>(size: 4, offset: 0)
        try window.set(value: true, atIndex: 0)
        try window.set(value: true, atIndex: 1)
        XCTAssertEqual(window.advance(), true)
        XCTAssertEqual(window.advance(), true)
        XCTAssertNil(window.advance())
        XCTAssertEqual(window.getOffset(), 2)
    }

    func testDeliveredUpperBoundStopsAtFirstGap() throws {
        let window = SlidingWindow<Bool>(size: 4, offset: 0)
        try window.set(value: true, atIndex: 0)
        try window.set(value: true, atIndex: 1)
        // index 2 left nil → delivered prefix stops there
        XCTAssertEqual(window.deliveredUpperBound { $0 == true }, 2)
    }

    func testDeliveredUpperBoundIncludesOffset() throws {
        let window = SlidingWindow<Bool>(size: 4, offset: 5)
        try window.set(value: true, atIndex: 5)
        try window.set(value: true, atIndex: 6)
        // window index 2 (logical index 7) left nil → leading prefix stops there
        XCTAssertEqual(window.deliveredUpperBound { $0 == true }, 7) // offset 5 + 2 leading
    }

    func testDeliveredUpperBoundReflectsOffsetAfterAdvance() throws {
        let window = SlidingWindow<Bool>(size: 4, offset: 0)
        try window.set(value: true, atIndex: 0)
        try window.set(value: true, atIndex: 1)
        _ = window.advance() // consumes logical index 0, offset -> 1
        // from window index 0: old index 1 == true, next slot nil
        XCTAssertEqual(window.deliveredUpperBound { $0 == true }, 2) // offset 1 + 1 leading
    }

    // MARK: - Edge cases

    /// Reachable in production: SRTxState with empty data builds a size-0 window.
    func testZeroSizeWindowIsInertAndSafe() {
        let window = SlidingWindow<Bool>(size: 0, offset: 0)
        XCTAssertNil(window.advance())
        XCTAssertNil(window.advanceReturningTail())
        XCTAssertThrowsError(try window.set(value: true, atIndex: 0))
        XCTAssertNil(window.getValue(atWindowIndex: 0))
        XCTAssertEqual(window.deliveredUpperBound { $0 == true }, 0)
        XCTAssertEqual(window.tail, -1)
        _ = window.description // must not crash
    }

    /// SRTxState's actual construction: offset -windowSize, negative slots pre-set,
    /// so the first popped tails are the real block numbers 0, 1, ...
    func testNegativeOffsetPrefilledWindowYieldsBlockZeroFirst() throws {
        let window = SlidingWindow<Bool>(size: 2, offset: -2)
        try window.set(value: true, atIndex: -2)
        try window.set(value: true, atIndex: -1)
        XCTAssertEqual(window.advanceReturningTail(), 0)
        XCTAssertEqual(window.advanceReturningTail(), 1)
        XCTAssertNil(window.advanceReturningTail()) // real slots not delivered yet
    }

    func testRingReusesSlotsAfterAdvance() throws {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        try window.set(value: true, atIndex: 0)
        try window.set(value: true, atIndex: 1)
        try window.set(value: true, atIndex: 2)
        XCTAssertEqual(window.advance(), true) // offset → 1, slot recycled
        try window.set(value: true, atIndex: 3) // lands in the recycled slot
        XCTAssertEqual(window.getValue(atWindowIndex: 0), true) // logical 1
        XCTAssertEqual(window.getValue(atWindowIndex: 2), true) // logical 3
        XCTAssertEqual(window.deliveredUpperBound { $0 == true }, 4) // full window delivered
    }

    /// A stale set below the offset (late ACK for an already-slid block) must be
    /// ignored entirely — not wrap around into a live slot.
    func testStaleSetBelowOffsetDoesNotCorruptRing() throws {
        let window = SlidingWindow<Bool>(size: 2, offset: 0)
        try window.set(value: true, atIndex: 0)
        _ = window.advance() // offset → 1
        XCTAssertNoThrow(try window.set(value: true, atIndex: 0)) // stale
        XCTAssertNil(window.getValue(atWindowIndex: 0)) // logical 1 untouched
        XCTAssertNil(window.getValue(atWindowIndex: 1)) // logical 2 untouched
    }

    func testSetAtTailBoundary() throws {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        try window.set(value: true, atIndex: 2) // windowIndex == size - 1
        XCTAssertEqual(window.getValue(atWindowIndex: 2), true)
        XCTAssertThrowsError(try window.set(value: true, atIndex: 3))
    }

    func testAdvanceReturningTailYieldsContiguousTails() throws {
        let window = SlidingWindow<Bool>(size: 3, offset: 0)
        for i in 0..<3 { try window.set(value: true, atIndex: i) }
        XCTAssertEqual(window.advanceReturningTail(), 3)
        XCTAssertEqual(window.advanceReturningTail(), 4)
        XCTAssertEqual(window.advanceReturningTail(), 5)
        XCTAssertNil(window.advanceReturningTail())
    }

    // MARK: - Concurrency (the NSLock is reachable from the send-caller and delegate queues)

    /// Two racing poppers must never observe the same tail — the exact split-read
    /// bug advanceReturningTail exists to prevent (duplicated + skipped block).
    func testConcurrentAdvanceReturningTailYieldsUniqueTails() {
        let size = 500
        let window = SlidingWindow<Bool>(size: size, offset: 0)
        for i in 0..<size { try? window.set(value: true, atIndex: i) }

        let tails = Synchronized<Set<Int>>(value: [])
        DispatchQueue.concurrentPerform(iterations: size) { _ in
            if let tail = window.advanceReturningTail() {
                tails.mutate { $0.insert(tail) }
            }
        }
        XCTAssertEqual(tails.value, Set(size..<(2 * size)))
    }

    func testConcurrentAdvanceConsumesEachSlotExactlyOnce() {
        let size = 500
        let window = SlidingWindow<Bool>(size: size, offset: 0)
        for i in 0..<size { try? window.set(value: true, atIndex: i) }

        let consumed = Synchronized<Int>(value: 0)
        DispatchQueue.concurrentPerform(iterations: size) { _ in
            if window.advance() != nil { consumed.mutate { $0 += 1 } }
        }
        // Without the lock, concurrent advance() would race head/offset → over- or
        // under-count. Each delivered slot must be consumed exactly once.
        XCTAssertEqual(consumed.value, size)
        XCTAssertEqual(window.getOffset(), size)
        XCTAssertNil(window.advance())
    }
}
