import Foundation
import XCTest
@testable import AgentActivityHookCore

final class GitHeadInspectorTests: XCTestCase {
    func testStopsLargeOutputCommandAfterTimeout() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("large-output-command")
        try #"""
        #!/bin/sh
        i=0
        while [ "$i" -lt 40000 ]; do
          printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
          i=$((i + 1))
        done
        sleep 5
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let inspector = GitHeadInspector(commandTimeout: 0.05, executableURL: script)
        let startedAt = Date()
        XCTAssertNil(inspector.repositoryRoot(for: directory))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentActivityGitHeadInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
