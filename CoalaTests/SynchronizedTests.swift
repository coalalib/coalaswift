import XCTest
@testable import Coala

final class SynchronizedTests: XCTestCase {

    func testConcurrentMutateScalarHasNoLostUpdates() {
        let sync = Synchronized<Int>(value: 0)
        let perWorker = 1000
        let workers = 8
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            for _ in 0..<perWorker {
                sync.mutate { $0 += 1 }
            }
        }
        XCTAssertEqual(sync.value, workers * perWorker)
    }

    func testConcurrentMutateDictionaryHasNoLostUpdates() {
        let sync = Synchronized<[String: Int]>(value: [:])
        let perWorker = 1000
        let workers = 8
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            for _ in 0..<perWorker {
                sync.mutate { $0["k", default: 0] += 1 }
            }
        }
        XCTAssertEqual(sync.value["k"], workers * perWorker)
    }

    func testMutateReturnsValue() {
        let sync = Synchronized<[String: Int]>(value: ["a": 1])
        let previous: Int? = sync.mutate { dict in
            let old = dict["a"]
            dict["a"] = 2
            return old
        }
        XCTAssertEqual(previous, 1)
        XCTAssertEqual(sync.value["a"], 2)
    }
}
