//
//  PerformanceTests.swift
//  Coala
//
//  Created by Roman on 22/03/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

import XCTest
@testable import Coala

class PerformanceTests: CoalaTests {

    override func setUp() {
        super.setUp()
        (Coala.logger as? DefaultLogger)?.minLogLevel = .info
    }

    let formatter = BinaryByteFormatter()
    let serverUrl = URL(string: "coap://46.101.158.16:5683/tests/large")!
//    let iPhoneUrl = URL(string: "coap://192.168.1.43:5683/tests/mirror")!

    func testServerBlock1() {
        let speed = testPerformance(direction: .block1, size: 1000000, toUrl: serverUrl) ?? 0
        print("Speed: \(formatter.string(fromByteCount: Int64(speed)))/s")
        XCTAssert(speed != 0)
    }

    func testServerBlock2() {
        let speed = testPerformance(direction: .block2, size: 1000000, toUrl: serverUrl) ?? 0
        print("Speed: \(formatter.string(fromByteCount: Int64(speed)))/s")
        XCTAssert(speed != 0)
    }

    func testPerformance(direction: Direction, size: Int, toUrl: URL) -> Double? {
        var speed: Double?
        let start = DispatchTime.now()
        var requestMessage = CoAPMessage(type: .confirmable, method: direction == .block1 ? .post : .get, url: toUrl)
        let transferCompleted = expectation(description: "Transfer Completed")
        switch direction {
        case .block1:
            let data = Data.randomData(length: size)
            requestMessage.payload = data
            requestMessage.query = [URLQueryItem(name: "hash",
                                                 value: MD5(data).hexDescription)]
        case .block2:
            requestMessage.query = [URLQueryItem(name: "size", value: "\(size)")]
        }
        var responses = 0
        requestMessage.onResponse = { response in
            responses += 1
            if responses == 2 {
                XCTAssert(false)
                return
            }
            switch response {
            case .error:
                break
            case .message(let responseMessage, _):
                let end = DispatchTime.now()
                let bytesReceived = responseMessage.payload?.data.count ?? 0
                let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
                let timeInterval = Double(nanoTime) / 1_000_000_000
                let bytesSent = requestMessage.payload?.data.count ?? 0
                let bytesTotal = bytesSent + bytesReceived
                let bytesPerSecond = Double(bytesTotal) / timeInterval
//                print("Took \(timeInterval * 1000) ms to transfer \(bytesTotal) bytes")
                speed = bytesPerSecond
            }
            transferCompleted.fulfill()
        }
        _ = try? coalaClient.send(requestMessage)
        waitForExpectations(timeout: 160, handler: nil)
        return speed
    }

    enum Direction {
        case block1, block2//, duplex
    }

    func printCSVLocal(direction: Direction) {
        var rxBytes = 0
        let resourceBlock1 = CoAPResource(method: .post, path: "/large") { _, _ in
            return (.changed, nil)
        }
        let resourceBlock2 = CoAPResource(method: .get, path: "/large") { _, _ in
            return (.content, Data.randomData(length: rxBytes))
        }
        coalaServer.addResource(resourceBlock1)
        coalaServer.addResource(resourceBlock2)
        let url = URL(string: "coap://localhost:\(serverPort)/large")!
        let kBytes = [30, 100, 300, 1000, 3000]
        let dataSizes = kBytes.map { $0 * 1024 }
        let windowSizes = [1, 3, 6, 10, 30, 60]
        print("," + dataSizes.map({ "\(formatter.string(fromByteCount: Int64($0)))," }).joined())
        for windowSize in windowSizes {
            coalaClient.layerStack.arqLayer.defaultSendWindowSize = windowSize
            coalaServer.layerStack.arqLayer.defaultSendWindowSize = windowSize
            var line = "Window size: \(windowSize),"
            for bytes in dataSizes {
                let txBytes: Int
                switch direction {
                case .block1:
                    txBytes = bytes
                    rxBytes = 0
                case .block2:
                    txBytes = 0
                    rxBytes = bytes
//                case .duplex:
//                    txBytes = bytes / 2
//                    rxBytes = bytes / 2
                }
                var speeds: [Double] = []
                let iterations = 1
                for _ in 1...iterations {
//                    print("test: windowSize \(windowSize), dataSize bytes: \(bytes)")
                    if let speed = testPerformance(direction: direction, size: txBytes, toUrl: url) {
                        speeds.append(speed)
//                        print("speed \(speed)")
                    }
                }
                if speeds == [] {
                    speeds = [0]
                }
                let averageSpeed = speeds.reduce(0.0, +) / Double(speeds.count)
                line.append("\(averageSpeed),")
//                let speedString = formatter.string(fromByteCount: Int64(averageSpeed)) + "/s, or \(averageSpeed) b/s"
//                print("Average speed for transferring \(kBytes) kb: \(speedString)")
            }
            print(line)
        }
    }

    func testLocalBlock1() {
        printCSVLocal(direction: .block1)
    }

    func testLocalBlock2() {
        printCSVLocal(direction: .block2)
    }

//    func testLocalDuplex() {
//        printCSVLocal(direction: .duplex)
//    }

}
