import XCTest
@testable import Coala

final class LoggingTests: XCTestCase {

    private var originalLogger: CoalaLogger?

    override func setUp() {
        super.setUp()
        originalLogger = Coala.logger
    }

    override func tearDown() {
        Coala.logger = originalLogger
        originalLogger = nil
        super.tearDown()
    }

    func testOriginalCallerAndContextReachProtocolWitness() {
        let logger = RecordingLogger()
        Coala.logger = logger
        let line = UInt(#line + 1)
        LogInfo("Device connection restored", context: ["attempts": 3])

        let record = logger.records[0]
        XCTAssertEqual(record.message, "Device connection restored")
        XCTAssertEqual(record.context["attempts"] as? Int, 3)
        XCTAssertEqual(record.file, #file)
        XCTAssertEqual(record.function, #function)
        XCTAssertEqual(record.line, line)
    }

    func testAllWrappersForwardTheirLevelAndExplicitSynchronization() {
        let logger = RecordingLogger()
        Coala.logger = logger

        LogVerbose("verbose", asynchronous: false, context: ["index": 0])
        LogDebug("debug", asynchronous: false, context: ["index": 1])
        LogInfo("info", asynchronous: false, context: ["index": 2])
        LogWarn("warning", asynchronous: false, context: ["index": 3])
        LogError("error", asynchronous: false, context: ["index": 4])

        XCTAssertEqual(logger.records.map(\.level), [.verbose, .debug, .info, .warning, .error])
        XCTAssertEqual(logger.records.map(\.asynchronous), [false, false, false, false, false])
        XCTAssertEqual(logger.records.compactMap { $0.context["index"] as? Int }, [0, 1, 2, 3, 4])
    }

    func testContextualCallFallsBackToLegacyRequirementExactlyOnce() {
        let logger = LegacyLogger()
        Coala.logger = logger

        LogWarn("Recovery delayed", asynchronous: false, context: ["attempts": 2])

        XCTAssertEqual(logger.records.count, 1)
        XCTAssertEqual(logger.records[0].message, "Recovery delayed")
        XCTAssertEqual(logger.records[0].level, .warning)
        XCTAssertFalse(logger.records[0].asynchronous)
    }

    func testExistingPositionalAndLabeledCallsRemainAvailable() {
        let logger = RecordingLogger()
        Coala.logger = logger

        LogDebug("positional")
        LogInfo("labeled", asynchronous: false)

        XCTAssertEqual(logger.records.map(\.message), ["positional", "labeled"])
        XCTAssertEqual(logger.records.map(\.asynchronous), [true, false])
        XCTAssertEqual(logger.records.map(\.context.count), [0, 0])
    }

    func testInvalidContextKeepsValidSiblingsAndCopiesMutableValues() {
        let nested = NSMutableDictionary(dictionary: ["attempts": 3, "connected": true])
        let result = LogContext.normalize([
            "nested": nested, "invalid": Date(), "not_finite": Double.nan
        ])
        nested["attempts"] = 99

        let saved = result["nested"] as? [String: Any]
        XCTAssertEqual(saved?["attempts"] as? Int, 3)
        XCTAssertEqual(saved?["connected"] as? Bool, true)
        XCTAssertNil(result["invalid"])
        XCTAssertNil(result["not_finite"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }

    func testNestedCollectionsOmitInvalidElementsAndKeepJSONNull() {
        let nestedObject = NSDictionary(objects: ["value", Date()], forKeys: ["valid" as NSString, 7 as NSNumber])
        let result = LogContext.normalize([
            "values": [1, Date(), ["connected": true, "data": Data([1, 2])]],
            "object": nestedObject,
            "null": NSNull(),
            "unsupported": NSObject()
        ])

        let values = result["values"] as? [Any]
        XCTAssertEqual(values?.count, 2)
        XCTAssertEqual(values?.first as? Int, 1)
        XCTAssertEqual((values?.last as? [String: Any])?["connected"] as? Bool, true)
        XCTAssertNil((values?.last as? [String: Any])?["data"])
        XCTAssertEqual((result["object"] as? [String: Any])?["valid"] as? String, "value")
        XCTAssertTrue(result["null"] is NSNull)
        XCTAssertNil(result["unsupported"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }

    func testFiniteNumbersAndBooleansSurviveJSONRoundTrip() {
        let result = LogContext.normalize([
            "integer": Int64.max,
            "double": 12.5,
            "true": true,
            "false": false,
            "infinity": Double.infinity
        ])

        XCTAssertEqual((result["integer"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertEqual((result["double"] as? NSNumber)?.doubleValue, 12.5)
        XCTAssertEqual((result["true"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((result["false"] as? NSNumber)?.boolValue, false)
        XCTAssertNil(result["infinity"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }

    func testNormalizationStopsDescendingAfterSixteenLevels() {
        var boundary: Any = "survives"
        var beyond: Any = "omitted"
        for _ in 0..<16 {
            boundary = [boundary]
        }
        for _ in 0..<17 {
            beyond = [beyond]
        }

        let result = LogContext.normalize(["boundary": boundary, "beyond": beyond])
        var currentBoundary = result["boundary"]
        var currentBeyond = result["beyond"]
        for _ in 0..<16 {
            let boundaryArray = currentBoundary as? [Any]
            let beyondArray = currentBeyond as? [Any]
            XCTAssertEqual(boundaryArray?.count, 1)
            if let next = beyondArray?.first {
                currentBeyond = next
            } else {
                XCTAssertEqual(beyondArray?.count, 0)
                currentBeyond = nil
            }
            currentBoundary = boundaryArray?.first
        }

        XCTAssertEqual(currentBoundary as? String, "survives")
        XCTAssertNil(currentBeyond)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }

    func testErrorContextIsOneReasonWithoutDescriptions() {
        let error = NSError(
            domain: "test.domain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "private description", "token": "secret"]
        )

        let context = LogContext.error(error, ["message_id": 7])

        XCTAssertEqual(Set(context.keys), ["reason", "message_id"])
        XCTAssertEqual(context["reason"] as? String, "test.domain 42")
        XCTAssertFalse(String(describing: context).contains("private description"))
        XCTAssertFalse(String(describing: context).contains("secret"))
    }

    func testSwiftErrorReasonIsTheCaseNameWithoutPayload() {
        XCTAssertEqual(LogContext.reason(SecurityLayer.SecurityLayerError.sessionNotEstablished),
                       "session_not_established")
        XCTAssertEqual(LogContext.reason(CoAPMessagePoolError.messageExpired(Address(host: "10.0.0.1", port: 1))),
                       "message_expired")
        XCTAssertEqual(LogContext.error(CoalaError.portIsBusy, ["reason": "explicit"])["reason"] as? String,
                       "explicit", "an explicit reason wins")
    }
}

final class RecordingLogger: CoalaLogger {

    struct Record {
        let message: String
        let level: LogLevel
        let asynchronous: Bool
        let context: [String: Any]
        let file: String
        let function: String
        let line: UInt
    }

    private let lock = NSLock()
    private var storedRecords: [Record] = []

    var records: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords
    }

    func log(_ message: String, level: LogLevel, asynchronous: Bool) {
        log(message, level: level, asynchronous: asynchronous,
            context: [:], file: "", function: "", line: 0)
    }

    // swiftlint:disable function_parameter_count
    func log(_ message: String, level: LogLevel, asynchronous: Bool,
             context: [String: Any], file: String, function: String, line: UInt) {
        lock.lock()
        defer { lock.unlock() }
        storedRecords.append(Record(
            message: message,
            level: level,
            asynchronous: asynchronous,
            context: context,
            file: file,
            function: function,
            line: line
        ))
    }
    // swiftlint:enable function_parameter_count
}

private final class LegacyLogger: CoalaLogger {

    struct Record {
        let message: String
        let level: LogLevel
        let asynchronous: Bool
    }

    private let lock = NSLock()
    private var storedRecords: [Record] = []

    var records: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords
    }

    func log(_ message: String, level: LogLevel, asynchronous: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storedRecords.append(Record(message: message, level: level, asynchronous: asynchronous))
    }
}
