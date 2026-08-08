import Foundation
import XCTest
@testable import AgentActivityHookCore

final class HookConfigurationManagerTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02 03:04:05 UTC

    func testInstallPreservesUnrelatedSettingsBacksUpExistingFilesAndIsIdempotent() throws {
        let home = try fixtureHome(
            cursorHooks: [
                "version": 1,
                "hooks": ["stop": [["command": "existing-cursor-tool"]]],
            ],
            claudeSettings: [
                "theme": "dark",
                "hooks": ["Stop": [["hooks": [["type": "command", "command": "existing-claude-tool"]]]]],
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = try fixtureHelper()
        defer { try? FileManager.default.removeItem(at: helper) }

        let manager = HookConfigurationManager()
        try manager.install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)
        try manager.install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)

        let cursor = try readJSONObject(home.appendingPathComponent(".cursor/hooks.json"))
        let claude = try readJSONObject(home.appendingPathComponent(".claude/settings.json"))
        let installedHelper = home.appendingPathComponent("Library/Application Support/AgentActivity/bin/AgentActivityHook")
        XCTAssertEqual(cursor["version"] as? Int, 1)
        XCTAssertEqual(cursorCommandCount(named: "\(installedHelper.path) capture cursor", in: cursor), 9)
        XCTAssertEqual(cursorCommandCount(named: "existing-cursor-tool", in: cursor), 1)
        XCTAssertEqual(claude["theme"] as? String, "dark")
        XCTAssertEqual(claudeCommandCount(named: "\(installedHelper.path) capture claude", in: claude), 9)
        XCTAssertEqual(claudeCommandCount(named: "existing-claude-tool", in: claude), 1)

        let backupSuffix = ".agentactivity-backup-20240102-030405"
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/hooks.json" + backupSuffix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json" + backupSuffix).path))

        XCTAssertEqual(try fileMode(installedHelper), 0o755)
        XCTAssertEqual(try Data(contentsOf: installedHelper), try Data(contentsOf: helper))
    }

    func testUninstallRemovesOnlyAgentActivityCommandsAndPrunesTheirEmptyContainers() throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installedHelper = home.appendingPathComponent("Library/Application Support/AgentActivity/bin/AgentActivityHook")
        let cursorCommand = "\(installedHelper.path) capture cursor"
        let claudeCommand = "\(installedHelper.path) capture claude"
        try writeJSONObject([
            "version": 1,
            "hooks": [
                "stop": [
                    ["command": cursorCommand],
                    ["command": "existing-cursor-tool"],
                    ["command": "agent_activity_hook.sh cursor"],
                ],
            ],
        ], to: home.appendingPathComponent(".cursor/hooks.json"))
        try writeJSONObject([
            "theme": "dark",
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": claudeCommand, "timeout": 5]]],
                    ["hooks": [["type": "command", "command": "existing-claude-tool"]]],
                    ["hooks": [["type": "command", "command": "agent_activity_hook.sh claude", "timeout": 5]]],
                ],
            ],
        ], to: home.appendingPathComponent(".claude/settings.json"))
        try FileManager.default.createDirectory(at: installedHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: installedHelper)

        try HookConfigurationManager().uninstall(homeDirectory: home, timestamp: fixedDate)

        let cursor = try readJSONObject(home.appendingPathComponent(".cursor/hooks.json"))
        let claude = try readJSONObject(home.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(cursorCommandCount(named: "existing-cursor-tool", in: cursor), 1)
        XCTAssertEqual(cursorCommandCount(in: cursor), 1)
        XCTAssertEqual(claude["theme"] as? String, "dark")
        XCTAssertEqual(claudeCommandCount(named: "existing-claude-tool", in: claude), 1)
        XCTAssertEqual(claudeCommandCount(in: claude), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedHelper.path))
    }

    func testInstallRejectsMalformedConfigBeforeCopyingHelperOrChangingEitherConfig() throws {
        let home = try fixtureHome(cursorHooks: ["version": 1, "hooks": [:]])
        defer { try? FileManager.default.removeItem(at: home) }
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("[not valid json".utf8)
        try malformed.write(to: claudeURL)
        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        let originalCursor = try Data(contentsOf: cursorURL)
        let helper = try fixtureHelper()
        defer { try? FileManager.default.removeItem(at: helper) }

        XCTAssertThrowsError(try HookConfigurationManager().install(helperSource: helper, homeDirectory: home, timestamp: fixedDate))

        XCTAssertEqual(try Data(contentsOf: cursorURL), originalCursor)
        XCTAssertEqual(try Data(contentsOf: claudeURL), malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/AgentActivity/bin/AgentActivityHook").path))
    }

    private func fixtureHome(cursorHooks: [String: Any]? = nil, claudeSettings: [String: Any]? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let cursorHooks {
            let url = home.appendingPathComponent(".cursor/hooks.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: cursorHooks, options: [.sortedKeys]).write(to: url)
        }
        if let claudeSettings {
            let url = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: claudeSettings, options: [.sortedKeys]).write(to: url)
        }
        return home
    }

    private func fixtureHelper() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("#!/bin/sh\necho helper\n".utf8).write(to: url)
        return url
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw NSError(domain: "HookConfigurationManagerTests", code: 1)
        }
        return object
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func cursorCommandCount(in object: [String: Any]) -> Int {
        cursorCommands(in: object).count
    }

    private func cursorCommandCount(named command: String, in object: [String: Any]) -> Int {
        cursorCommands(in: object).filter { $0 == command }.count
    }

    private func claudeCommandCount(in object: [String: Any]) -> Int {
        claudeCommands(in: object).count
    }

    private func claudeCommandCount(named command: String, in object: [String: Any]) -> Int {
        claudeCommands(in: object).filter { $0 == command }.count
    }

    private func cursorCommands(in object: [String: Any]) -> [String] {
        guard let hooks = object["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { event in
            ((event as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }
    }

    private func claudeCommands(in object: [String: Any]) -> [String] {
        guard let events = object["hooks"] as? [String: Any] else { return [] }
        return events.values.flatMap { event in
            ((event as? [[String: Any]]) ?? []).flatMap { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
            }
        }
    }

    private func fileMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
