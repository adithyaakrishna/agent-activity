import Foundation

enum HookConfigurationMutation: Equatable {
  case replaceHelper
  case replaceCursor
  case replaceClaude
  case removeHelper
}

public struct HookConfigurationManager {
  private let failBeforeMutation: (HookConfigurationMutation) throws -> Void

  public init() {
    failBeforeMutation = { _ in }
  }

  init(failBeforeMutation: @escaping (HookConfigurationMutation) throws -> Void) {
    self.failBeforeMutation = failBeforeMutation
  }

  public func install(helperSource: URL, homeDirectory: URL, timestamp: Date) throws {
    let cursorURL = homeDirectory.appendingPathComponent(".cursor/hooks.json")
    let claudeURL = homeDirectory.appendingPathComponent(".claude/settings.json")
    let helperURL = installedHelperURL(homeDirectory: homeDirectory)

    let cursor = try loadConfiguration(at: cursorURL)
    let claude = try loadConfiguration(at: claudeURL)
    let updatedCursor = try installingCursorHooks(
      in: cursor.object, at: cursorURL, helperURL: helperURL)
    let updatedClaude = try installingClaudeHooks(
      in: claude.object, at: claudeURL, helperURL: helperURL)

    var prepared: [PreparedFile] = []
    do {
      prepared.append(try prepareHelper(from: helperSource, to: helperURL))
      if let cursorFile = try prepareConfiguration(
        updatedCursor,
        replacing: cursor,
        at: cursorURL,
        timestamp: timestamp,
        mutation: .replaceCursor
      ) {
        prepared.append(cursorFile)
      }
      if let claudeFile = try prepareConfiguration(
        updatedClaude,
        replacing: claude,
        at: claudeURL,
        timestamp: timestamp,
        mutation: .replaceClaude
      ) {
        prepared.append(claudeFile)
      }
      try commit(prepared)
    } catch {
      cleanup(prepared)
      throw error
    }
  }

  public func uninstall(homeDirectory: URL, timestamp: Date) throws {
    let cursorURL = homeDirectory.appendingPathComponent(".cursor/hooks.json")
    let claudeURL = homeDirectory.appendingPathComponent(".claude/settings.json")
    let helperURL = installedHelperURL(homeDirectory: homeDirectory)

    let cursor = try loadConfiguration(at: cursorURL)
    let claude = try loadConfiguration(at: claudeURL)
    let updatedCursor = try uninstallingCursorHooks(
      in: cursor.object, at: cursorURL, helperURL: helperURL)
    let updatedClaude = try uninstallingClaudeHooks(
      in: claude.object, at: claudeURL, helperURL: helperURL)

    var prepared: [PreparedFile] = []
    var helperRemoval: PreparedRemoval?
    do {
      if let cursorFile = try prepareConfiguration(
        updatedCursor,
        replacing: cursor,
        at: cursorURL,
        timestamp: timestamp,
        mutation: .replaceCursor
      ) {
        prepared.append(cursorFile)
      }
      if let claudeFile = try prepareConfiguration(
        updatedClaude,
        replacing: claude,
        at: claudeURL,
        timestamp: timestamp,
        mutation: .replaceClaude
      ) {
        prepared.append(claudeFile)
      }
      helperRemoval = try prepareRemoval(at: helperURL)
      try commit(prepared, then: helperRemoval)
    } catch {
      cleanup(prepared)
      if let helperRemoval { cleanup(helperRemoval) }
      throw error
    }
  }
}

extension HookConfigurationManager {
  fileprivate static let cursorEvents = [
    "sessionStart", "beforeSubmitPrompt", "afterFileEdit", "postToolUse", "postToolUseFailure",
    "subagentStart", "subagentStop", "stop", "sessionEnd",
  ]
  fileprivate static let claudeEvents = [
    "SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "SubagentStart",
    "SubagentStop", "Stop", "SessionEnd", "CwdChanged",
  ]

  fileprivate struct Configuration {
    let object: [String: Any]
    let existed: Bool
  }

  fileprivate struct PreparedFile {
    let target: URL
    let staged: URL
    let rollback: URL?
    let existed: Bool
    let mutation: HookConfigurationMutation
    let backupTimestamp: Date?
  }

  fileprivate struct PreparedRemoval {
    let target: URL
    let rollback: URL
  }

  fileprivate enum ConfigurationError: LocalizedError {
    case rootIsNotJSONObject(URL)
    case hooksIsNotJSONObject(URL)
    case eventIsNotArray(String, URL)

    var errorDescription: String? {
      switch self {
      case .rootIsNotJSONObject(let url): return "Expected JSON object in \(url.path)"
      case .hooksIsNotJSONObject(let url): return "Expected hooks object in \(url.path)"
      case .eventIsNotArray(let event, let url):
        return "Expected \(event) hooks array in \(url.path)"
      }
    }
  }

  fileprivate func installedHelperURL(homeDirectory: URL) -> URL {
    homeDirectory.appendingPathComponent(
      "Library/Application Support/AgentActivity/bin/AgentActivityHook")
  }

  fileprivate func loadConfiguration(at url: URL) throws -> Configuration {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return Configuration(object: [:], existed: false)
    }
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ConfigurationError.rootIsNotJSONObject(url)
    }
    return Configuration(object: object, existed: true)
  }

  fileprivate func installingCursorHooks(
    in object: [String: Any],
    at configURL: URL,
    helperURL: URL
  ) throws -> [String: Any] {
    var result = object
    var hooks = try hooksObject(from: result, configURL: configURL)
    let command = installedCommand(helperURL: helperURL, provider: "cursor")
    result["version"] = 1
    for event in Self.cursorEvents {
      let entries = try eventEntries(named: event, in: hooks, configURL: configURL)
      let sanitized = sanitizeCursorEntries(entries, helperURL: helperURL, provider: "cursor")
      hooks[event] = sanitized.entries + [["command": command]]
    }
    result["hooks"] = hooks
    return result
  }

  fileprivate func installingClaudeHooks(
    in object: [String: Any],
    at configURL: URL,
    helperURL: URL
  ) throws -> [String: Any] {
    var result = object
    var events = try hooksObject(from: result, configURL: configURL)
    let command = installedCommand(helperURL: helperURL, provider: "claude")
    for event in Self.claudeEvents {
      let groups = try eventEntries(named: event, in: events, configURL: configURL)
      let sanitized = sanitizeClaudeGroups(groups, helperURL: helperURL, provider: "claude")
      events[event] =
        sanitized.groups + [
          ["hooks": [["type": "command", "command": command, "timeout": 5]]]
        ]
    }
    result["hooks"] = events
    return result
  }

  fileprivate func uninstallingCursorHooks(
    in object: [String: Any],
    at configURL: URL,
    helperURL: URL
  ) throws -> [String: Any] {
    guard object["hooks"] != nil else { return object }
    var result = object
    var hooks = try hooksObject(from: result, configURL: configURL)
    for event in Self.cursorEvents {
      guard let value = hooks[event] else { continue }
      guard let entries = value as? [[String: Any]] else {
        throw ConfigurationError.eventIsNotArray(event, configURL)
      }
      let sanitized = sanitizeCursorEntries(entries, helperURL: helperURL, provider: "cursor")
      if sanitized.removedOwned && sanitized.entries.isEmpty {
        hooks.removeValue(forKey: event)
      } else {
        hooks[event] = sanitized.entries
      }
    }
    result["hooks"] = hooks
    return result
  }

  fileprivate func uninstallingClaudeHooks(
    in object: [String: Any],
    at configURL: URL,
    helperURL: URL
  ) throws -> [String: Any] {
    guard object["hooks"] != nil else { return object }
    var result = object
    var events = try hooksObject(from: result, configURL: configURL)
    for event in Self.claudeEvents {
      guard let value = events[event] else { continue }
      guard let groups = value as? [[String: Any]] else {
        throw ConfigurationError.eventIsNotArray(event, configURL)
      }
      let sanitized = sanitizeClaudeGroups(groups, helperURL: helperURL, provider: "claude")
      if sanitized.removedOwned && sanitized.groups.isEmpty {
        events.removeValue(forKey: event)
      } else {
        events[event] = sanitized.groups
      }
    }
    result["hooks"] = events
    return result
  }

  fileprivate func sanitizeCursorEntries(
    _ entries: [[String: Any]],
    helperURL: URL,
    provider: String
  ) -> (entries: [[String: Any]], removedOwned: Bool) {
    var removedOwned = false
    var result: [[String: Any]] = []
    for var entry in entries {
      guard isOwnedCommand(entry["command"] as? String, helperURL: helperURL, provider: provider)
      else {
        result.append(entry)
        continue
      }
      removedOwned = true
      if Set(entry.keys) == ["command"] { continue }
      entry.removeValue(forKey: "command")
      result.append(entry)
    }
    return (result, removedOwned)
  }

  fileprivate func sanitizeClaudeGroups(
    _ groups: [[String: Any]],
    helperURL: URL,
    provider: String
  ) -> (groups: [[String: Any]], removedOwned: Bool) {
    var removedOwned = false
    var result: [[String: Any]] = []
    for var group in groups {
      guard let hooks = group["hooks"] as? [[String: Any]] else {
        result.append(group)
        continue
      }
      let retained = hooks.filter { hook in
        let owned = isOwnedCommand(
          hook["command"] as? String, helperURL: helperURL, provider: provider)
        if owned { removedOwned = true }
        return !owned
      }
      let removedFromGroup = retained.count != hooks.count
      if removedFromGroup, retained.isEmpty, Set(group.keys) == ["hooks"] {
        continue
      }
      group["hooks"] = retained
      result.append(group)
    }
    return (result, removedOwned)
  }

  fileprivate func hooksObject(from object: [String: Any], configURL: URL) throws -> [String: Any] {
    guard let hooks = object["hooks"] else { return [:] }
    guard let dictionary = hooks as? [String: Any] else {
      throw ConfigurationError.hooksIsNotJSONObject(configURL)
    }
    return dictionary
  }

  fileprivate func eventEntries(named event: String, in hooks: [String: Any], configURL: URL) throws
    -> [[String: Any]]
  {
    guard let entries = hooks[event] else { return [] }
    guard let array = entries as? [[String: Any]] else {
      throw ConfigurationError.eventIsNotArray(event, configURL)
    }
    return array
  }

  fileprivate func installedCommand(helperURL: URL, provider: String) -> String {
    "\(posixShellQuote(helperURL.path)) capture \(provider)"
  }

  fileprivate func posixShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  fileprivate func isOwnedCommand(_ command: String?, helperURL: URL, provider: String) -> Bool {
    guard let command else { return false }
    let canonical = installedCommand(helperURL: helperURL, provider: provider)
    let oldUnquoted = "\(helperURL.path) capture \(provider)"
    if command == canonical || command == oldUnquoted { return true }
    guard let words = shellWords(command) else { return false }
    if words == [helperURL.path, "capture", provider] { return true }
    guard words.count == 2, words[1] == provider else { return false }
    if words[0] == "agent_activity_hook.sh" { return true }
    let normalizedLegacyPath = URL(fileURLWithPath: words[0]).standardizedFileURL.path
    return normalizedLegacyPath.hasSuffix("/AgentActivity/script/agent_activity_hook.sh")
  }

  fileprivate func shellWords(_ command: String) -> [String]? {
    indirect enum State {
      case unquoted
      case singleQuoted
      case doubleQuoted
      case escaped(State)
    }

    var state = State.unquoted
    var words: [String] = []
    var current = ""
    var hasToken = false

    func finishWord() {
      if hasToken {
        words.append(current)
        current = ""
        hasToken = false
      }
    }

    for character in command {
      switch state {
      case .unquoted:
        if character.isWhitespace {
          finishWord()
        } else if character == "'" {
          state = .singleQuoted
          hasToken = true
        } else if character == "\"" {
          state = .doubleQuoted
          hasToken = true
        } else if character == "\\" {
          state = .escaped(.unquoted)
          hasToken = true
        } else {
          current.append(character)
          hasToken = true
        }
      case .singleQuoted:
        if character == "'" {
          state = .unquoted
        } else {
          current.append(character)
        }
      case .doubleQuoted:
        if character == "\"" {
          state = .unquoted
        } else if character == "\\" {
          state = .escaped(.doubleQuoted)
        } else {
          current.append(character)
        }
      case .escaped(let previous):
        current.append(character)
        state = previous
      }
    }

    switch state {
    case .unquoted:
      finishWord()
      return words
    case .singleQuoted, .doubleQuoted, .escaped:
      return nil
    }
  }

  fileprivate func prepareHelper(from source: URL, to destination: URL) throws -> PreparedFile {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staged = temporarySibling(of: destination, label: "helper-stage")
    do {
      try fileManager.copyItem(at: source, to: staged)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
      let rollback = try prepareRollback(for: destination)
      return PreparedFile(
        target: destination,
        staged: staged,
        rollback: rollback,
        existed: fileManager.fileExists(atPath: destination.path),
        mutation: .replaceHelper,
        backupTimestamp: nil
      )
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
  }

  fileprivate func prepareConfiguration(
    _ updated: [String: Any],
    replacing original: Configuration,
    at url: URL,
    timestamp: Date,
    mutation: HookConfigurationMutation
  ) throws -> PreparedFile? {
    guard !jsonObjectsEqual(updated, original.object) else { return nil }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staged = temporarySibling(of: url, label: "config-stage")
    do {
      let data = try JSONSerialization.data(
        withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: staged)
      guard (try JSONSerialization.jsonObject(with: Data(contentsOf: staged))) is [String: Any]
      else {
        throw ConfigurationError.rootIsNotJSONObject(staged)
      }
      let rollback = try prepareRollback(for: url)
      return PreparedFile(
        target: url,
        staged: staged,
        rollback: rollback,
        existed: original.existed,
        mutation: mutation,
        backupTimestamp: timestamp
      )
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
  }

  fileprivate func prepareRollback(for target: URL) throws -> URL? {
    guard FileManager.default.fileExists(atPath: target.path) else { return nil }
    let rollback = temporarySibling(of: target, label: "rollback")
    try FileManager.default.copyItem(at: target, to: rollback)
    return rollback
  }

  fileprivate func prepareRemoval(at target: URL) throws -> PreparedRemoval? {
    guard let rollback = try prepareRollback(for: target) else { return nil }
    return PreparedRemoval(target: target, rollback: rollback)
  }

  fileprivate func commit(_ files: [PreparedFile], then removal: PreparedRemoval? = nil) throws {
    let fileManager = FileManager.default
    var applied: [PreparedFile] = []
    var createdBackups: [URL] = []
    var removalApplied = false

    do {
      for file in files {
        try failBeforeMutation(file.mutation)
        if let timestamp = file.backupTimestamp, file.existed {
          let backup = uniqueBackupURL(for: file.target, timestamp: timestamp)
          try fileManager.copyItem(at: file.target, to: backup)
          createdBackups.append(backup)
        }
        applied.append(file)
        try replaceTarget(with: file)
      }
      if let removal {
        try failBeforeMutation(.removeHelper)
        removalApplied = true
        try fileManager.removeItem(at: removal.target)
      }
    } catch {
      if removalApplied, let removal {
        restoreRemoval(removal)
      }
      for file in applied.reversed() {
        restore(file)
      }
      for backup in createdBackups {
        try? fileManager.removeItem(at: backup)
      }
      cleanup(files)
      if let removal { cleanup(removal) }
      throw error
    }

    cleanup(files)
    if let removal { cleanup(removal) }
  }

  fileprivate func replaceTarget(with file: PreparedFile) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: file.target.path) {
      _ = try fileManager.replaceItemAt(file.target, withItemAt: file.staged)
    } else {
      try fileManager.moveItem(at: file.staged, to: file.target)
    }
  }

  fileprivate func restore(_ file: PreparedFile) {
    let fileManager = FileManager.default
    if file.existed, let rollback = file.rollback {
      if fileManager.fileExists(atPath: file.target.path) {
        _ = try? fileManager.replaceItemAt(file.target, withItemAt: rollback)
      } else {
        try? fileManager.moveItem(at: rollback, to: file.target)
      }
    } else if fileManager.fileExists(atPath: file.target.path) {
      try? fileManager.removeItem(at: file.target)
    }
  }

  fileprivate func restoreRemoval(_ removal: PreparedRemoval) {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: removal.target.path) {
      _ = try? fileManager.replaceItemAt(removal.target, withItemAt: removal.rollback)
    } else {
      try? fileManager.copyItem(at: removal.rollback, to: removal.target)
    }
  }

  fileprivate func cleanup(_ files: [PreparedFile]) {
    for file in files {
      try? FileManager.default.removeItem(at: file.staged)
      if let rollback = file.rollback {
        try? FileManager.default.removeItem(at: rollback)
      }
    }
  }

  fileprivate func cleanup(_ removal: PreparedRemoval) {
    try? FileManager.default.removeItem(at: removal.rollback)
  }

  fileprivate func temporarySibling(of target: URL, label: String) -> URL {
    target.deletingLastPathComponent()
      .appendingPathComponent(
        ".\(target.lastPathComponent).agentactivity-\(label)-\(UUID().uuidString)")
  }

  fileprivate func uniqueBackupURL(for configURL: URL, timestamp: Date) -> URL {
    let directory = configURL.deletingLastPathComponent()
    let baseName =
      "\(configURL.lastPathComponent).agentactivity-backup-\(backupTimestamp(timestamp))"
    var candidate = directory.appendingPathComponent(baseName)
    var ordinal = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(baseName)-\(ordinal)")
      ordinal += 1
    }
    return candidate
  }

  fileprivate func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
      let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
    else { return false }
    return left == right
  }

  fileprivate func backupTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}
