import Foundation
import XCTest
@testable import AgentActivityHookCore

final class HookRecordStoreTests: XCTestCase {
    func testStoreWritesOwnerOnlyJSONLine() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try HookRecordStore(maxBytes: 1_024).append(
            ["provider": "cursor", "session_id": "c-1"],
            provider: .cursor,
            directory: directory
        )

        let file = directory.appendingPathComponent("cursor.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: file).split(separator: "\n").count, 1)
        XCTAssertEqual(try String(contentsOf: file), "{\"provider\":\"cursor\",\"session_id\":\"c-1\"}\n")
    }

    func testStoreRotatesAtLimitAndKeepsOneBackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HookRecordStore(maxBytes: 50)

        try store.append(["session_id": "first", "provider": "cursor"], provider: .cursor, directory: directory)
        try store.append(["session_id": "second", "provider": "cursor"], provider: .cursor, directory: directory)
        try store.append(["session_id": "third", "provider": "cursor"], provider: .cursor, directory: directory)

        let active = try String(contentsOf: directory.appendingPathComponent("cursor.jsonl"))
        let backup = try String(contentsOf: directory.appendingPathComponent("cursor.jsonl.1"))
        XCTAssertTrue(active.contains("third"))
        XCTAssertTrue(backup.contains("second"))
        XCTAssertFalse(backup.contains("first"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cursor.jsonl.2").path))
    }

    func testStoreRejectsSerializedLineLargerThanConfiguredLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try HookRecordStore(maxBytes: 50).append(
                ["provider": "cursor", "session_id": String(repeating: "x", count: 100)],
                provider: .cursor,
                directory: directory
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cursor.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cursor.jsonl.1").path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentActivityHookRecordStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
