import XCTest
@testable import Coala

final class ARQLayerStateTests: XCTestCase {

    private func makeReceiveState(token: CoAPToken, ageSeconds: TimeInterval) -> ARQLayer.ReceiveState {
        let message = CoAPMessage(type: .confirmable, method: .get)
        var state = ARQLayer.ReceiveState(token: token,
                                          outboundMessage: nil,
                                          originalMessage: message,
                                          selectiveRepeat: SRRxState())
        state.lastActivity = Date(timeIntervalSinceNow: -ageSeconds)
        return state
    }

    func testReapRemovesStaleReceiveStates() {
        let arq = ARQLayer()
        arq.receiveStateMaxAge = 30
        let token = CoAPToken(value: Data([0x01]))
        arq.rxStates.mutate { $0[token] = self.makeReceiveState(token: token, ageSeconds: 120) }
        arq.reapStaleReceiveStates()
        XCTAssertNil(arq.rxStates.value[token])
    }

    func testReapKeepsFreshReceiveStates() {
        let arq = ARQLayer()
        arq.receiveStateMaxAge = 30
        let token = CoAPToken(value: Data([0x02]))
        arq.rxStates.mutate { $0[token] = self.makeReceiveState(token: token, ageSeconds: 5) }
        arq.reapStaleReceiveStates()
        XCTAssertNotNil(arq.rxStates.value[token])
    }

    func testReapClearsBlock2DownloadProgressForStaleStates() {
        let arq = ARQLayer()
        arq.receiveStateMaxAge = 30
        let token = CoAPToken(value: Data([0x04]))
        arq.rxStates.mutate { $0[token] = self.makeReceiveState(token: token, ageSeconds: 120) }
        arq.setBlock2DownloadProgress({ _ in }, forToken: token)
        XCTAssertNotNil(arq.block2DownloadProgresses.value[token])

        arq.reapStaleReceiveStates()

        XCTAssertNil(arq.rxStates.value[token])
        XCTAssertNil(arq.block2DownloadProgresses.value[token]) // leaked before the fix
    }

    /// The reaper runs on the inbound path before the resuming block refreshes
    /// lastActivity. It must never evict the token being processed, otherwise a
    /// transfer resuming after a >maxAge stall restarts at frontier 0 and hangs.
    func testReapKeepsStaleStateForExcludedActiveToken() {
        let arq = ARQLayer()
        arq.receiveStateMaxAge = 30
        let token = CoAPToken(value: Data([0x05]))
        arq.rxStates.mutate { $0[token] = self.makeReceiveState(token: token, ageSeconds: 120) }
        arq.setBlock2DownloadProgress({ _ in }, forToken: token)

        arq.reapStaleReceiveStates(excluding: token)

        XCTAssertNotNil(arq.rxStates.value[token])
        XCTAssertNotNil(arq.block2DownloadProgresses.value[token])
    }

    func testFailClearsBlock2DownloadProgress() {
        let arq = ARQLayer()
        let token = CoAPToken(value: Data([0x03]))
        arq.setBlock2DownloadProgress({ _ in }, forToken: token)
        XCTAssertNotNil(arq.block2DownloadProgresses.value[token])
        arq.fail(withError: ARQLayerError.unexpectedAck, forToken: token)
        XCTAssertNil(arq.block2DownloadProgresses.value[token])
    }

    /// The reap age check is strictly greater-than: a state exactly at maxAge stays.
    func testReapBoundaryIsExclusive() {
        let arq = ARQLayer()
        arq.receiveStateMaxAge = 30
        let token = CoAPToken(value: Data([0x06]))
        let t0 = Date()
        var state = makeReceiveState(token: token, ageSeconds: 0)
        state.lastActivity = t0
        arq.rxStates.mutate { $0[token] = state }

        arq.reapStaleReceiveStates(referenceDate: t0.addingTimeInterval(30))
        XCTAssertNotNil(arq.rxStates.value[token])

        arq.reapStaleReceiveStates(referenceDate: t0.addingTimeInterval(30.5))
        XCTAssertNil(arq.rxStates.value[token])
    }

    func testReapRemovesOnlyStaleTokens() {
        let arq = ARQLayer()
        arq.receiveStateMaxAge = 30
        let staleToken = CoAPToken(value: Data([0x07]))
        let freshToken = CoAPToken(value: Data([0x08]))
        arq.rxStates.mutate {
            $0[staleToken] = self.makeReceiveState(token: staleToken, ageSeconds: 120)
            $0[freshToken] = self.makeReceiveState(token: freshToken, ageSeconds: 5)
        }
        arq.reapStaleReceiveStates()
        XCTAssertNil(arq.rxStates.value[staleToken])
        XCTAssertNotNil(arq.rxStates.value[freshToken])
    }

    func testFailRemovesRxAndTxStatesAndNotifiesOnResponseOnce() {
        let arq = ARQLayer()
        let token = CoAPToken(value: Data([0x09]))
        let errors = Synchronized<[Error]>(value: [])
        var originalMessage = CoAPMessage(type: .confirmable, method: .post)
        originalMessage.onResponse = { response in
            if case .error(let error) = response {
                errors.mutate { $0.append(error) }
            }
        }
        let tx = ARQLayer.TransmitState(
            token: token,
            originalMessage: originalMessage,
            selectiveRepeat: SRTxState(data: Data(count: 2048), windowSize: 2, blockSize: 1024)
        )
        arq.txStates.mutate { $0[token] = tx }
        arq.rxStates.mutate { $0[token] = self.makeReceiveState(token: token, ageSeconds: 0) }

        arq.fail(withError: ARQLayerError.unexpectedAck, forToken: token)

        XCTAssertNil(arq.txStates.value[token])
        XCTAssertNil(arq.rxStates.value[token])
        XCTAssertEqual(errors.value.count, 1)

        arq.fail(withError: ARQLayerError.unexpectedAck, forToken: token) // idempotent
        XCTAssertEqual(errors.value.count, 1) // no second callback once state is gone
    }

    func testSetNilProgressRemovesEntry() {
        let arq = ARQLayer()
        let token = CoAPToken(value: Data([0x0A]))
        arq.setBlock2DownloadProgress({ _ in }, forToken: token)
        XCTAssertNotNil(arq.block2DownloadProgresses.value[token])
        arq.setBlock2DownloadProgress(nil, forToken: token)
        XCTAssertNil(arq.block2DownloadProgresses.value[token])
    }

    func testDidTransmitForUnknownTokenIsNoOp() {
        let arq = ARQLayer()
        let token = CoAPToken(value: Data([0x0B]))
        XCTAssertNoThrow(try arq.didTransmit(blockNumber: 0, forToken: token, retransmits: 1))
        XCTAssertNil(arq.txStates.value[token])
    }

    // MARK: - Concurrency (C5: block2DownloadProgresses mutated from ≥3 threads)

    func testConcurrentProgressMapDistinctKeysStayConsistent() {
        let arq = ARQLayer()
        let count = 300
        let tokens = (0..<count).map {
            CoAPToken(value: Data([UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF)]))
        }
        DispatchQueue.concurrentPerform(iterations: count) { i in
            arq.setBlock2DownloadProgress({ _ in }, forToken: tokens[i])
        }
        XCTAssertEqual(arq.block2DownloadProgresses.value.count, count)

        DispatchQueue.concurrentPerform(iterations: count) { i in
            if i % 2 == 0 {
                arq.fail(withError: ARQLayerError.unexpectedAck, forToken: tokens[i])
            }
        }
        // Even indices cleared; odd indices survive — deterministic since keys are distinct.
        XCTAssertEqual(arq.block2DownloadProgresses.value.count, count / 2)
    }

    func testConcurrentProgressSetAndClearOnSameTokenIsSafe() {
        let arq = ARQLayer()
        let token = CoAPToken(value: Data([0xFF, 0xEE]))
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            if i % 2 == 0 {
                arq.setBlock2DownloadProgress({ _ in }, forToken: token)
            } else {
                arq.fail(withError: ARQLayerError.unexpectedAck, forToken: token)
            }
        }
        // Whatever the racing order, a final explicit clear must leave the map empty
        // for this token (no torn state, no crash under the data race the lock prevents).
        arq.fail(withError: ARQLayerError.unexpectedAck, forToken: token)
        XCTAssertNil(arq.block2DownloadProgresses.value[token])
    }
}
