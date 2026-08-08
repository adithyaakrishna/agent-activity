import Foundation
import XCTest

@testable import AgentActivity

final class HookActivityImporterTests: XCTestCase {
  func testImportsProviderRootPromptsAgentsAndDeduplicatedCommits() throws {
    let inbox = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "AgentActivityHookImporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: inbox) }

    let hash = String(repeating: "a", count: 40)
    let records: [[String: Any]] = [
      [
        "schema_version": 1,
        "provider": "cursor",
        "captured_at": "2026-08-07T09:00:00Z",
        "event": "sessionStart",
        "session_id": "conversation-1",
        "repository_root": "/tmp/example-repository",
      ],
      [
        "schema_version": 1,
        "provider": "cursor",
        "captured_at": "2026-08-07T09:01:00Z",
        "event": "beforeSubmitPrompt",
        "session_id": "conversation-1",
        "repository_root": "/tmp/example-repository",
      ],
      [
        "schema_version": 1,
        "provider": "cursor",
        "captured_at": "2026-08-07T09:02:00Z",
        "event": "subagentStart",
        "session_id": "conversation-1",
        "agent_id": "subagent-1",
        "repository_root": "/tmp/example-repository",
      ],
      [
        "schema_version": 1,
        "provider": "cursor",
        "captured_at": "2026-08-07T09:05:00Z",
        "event": "stop",
        "session_id": "conversation-1",
        "repository_root": "/tmp/example-repository",
        "head_sha": hash,
        "head_committed_at": "2026-08-07T09:04:00Z",
        "head_additions": 21,
        "head_deletions": 5,
      ],
      [
        "schema_version": 1,
        "provider": "cursor",
        "captured_at": "2026-08-07T09:05:01Z",
        "event": "sessionEnd",
        "session_id": "conversation-1",
        "repository_root": "/tmp/example-repository",
        "head_sha": hash,
        "head_committed_at": "2026-08-07T09:04:00Z",
        "head_additions": 21,
        "head_deletions": 5,
      ],
    ]
    let contents =
      try records.map { record -> String in
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
      }.joined(separator: "\n") + "\n"
    try contents.write(
      to: inbox.appendingPathComponent("cursor.jsonl"),
      atomically: true,
      encoding: .utf8
    )

    let result = HookActivityImporter.load(
      source: .cursor,
      rangeStart: try XCTUnwrap(ISO8601Parser.date(from: "2026-08-07T00:00:00Z")),
      rangeEnd: try XCTUnwrap(ISO8601Parser.date(from: "2026-08-08T00:00:00Z")),
      inboxDirectory: inbox
    )

    let session = try XCTUnwrap(result.sessions.first)
    XCTAssertEqual(result.sessions.count, 1)
    XCTAssertEqual(session.id, "conversation-1")
    XCTAssertEqual(session.workingDirectory?.path, "/tmp/example-repository")
    XCTAssertEqual(session.workItems, 1)
    XCTAssertEqual(session.agentCount, 2)
    XCTAssertEqual(session.activeMinutes, 5)

    let commit = try XCTUnwrap(result.commits.first)
    XCTAssertEqual(result.commits.count, 1)
    XCTAssertEqual(commit.hash, hash)
    XCTAssertEqual(commit.additions, 21)
    XCTAssertEqual(commit.deletions, 5)
  }
}
