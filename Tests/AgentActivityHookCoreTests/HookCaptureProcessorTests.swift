import Foundation
import XCTest
@testable import AgentActivityHookCore

final class HookCaptureProcessorTests: XCTestCase {
    func testCursorPayloadKeepsMetadataAndDropsContent() throws {
        let input = Data(#"{"conversation_id":"c-1","workspace_roots":["/tmp/repo"],"hook_event_name":"stop","prompt":"DO_NOT_STORE","response":"DO_NOT_STORE","command":"DO_NOT_STORE","tool_input":{"command":"DO_NOT_STORE"},"tool_response":"DO_NOT_STORE","transcript":"DO_NOT_STORE"}"#.utf8)

        let record = try HookCaptureProcessor(git: StubGitHeadInspector()).makeRecord(
            input: input,
            provider: .cursor,
            capturedAt: Date(timeIntervalSince1970: 0),
            environment: ["SECRET": "DO_NOT_STORE"]
        )

        XCTAssertEqual(record?["session_id"] as? String, "c-1")
        XCTAssertEqual(record?["repository_root"] as? String, "/tmp/repo")
        XCTAssertEqual(record?["event"] as? String, "stop")
        assertDoesNotStoreContent(record)
    }

    func testClaudePayloadKeepsMetadataAndDropsContent() throws {
        let input = Data(#"{"session_id":"s-1","cwd":"/tmp/repo","hook_event_name":"SessionEnd","transcript_path":"/Users/example/.claude/projects/work/transcript.jsonl","prompt":"DO_NOT_STORE","response":"DO_NOT_STORE","command":"DO_NOT_STORE","tool_input":{"command":"DO_NOT_STORE"},"tool_response":"DO_NOT_STORE","transcript":"DO_NOT_STORE"}"#.utf8)

        let record = try HookCaptureProcessor(git: StubGitHeadInspector()).makeRecord(
            input: input,
            provider: .claude,
            capturedAt: Date(timeIntervalSince1970: 0),
            environment: [:]
        )

        XCTAssertEqual(record?["session_id"] as? String, "s-1")
        XCTAssertEqual(record?["repository_root"] as? String, "/tmp/repo")
        XCTAssertEqual(record?["event"] as? String, "SessionEnd")
        assertDoesNotStoreContent(record)
    }

    func testClaudePayloadOutsideClaudeProjectsIsIgnored() throws {
        let input = Data(#"{"session_id":"s-1","cwd":"/tmp/repo","transcript_path":"/tmp/transcript.jsonl"}"#.utf8)

        let record = try HookCaptureProcessor(git: StubGitHeadInspector()).makeRecord(
            input: input,
            provider: .claude,
            capturedAt: Date(timeIntervalSince1970: 0),
            environment: [:]
        )

        XCTAssertNil(record)
    }

    func testHeadMetadataIsAttachedOnlyForAllowedEventAndValidSHA() throws {
        let input = Data(#"{"conversation_id":"c-1","workspace_roots":["/tmp/repo"],"hook_event_name":"stop"}"#.utf8)
        let validHead = GitHeadMetadata(
            sha: String(repeating: "a", count: 40),
            committedAt: Date(timeIntervalSince1970: 60),
            additions: 4,
            deletions: 2
        )
        let record = try XCTUnwrap(HookCaptureProcessor(git: StubGitHeadInspector(head: validHead)).makeRecord(
            input: input,
            provider: .cursor,
            capturedAt: Date(timeIntervalSince1970: 0),
            environment: [:]
        ))

        XCTAssertEqual(record["head_sha"] as? String, String(repeating: "a", count: 40))
        XCTAssertEqual((record["head_additions"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((record["head_deletions"] as? NSNumber)?.intValue, 2)

        let invalidRecord = try XCTUnwrap(HookCaptureProcessor(git: StubGitHeadInspector(head: GitHeadMetadata(
            sha: "not-a-sha",
            committedAt: Date(timeIntervalSince1970: 60),
            additions: 4,
            deletions: 2
        ))).makeRecord(
            input: input,
            provider: .cursor,
            capturedAt: Date(timeIntervalSince1970: 0),
            environment: [:]
        ))
        XCTAssertNil(invalidRecord["head_sha"])
    }

    private func assertDoesNotStoreContent(_ record: [String: Any]?) {
        let encoded = try? JSONSerialization.data(withJSONObject: record ?? [:])
        let text = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(text.contains("DO_NOT_STORE"))
        XCTAssertNil(record?["prompt"])
        XCTAssertNil(record?["response"])
        XCTAssertNil(record?["command"])
        XCTAssertNil(record?["tool_input"])
        XCTAssertNil(record?["tool_response"])
        XCTAssertNil(record?["transcript"])
    }
}

private struct StubGitHeadInspector: GitHeadInspecting {
    let head: GitHeadMetadata?

    init(head: GitHeadMetadata? = nil) {
        self.head = head
    }

    func repositoryRoot(for candidateDirectory: URL) -> URL? {
        candidateDirectory
    }

    func headMetadata(at repositoryRoot: URL) -> GitHeadMetadata? {
        head
    }
}
