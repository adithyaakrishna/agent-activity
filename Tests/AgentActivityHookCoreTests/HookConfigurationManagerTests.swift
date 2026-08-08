import Foundation
import XCTest
@testable import AgentActivityHookCore

final class HookConfigurationManagerTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02 03:04:05 UTC
    private let cursorEvents = [
        "sessionStart", "beforeSubmitPrompt", "afterFileEdit", "postToolUse", "postToolUseFailure",
        "subagentStart", "subagentStop", "stop", "sessionEnd",
    ]
    private let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "SubagentStart",
        "SubagentStop", "Stop", "SessionEnd", "CwdChanged",
    ]

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
        XCTAssertEqual(cursorCommandCount(named: expectedCommand(home: home, provider: "cursor"), in: cursor), 9)
        XCTAssertEqual(cursorCommandCount(named: "existing-cursor-tool", in: cursor), 1)
        XCTAssertEqual(claude["theme"] as? String, "dark")
        XCTAssertEqual(claudeCommandCount(named: expectedCommand(home: home, provider: "claude"), in: claude), 9)
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

    func testInstallQuotesCommandsForShellAndEveryGeneratedCommandExecutes() throws {
        let home = try fixtureHome(directoryName: "Owner's Hook Home \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = try fixtureHelper(contents: "#!/bin/sh\nprintf '%s|%s' \"$1\" \"$2\"\n")
        defer { try? FileManager.default.removeItem(at: helper) }

        try HookConfigurationManager().install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)

        let cursor = try readJSONObject(home.appendingPathComponent(".cursor/hooks.json"))
        let claude = try readJSONObject(home.appendingPathComponent(".claude/settings.json"))
        for event in cursorEvents {
            let command = try XCTUnwrap(cursorCommand(event: event, in: cursor))
            XCTAssertEqual(try executeShellCommand(command), "capture|cursor", "Cursor event \(event)")
        }
        for event in claudeEvents {
            let hook = try XCTUnwrap(claudeManagedHook(event: event, in: claude, home: home))
            XCTAssertEqual(hook["type"] as? String, "command", "Claude event \(event)")
            XCTAssertEqual(hook["timeout"] as? Int, 5, "Claude event \(event)")
            XCTAssertEqual(try executeShellCommand(try XCTUnwrap(hook["command"] as? String)), "capture|claude", "Claude event \(event)")
        }
    }

    func testInstallMigratesExactPathQualifiedLegacyCommandsAndPreservesNearMatches() throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = try fixtureHelper()
        defer { try? FileManager.default.removeItem(at: helper) }
        let cursorLegacy = "/Applications/AgentActivity/script/agent_activity_hook.sh cursor"
        let claudeLegacy = "'/Users/Example/Agent Activity/script/agent_activity_hook.sh' claude"
        let cursorNearMatches = [
            "/Applications/AgentActivity/script/agent_activity_hook.sh cursor --verbose",
            "/Applications/AgentActivity/script/not_agent_activity_hook.sh cursor",
            "/bin/echo /Applications/AgentActivity/script/agent_activity_hook.sh cursor",
        ]
        let claudeNearMatches = [
            "'/Users/Example/Agent Activity/script/agent_activity_hook.sh' claude --verbose",
            "'/Users/Example/Agent Activity/script/not_agent_activity_hook.sh' claude",
            "/bin/echo '/Users/Example/Agent Activity/script/agent_activity_hook.sh' claude",
        ]
        try writeJSONObject([
            "version": 1,
            "hooks": ["stop": ([cursorLegacy, "agent_activity_hook.sh cursor"] + cursorNearMatches).map { ["command": $0] }],
        ], to: home.appendingPathComponent(".cursor/hooks.json"))
        try writeJSONObject([
            "hooks": ["Stop": ([claudeLegacy, "agent_activity_hook.sh claude"] + claudeNearMatches).map {
                ["hooks": [["type": "command", "command": $0, "timeout": 5]]]
            }],
        ], to: home.appendingPathComponent(".claude/settings.json"))

        let manager = HookConfigurationManager()
        try manager.install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)

        var cursor = try readJSONObject(home.appendingPathComponent(".cursor/hooks.json"))
        var claude = try readJSONObject(home.appendingPathComponent(".claude/settings.json"))
        XCTAssertFalse(cursorCommands(in: cursor).contains(cursorLegacy))
        XCTAssertFalse(claudeCommands(in: claude).contains(claudeLegacy))
        XCTAssertEqual(cursorNearMatches.filter { cursorCommands(in: cursor).contains($0) }.count, cursorNearMatches.count)
        XCTAssertEqual(claudeNearMatches.filter { claudeCommands(in: claude).contains($0) }.count, claudeNearMatches.count)

        var cursorHooks = try XCTUnwrap(cursor["hooks"] as? [String: Any])
        var cursorStop = try XCTUnwrap(cursorHooks["stop"] as? [[String: Any]])
        cursorStop.append(["command": cursorLegacy])
        cursorHooks["stop"] = cursorStop
        cursor["hooks"] = cursorHooks
        try writeJSONObject(cursor, to: home.appendingPathComponent(".cursor/hooks.json"))
        var claudeHooks = try XCTUnwrap(claude["hooks"] as? [String: Any])
        var claudeStop = try XCTUnwrap(claudeHooks["Stop"] as? [[String: Any]])
        claudeStop.append(["hooks": [["type": "command", "command": claudeLegacy, "timeout": 5]]])
        claudeHooks["Stop"] = claudeStop
        claude["hooks"] = claudeHooks
        try writeJSONObject(claude, to: home.appendingPathComponent(".claude/settings.json"))

        try manager.uninstall(homeDirectory: home, timestamp: fixedDate)
        cursor = try readJSONObject(home.appendingPathComponent(".cursor/hooks.json"))
        claude = try readJSONObject(home.appendingPathComponent(".claude/settings.json"))
        XCTAssertFalse(cursorCommands(in: cursor).contains(cursorLegacy))
        XCTAssertFalse(claudeCommands(in: claude).contains(claudeLegacy))
        XCTAssertEqual(cursorNearMatches.filter { cursorCommands(in: cursor).contains($0) }.count, cursorNearMatches.count)
        XCTAssertEqual(claudeNearMatches.filter { claudeCommands(in: claude).contains($0) }.count, claudeNearMatches.count)
        XCTAssertFalse(cursorCommands(in: cursor).contains(expectedCommand(home: home, provider: "cursor")))
        XCTAssertFalse(claudeCommands(in: claude).contains(expectedCommand(home: home, provider: "claude")))
    }

    func testUninstallPreservesPreexistingEmptyContainersAndUnrelatedMetadata() throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = try fixtureHelper()
        defer { try? FileManager.default.removeItem(at: helper) }
        let manager = HookConfigurationManager()
        try manager.install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)
        let cursorCommand = expectedCommand(home: home, provider: "cursor")
        let claudeCommand = expectedCommand(home: home, provider: "claude")
        try writeJSONObject([
            "version": 1,
            "hooks": [
                "sessionStart": [],
                "stop": [["command": cursorCommand], ["command": "unrelated"]],
                "sessionEnd": [["command": cursorCommand, "marker": "keep"]],
            ],
        ], to: home.appendingPathComponent(".cursor/hooks.json"))
        try writeJSONObject([
            "theme": "dark",
            "hooks": [
                "SessionStart": [],
                "Stop": [
                    ["hooks": [["type": "command", "command": claudeCommand, "timeout": 5]]],
                    ["hooks": [["type": "command", "command": "unrelated"]]],
                    ["matcher": "keep", "hooks": [["type": "command", "command": claudeCommand, "timeout": 5]]],
                ],
                "SessionEnd": [["matcher": "preexisting", "hooks": []]],
            ],
        ], to: home.appendingPathComponent(".claude/settings.json"))

        try manager.uninstall(homeDirectory: home, timestamp: fixedDate)

        let cursor = try readJSONObject(home.appendingPathComponent(".cursor/hooks.json"))
        let cursorHooks = try XCTUnwrap(cursor["hooks"] as? [String: Any])
        XCTAssertNotNil(cursorHooks["sessionStart"])
        XCTAssertEqual((cursorHooks["sessionStart"] as? [Any])?.count, 0)
        XCTAssertEqual(cursorHooks["stop"] as? [[String: String]], [["command": "unrelated"]])
        XCTAssertEqual(cursorHooks["sessionEnd"] as? [[String: String]], [["marker": "keep"]])

        let claude = try readJSONObject(home.appendingPathComponent(".claude/settings.json"))
        let claudeHooks = try XCTUnwrap(claude["hooks"] as? [String: Any])
        XCTAssertNotNil(claudeHooks["SessionStart"])
        XCTAssertEqual((claudeHooks["SessionStart"] as? [Any])?.count, 0)
        let stopGroups = try XCTUnwrap(claudeHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopGroups.count, 2)
        XCTAssertEqual(stopGroups.first?["hooks"] as? [[String: String]], [["type": "command", "command": "unrelated"]])
        XCTAssertEqual(stopGroups.last?["matcher"] as? String, "keep")
        XCTAssertEqual((stopGroups.last?["hooks"] as? [Any])?.count, 0)
        XCTAssertEqual((claudeHooks["SessionEnd"] as? [[String: Any]])?.first?["matcher"] as? String, "preexisting")
    }

    func testReinstallCanonicalizesClaudeMetadataAndCreatesUniqueImmediateBackups() throws {
        let home = try fixtureHome(
            cursorHooks: ["version": 7, "hooks": [:], "marker": "original-cursor"],
            claudeSettings: ["hooks": [:], "marker": "original-claude"]
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = try fixtureHelper()
        defer { try? FileManager.default.removeItem(at: helper) }
        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        let originalCursor = try Data(contentsOf: cursorURL)
        let originalClaude = try Data(contentsOf: claudeURL)
        let manager = HookConfigurationManager()

        try manager.install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)
        XCTAssertEqual(try Data(contentsOf: backupURL(for: cursorURL, ordinal: 0)), originalCursor)
        XCTAssertEqual(try Data(contentsOf: backupURL(for: claudeURL, ordinal: 0)), originalClaude)

        var cursor = try readJSONObject(cursorURL)
        cursor["version"] = 9
        try writeJSONObject(cursor, to: cursorURL)
        var claude = try readJSONObject(claudeURL)
        claude = replacingManagedClaudeMetadata(in: claude, home: home, type: "prompt", timeout: 99)
        try writeJSONObject(claude, to: claudeURL)
        let cursorBeforeSecondInstall = try Data(contentsOf: cursorURL)
        let claudeBeforeSecondInstall = try Data(contentsOf: claudeURL)

        try manager.install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)

        XCTAssertEqual(try Data(contentsOf: backupURL(for: cursorURL, ordinal: 1)), cursorBeforeSecondInstall)
        XCTAssertEqual(try Data(contentsOf: backupURL(for: claudeURL, ordinal: 1)), claudeBeforeSecondInstall)
        let repairedClaude = try readJSONObject(claudeURL)
        for event in claudeEvents {
            let hook = try XCTUnwrap(claudeManagedHook(event: event, in: repairedClaude, home: home))
            XCTAssertEqual(hook["type"] as? String, "command", "Claude event \(event)")
            XCTAssertEqual(hook["timeout"] as? Int, 5, "Claude event \(event)")
        }
    }

    func testHelperReplacementFailureLeavesHelperAndBothConfigsUnchanged() throws {
        let fixture = try transactionalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        defer { try? FileManager.default.removeItem(at: fixture.source) }
        let manager = HookConfigurationManager(failBeforeMutation: { mutation in
            if mutation == .replaceHelper { throw InjectedFailure() }
        })

        XCTAssertThrowsError(try manager.install(helperSource: fixture.source, homeDirectory: fixture.home, timestamp: fixedDate))

        try assertFixtureUnchanged(fixture)
        XCTAssertTrue(try backupFiles(in: fixture.home).isEmpty)
    }

    func testSecondConfigReplacementFailureRollsBackHelperAndCursor() throws {
        let fixture = try transactionalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        defer { try? FileManager.default.removeItem(at: fixture.source) }
        let manager = HookConfigurationManager(failBeforeMutation: { mutation in
            if mutation == .replaceClaude { throw InjectedFailure() }
        })

        XCTAssertThrowsError(try manager.install(helperSource: fixture.source, homeDirectory: fixture.home, timestamp: fixedDate))

        try assertFixtureUnchanged(fixture)
        XCTAssertTrue(try backupFiles(in: fixture.home).isEmpty)
    }

    func testUninstallSecondConfigFailureRollsBackCursorAndKeepsHelper() throws {
        let home = try fixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = try fixtureHelper()
        defer { try? FileManager.default.removeItem(at: helper) }
        try HookConfigurationManager().install(helperSource: helper, homeDirectory: home, timestamp: fixedDate)
        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        let installedHelper = installedHelperURL(home: home)
        let cursorBefore = try Data(contentsOf: cursorURL)
        let claudeBefore = try Data(contentsOf: claudeURL)
        let helperBefore = try Data(contentsOf: installedHelper)
        let manager = HookConfigurationManager(failBeforeMutation: { mutation in
            if mutation == .replaceClaude { throw InjectedFailure() }
        })

        XCTAssertThrowsError(try manager.uninstall(homeDirectory: home, timestamp: fixedDate))

        XCTAssertEqual(try Data(contentsOf: cursorURL), cursorBefore)
        XCTAssertEqual(try Data(contentsOf: claudeURL), claudeBefore)
        XCTAssertEqual(try Data(contentsOf: installedHelper), helperBefore)
    }

    private struct InjectedFailure: Error {}

    private struct TransactionalFixture {
        let home: URL
        let source: URL
        let cursorURL: URL
        let claudeURL: URL
        let helperURL: URL
        let cursorData: Data
        let claudeData: Data
        let helperData: Data
    }

    private func fixtureHome(
        directoryName: String = UUID().uuidString,
        cursorHooks: [String: Any]? = nil,
        claudeSettings: [String: Any]? = nil
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
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

    private func fixtureHelper(contents: String = "#!/bin/sh\necho helper\n") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func transactionalFixture() throws -> TransactionalFixture {
        let home = try fixtureHome(
            cursorHooks: ["version": 1, "hooks": [:], "marker": "original-cursor"],
            claudeSettings: ["hooks": [:], "marker": "original-claude"]
        )
        let source = try fixtureHelper(contents: "#!/bin/sh\necho new-helper\n")
        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        let helperURL = installedHelperURL(home: home)
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helperData = Data("#!/bin/sh\necho old-helper\n".utf8)
        try helperData.write(to: helperURL)
        return TransactionalFixture(
            home: home,
            source: source,
            cursorURL: cursorURL,
            claudeURL: claudeURL,
            helperURL: helperURL,
            cursorData: try Data(contentsOf: cursorURL),
            claudeData: try Data(contentsOf: claudeURL),
            helperData: helperData
        )
    }

    private func assertFixtureUnchanged(_ fixture: TransactionalFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fixture.cursorURL), fixture.cursorData, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fixture.claudeURL), fixture.claudeData, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fixture.helperURL), fixture.helperData, file: file, line: line)
    }

    private func installedHelperURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/AgentActivity/bin/AgentActivityHook")
    }

    private func expectedCommand(home: URL, provider: String) -> String {
        let path = installedHelperURL(home: home).path.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(path)' capture \(provider)"
    }

    private func cursorCommand(event: String, in object: [String: Any]) -> String? {
        let hooks = object["hooks"] as? [String: Any]
        let entries = hooks?[event] as? [[String: Any]]
        return entries?.compactMap { $0["command"] as? String }.first(where: { $0.hasSuffix(" capture cursor") })
    }

    private func claudeManagedHook(event: String, in object: [String: Any], home: URL) -> [String: Any]? {
        let events = object["hooks"] as? [String: Any]
        let groups = events?[event] as? [[String: Any]]
        return groups?.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .first(where: { $0["command"] as? String == expectedCommand(home: home, provider: "claude") })
    }

    private func executeShellCommand(_ command: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Command failed: \(command)")
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func replacingManagedClaudeMetadata(
        in object: [String: Any],
        home: URL,
        type: String,
        timeout: Int
    ) -> [String: Any] {
        var result = object
        guard var events = result["hooks"] as? [String: Any] else { return result }
        let command = expectedCommand(home: home, provider: "claude")
        for event in claudeEvents {
            guard var groups = events[event] as? [[String: Any]] else { continue }
            for groupIndex in groups.indices {
                guard var hooks = groups[groupIndex]["hooks"] as? [[String: Any]] else { continue }
                for hookIndex in hooks.indices where hooks[hookIndex]["command"] as? String == command {
                    hooks[hookIndex]["type"] = type
                    hooks[hookIndex]["timeout"] = timeout
                }
                groups[groupIndex]["hooks"] = hooks
            }
            events[event] = groups
        }
        result["hooks"] = events
        return result
    }

    private func backupURL(for configURL: URL, ordinal: Int) -> URL {
        let base = configURL.deletingLastPathComponent()
            .appendingPathComponent("\(configURL.lastPathComponent).agentactivity-backup-20240102-030405")
        guard ordinal > 0 else { return base }
        return URL(fileURLWithPath: base.path + "-\(ordinal)")
    }

    private func backupFiles(in home: URL) throws -> [URL] {
        let cursorDirectory = home.appendingPathComponent(".cursor")
        let claudeDirectory = home.appendingPathComponent(".claude")
        return try [cursorDirectory, claudeDirectory].flatMap { directory in
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(".agentactivity-backup-") }
        }
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
