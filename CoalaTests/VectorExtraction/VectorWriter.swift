import Foundation
import XCTest
@testable import Coala

/// Shared helper for the cross-implementation vector extraction suites.
/// Serializes cases to JSON, compares against the committed fixture, and
/// FAILS while rewriting the file when they differ (drift). Passing means the
/// committed oracle matches freshly-generated Swift output.
enum VectorWriter {

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Walk up from the harness source file until a directory containing
    /// `coala-rust/vectors` is found. Robust to repo-relative layout changes.
    static func vectorsDir(from file: StaticString = #file) -> URL? {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("coala-rust/vectors")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    static func emit(category: String,
                     generator: String,
                     cases: [[String: Any]],
                     file: StaticString = #file,
                     line: UInt = #line) {
        // Device sandboxes cannot reach the repo path; only the Simulator can.
        guard let dir = vectorsDir(from: file) else {
            XCTFail("vectors dir not found from \(file) — run on the Simulator, not a device",
                    file: file, line: line)
            return
        }
        let envelope: [String: Any] = [
            "category": category,
            "generator": generator,
            "swift_commit": swiftCommit(),
            "cases": cases,
        ]
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .prettyPrinted])
        let url = dir.appendingPathComponent("\(category).json")

        let existing = try? Data(contentsOf: url)
        if existing == data { return } // no drift
        // swiftlint:disable:next force_try
        try! data.write(to: url)
        XCTFail("vectors '\(category)' regenerated (drift or first run) — review and commit \(url.lastPathComponent)",
                file: file, line: line)
    }

    /// Recorded into the envelope for provenance. Read from the committed file
    /// if present so regeneration does not thrash the field between runs.
    private static func swiftCommit() -> String {
        return ProcessInfo.processInfo.environment["COALA_VECTOR_COMMIT"] ?? "unknown"
    }
}
