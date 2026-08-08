import Foundation

public struct HookConfigurationManager {
    public init() {}

    public func install(helperSource: URL, homeDirectory: URL, timestamp: Date) throws {
        let cursorURL = homeDirectory.appendingPathComponent(".cursor/hooks.json")
        let claudeURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        let helperURL = installedHelperURL(homeDirectory: homeDirectory)

        let cursor = try loadConfiguration(at: cursorURL)
        let claude = try loadConfiguration(at: claudeURL)
        let updatedCursor = try installingCursorHooks(in: cursor.object, command: "\(helperURL.path) capture cursor")
        let updatedClaude = try installingClaudeHooks(in: claude.object, command: "\(helperURL.path) capture claude")

        try installHelper(from: helperSource, to: helperURL)
        try writeIfChanged(updatedCursor, replacing: cursor, at: cursorURL, timestamp: timestamp)
        try writeIfChanged(updatedClaude, replacing: claude, at: claudeURL, timestamp: timestamp)
    }

    public func uninstall(homeDirectory: URL, timestamp: Date) throws {
        let cursorURL = homeDirectory.appendingPathComponent(".cursor/hooks.json")
        let claudeURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        let helperURL = installedHelperURL(homeDirectory: homeDirectory)

        let cursor = try loadConfiguration(at: cursorURL)
        let claude = try loadConfiguration(at: claudeURL)
        let updatedCursor = try uninstallingCursorHooks(in: cursor.object, command: "\(helperURL.path) capture cursor")
        let updatedClaude = try uninstallingClaudeHooks(in: claude.object, command: "\(helperURL.path) capture claude")

        try writeIfChanged(updatedCursor, replacing: cursor, at: cursorURL, timestamp: timestamp)
        try writeIfChanged(updatedClaude, replacing: claude, at: claudeURL, timestamp: timestamp)
        if FileManager.default.fileExists(atPath: helperURL.path) {
            try FileManager.default.removeItem(at: helperURL)
        }
    }
}

private extension HookConfigurationManager {
    static let cursorEvents = [
        "sessionStart", "beforeSubmitPrompt", "afterFileEdit", "postToolUse", "postToolUseFailure",
        "subagentStart", "subagentStop", "stop", "sessionEnd",
    ]
    static let claudeEvents = [
        "SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "SubagentStart",
        "SubagentStop", "Stop", "SessionEnd", "CwdChanged",
    ]

    struct Configuration {
        let object: [String: Any]
        let existed: Bool
    }

    enum ConfigurationError: LocalizedError {
        case rootIsNotJSONObject(URL)
        case hooksIsNotJSONObject(URL)
        case eventIsNotArray(String, URL)

        var errorDescription: String? {
            switch self {
            case let .rootIsNotJSONObject(url): return "Expected JSON object in \(url.path)"
            case let .hooksIsNotJSONObject(url): return "Expected hooks object in \(url.path)"
            case let .eventIsNotArray(event, url): return "Expected \(event) hooks array in \(url.path)"
            }
        }
    }

    func installedHelperURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/AgentActivity/bin/AgentActivityHook")
    }

    func loadConfiguration(at url: URL) throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Configuration(object: [:], existed: false)
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError.rootIsNotJSONObject(url)
        }
        return Configuration(object: object, existed: true)
    }

    func installingCursorHooks(in object: [String: Any], command: String) throws -> [String: Any] {
        var result = object
        var hooks = try hooksObject(from: result, configURL: URL(fileURLWithPath: ".cursor/hooks.json"))
        result["version"] = 1
        for event in Self.cursorEvents {
            var entries = try eventEntries(named: event, in: hooks, configURL: URL(fileURLWithPath: ".cursor/hooks.json"))
            entries = keepingOneCommand(command, in: entries)
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    func installingClaudeHooks(in object: [String: Any], command: String) throws -> [String: Any] {
        var result = object
        var events = try hooksObject(from: result, configURL: URL(fileURLWithPath: ".claude/settings.json"))
        for event in Self.claudeEvents {
            var groups = try eventEntries(named: event, in: events, configURL: URL(fileURLWithPath: ".claude/settings.json"))
            groups = keepingOneClaudeCommand(command, in: groups)
            events[event] = groups
        }
        result["hooks"] = events
        return result
    }

    func uninstallingCursorHooks(in object: [String: Any], command: String) throws -> [String: Any] {
        guard object["hooks"] != nil else { return object }
        var result = object
        var hooks = try hooksObject(from: result, configURL: URL(fileURLWithPath: ".cursor/hooks.json"))
        for event in Self.cursorEvents {
            guard var entries = hooks[event] as? [[String: Any]] else {
                if hooks[event] != nil { throw ConfigurationError.eventIsNotArray(event, URL(fileURLWithPath: ".cursor/hooks.json")) }
                continue
            }
            entries.removeAll { entry in isOwnedCommand(entry["command"] as? String, stable: command, provider: "cursor") }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        result["hooks"] = hooks
        return result
    }

    func uninstallingClaudeHooks(in object: [String: Any], command: String) throws -> [String: Any] {
        guard object["hooks"] != nil else { return object }
        var result = object
        var events = try hooksObject(from: result, configURL: URL(fileURLWithPath: ".claude/settings.json"))
        for event in Self.claudeEvents {
            guard var groups = events[event] as? [[String: Any]] else {
                if events[event] != nil { throw ConfigurationError.eventIsNotArray(event, URL(fileURLWithPath: ".claude/settings.json")) }
                continue
            }
            groups = groups.compactMap { originalGroup in
                var group = originalGroup
                guard var commands = group["hooks"] as? [[String: Any]] else { return group }
                let hadOwnedCommand = commands.contains { isOwnedCommand($0["command"] as? String, stable: command, provider: "claude") }
                commands.removeAll { isOwnedCommand($0["command"] as? String, stable: command, provider: "claude") }
                if hadOwnedCommand && commands.isEmpty { return nil }
                group["hooks"] = commands
                return group
            }
            if groups.isEmpty { events.removeValue(forKey: event) } else { events[event] = groups }
        }
        result["hooks"] = events
        return result
    }

    func hooksObject(from object: [String: Any], configURL: URL) throws -> [String: Any] {
        guard let hooks = object["hooks"] else { return [:] }
        guard let dictionary = hooks as? [String: Any] else { throw ConfigurationError.hooksIsNotJSONObject(configURL) }
        return dictionary
    }

    func eventEntries(named event: String, in hooks: [String: Any], configURL: URL) throws -> [[String: Any]] {
        guard let entries = hooks[event] else { return [] }
        guard let array = entries as? [[String: Any]] else { throw ConfigurationError.eventIsNotArray(event, configURL) }
        return array
    }

    func keepingOneCommand(_ command: String, in entries: [[String: Any]]) -> [[String: Any]] {
        var found = false
        var result = entries.filter { entry in
            guard entry["command"] as? String == command else { return true }
            defer { found = true }
            return !found
        }
        if !found { result.append(["command": command]) }
        return result
    }

    func keepingOneClaudeCommand(_ command: String, in groups: [[String: Any]]) -> [[String: Any]] {
        var found = false
        var result: [[String: Any]] = []
        for var group in groups {
            guard var commands = group["hooks"] as? [[String: Any]] else {
                result.append(group)
                continue
            }
            commands = commands.filter { hook in
                guard hook["command"] as? String == command else { return true }
                defer { found = true }
                return !found
            }
            group["hooks"] = commands
            result.append(group)
        }
        if !found {
            result.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
        }
        return result
    }

    func isOwnedCommand(_ command: String?, stable: String, provider: String) -> Bool {
        command == stable || command == "agent_activity_hook.sh \(provider)"
    }

    func installHelper(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if source.standardizedFileURL != destination.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: source, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    func writeIfChanged(_ updated: [String: Any], replacing original: Configuration, at url: URL, timestamp: Date) throws {
        guard !jsonObjectsEqual(updated, original.object) else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if original.existed {
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).agentactivity-backup-\(backupTimestamp(timestamp))")
            if !fileManager.fileExists(atPath: backup.path) { try fileManager.copyItem(at: url, to: backup) }
        }
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).agentactivity-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary)
        guard (try JSONSerialization.jsonObject(with: Data(contentsOf: temporary))) is [String: Any] else {
            throw ConfigurationError.rootIsNotJSONObject(temporary)
        }
        if original.existed {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else { return false }
        return left == right
    }

    func backupTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
