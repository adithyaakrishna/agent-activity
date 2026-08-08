import Foundation

enum LocalAgentActivityError: LocalizedError {
    case unsupportedSource
    case historyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            "This source does not expose local agent history"
        case let .historyUnavailable(path):
            "No readable activity history was found at \(path)"
        }
    }
}

enum LocalAgentActivityService {
    static func load(
        source: AgentSource,
        endingOn endDate: Date = Date()
    ) async throws -> ActivityHistoryResult {
        try await Task.detached(priority: .utility) {
            try loadSynchronously(source: source, endingOn: endDate)
        }.value
    }

    private static func loadSynchronously(
        source: AgentSource,
        endingOn endDate: Date
    ) throws -> ActivityHistoryResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [URL]
        switch source {
        case .cursor:
            roots = [home.appendingPathComponent(".cursor/projects", isDirectory: true)]
        case .codex:
            roots = [
                home.appendingPathComponent(".codex/sessions", isDirectory: true),
                home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            ]
        case .claude:
            roots = [home.appendingPathComponent(".claude/projects", isDirectory: true)]
        case .github, .others:
            throw LocalAgentActivityError.unsupportedSource
        }

        let calendar = utcCalendar
        let rangeEnd = calendar.startOfDay(for: endDate).addingTimeInterval(86_399)
        let rangeStart = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: endDate))!
        let files = historyFiles(in: roots, source: source, rangeStart: rangeStart, rangeEnd: rangeEnd)
        let historicalSessions = files.compactMap { file in
            parseSession(file, source: source, rangeStart: rangeStart, rangeEnd: rangeEnd)
        }
        let hookImport = HookActivityImporter.load(
            source: source,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
        var sessions = mergeSessions(historicalSessions, with: hookImport.sessions)

        guard !sessions.isEmpty else {
            throw LocalAgentActivityError.historyUnavailable(roots[0].path)
        }

        let commits = Array(
            Dictionary(
                (hookImport.commits + GitCommitCorrelator.commits(matching: sessions))
                    .map { ($0.hash, $0) },
                uniquingKeysWith: { existing, _ in existing }
            ).values
        )
        var metricsByDate: [String: ActivityDayMetrics] = [:]

        for session in sessions {
            let key = ActivityFormatters.dateKey.string(from: session.start)
            var metrics = metricsByDate[key, default: ActivityDayMetrics()]
            metrics.thingsWorkedOn += max(1, session.workItems)
            metrics.tokens += session.tokens
            metrics.agents = max(metrics.agents, session.agentCount)
            metrics.activeMinutes += session.activeMinutes
            metricsByDate[key] = metrics
        }

        for commit in commits {
            let key = ActivityFormatters.dateKey.string(from: commit.date)
            var metrics = metricsByDate[key, default: ActivityDayMetrics()]
            metrics.commits += 1
            metrics.additions += commit.additions
            metrics.deletions += commit.deletions
            metricsByDate[key] = metrics
        }

        sessions.removeAll(keepingCapacity: false)
        return ActivityDataFactory.make(from: metricsByDate, endingOn: endDate)
    }

    private static func mergeSessions(
        _ historical: [AgentSession],
        with hooked: [AgentSession]
    ) -> [AgentSession] {
        var anonymous = historical.filter { $0.id == nil }
        var byID = Dictionary(
            historical.compactMap { session in session.id.map { ($0, session) } },
            uniquingKeysWith: { existing, duplicate in
                AgentSession(
                    id: existing.id,
                    start: min(existing.start, duplicate.start),
                    end: max(existing.end, duplicate.end),
                    workingDirectory: existing.workingDirectory ?? duplicate.workingDirectory,
                    workItems: max(existing.workItems, duplicate.workItems),
                    tokens: max(existing.tokens, duplicate.tokens),
                    agentCount: max(existing.agentCount, duplicate.agentCount)
                )
            }
        )

        for hookSession in hooked {
            guard let id = hookSession.id else {
                anonymous.append(hookSession)
                continue
            }
            guard let existing = byID[id] else {
                byID[id] = hookSession
                continue
            }
            byID[id] = AgentSession(
                id: id,
                start: min(existing.start, hookSession.start),
                end: max(existing.end, hookSession.end),
                workingDirectory: hookSession.workingDirectory ?? existing.workingDirectory,
                workItems: hookSession.workItems > 0 ? hookSession.workItems : existing.workItems,
                tokens: max(existing.tokens, hookSession.tokens),
                agentCount: max(existing.agentCount, hookSession.agentCount)
            )
        }
        return anonymous + Array(byID.values)
    }

    private static func historyFiles(
        in roots: [URL],
        source: AgentSource,
        rangeStart: Date,
        rangeEnd: Date
    ) -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        var files: [URL] = []

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let file as URL in enumerator {
                guard file.pathExtension == "jsonl",
                      !file.path.contains("/subagents/"),
                      !file.lastPathComponent.contains("skill-injections") else { continue }
                if source == .cursor, !file.path.contains("/agent-transcripts/") { continue }

                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
                let created = values.creationDate ?? modified
                guard modified >= rangeStart, created <= rangeEnd else { continue }
                files.append(file)
            }
        }
        return files
    }

    private static func parseSession(
        _ file: URL,
        source: AgentSource,
        rangeStart: Date,
        rangeEnd: Date
    ) -> AgentSession? {
        switch source {
        case .cursor:
            parseCursorSession(file, rangeStart: rangeStart, rangeEnd: rangeEnd)
        case .codex:
            parseCodexSession(file, rangeStart: rangeStart, rangeEnd: rangeEnd)
        case .claude:
            parseClaudeSession(file, rangeStart: rangeStart, rangeEnd: rangeEnd)
        case .github, .others:
            nil
        }
    }

    private static func parseCursorSession(
        _ file: URL,
        rangeStart: Date,
        rangeEnd: Date
    ) -> AgentSession? {
        guard let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else {
            return nil
        }
        let start = values.creationDate ?? values.contentModificationDate ?? .distantPast
        let end = max(start, values.contentModificationDate ?? start)
        guard end >= rangeStart, start <= rangeEnd else { return nil }

        var userMessages = 0
        var toolUses = 0
        JSONLReader.read(file) { object in
            if object["role"] as? String == "user" { userMessages += 1 }
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            toolUses += content.filter { $0["type"] as? String == "tool_use" }.count
        }

        let subagentDirectory = file.deletingLastPathComponent().appendingPathComponent("subagents")
        let subagents = (try? FileManager.default.contentsOfDirectory(at: subagentDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }.count ?? 0

        return AgentSession(
            id: file.deletingPathExtension().lastPathComponent,
            start: start,
            end: end,
            workingDirectory: nil,
            workItems: max(userMessages, toolUses),
            tokens: 0,
            agentCount: 1 + subagents
        )
    }

    private static func parseCodexSession(
        _ file: URL,
        rangeStart: Date,
        rangeEnd: Date
    ) -> AgentSession? {
        var start: Date?
        var end: Date?
        var workingDirectory: URL?
        var workItems = 0
        var totalTokens = 0
        var spawnedAgents = 0

        JSONLReader.read(file) { object in
            if let timestamp = object["timestamp"] as? String,
               let date = ISO8601Parser.date(from: timestamp) {
                start = min(start ?? date, date)
                end = max(end ?? date, date)
            }

            guard let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return }
            if type == "session_meta", let cwd = payload["cwd"] as? String {
                workingDirectory = URL(fileURLWithPath: cwd, isDirectory: true)
            }
            if type == "event_msg", payload["type"] as? String == "user_message" {
                workItems += 1
            }
            if type == "response_item", payload["name"] as? String == "spawn_agent" {
                spawnedAgents += 1
            }
            if type == "event_msg",
               payload["type"] as? String == "token_count",
               let info = payload["info"] as? [String: Any],
               let usage = info["total_token_usage"] as? [String: Any],
               let tokens = integer(usage["total_tokens"]) {
                totalTokens = max(totalTokens, tokens)
            }
        }

        guard let start, let end, end >= rangeStart, start <= rangeEnd else { return nil }
        return AgentSession(
            id: file.deletingPathExtension().lastPathComponent,
            start: start,
            end: end,
            workingDirectory: workingDirectory,
            workItems: workItems,
            tokens: totalTokens,
            agentCount: 1 + spawnedAgents
        )
    }

    private static func parseClaudeSession(
        _ file: URL,
        rangeStart: Date,
        rangeEnd: Date
    ) -> AgentSession? {
        var start: Date?
        var end: Date?
        var workingDirectory: URL?
        var workItems = 0
        var totalTokens = 0
        var seenUsageMessages = Set<String>()

        JSONLReader.read(file) { object in
            if let timestamp = object["timestamp"] as? String,
               let date = ISO8601Parser.date(from: timestamp) {
                start = min(start ?? date, date)
                end = max(end ?? date, date)
            }
            if workingDirectory == nil, let cwd = object["cwd"] as? String {
                workingDirectory = URL(fileURLWithPath: cwd, isDirectory: true)
            }
            if object["type"] as? String == "user", object["isMeta"] as? Bool != true {
                workItems += 1
            }

            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let identifier = (message["id"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
            guard seenUsageMessages.insert(identifier).inserted else { return }
            totalTokens += [
                "input_tokens",
                "output_tokens",
                "cache_creation_input_tokens",
                "cache_read_input_tokens",
            ].compactMap { integer(usage[$0]) }.reduce(0, +)
        }

        guard let start, let end, end >= rangeStart, start <= rangeEnd else { return nil }
        let subagentDirectory = file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            .appendingPathComponent("subagents")
        let subagents = (try? FileManager.default.contentsOfDirectory(at: subagentDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" }.count ?? 0

        return AgentSession(
            id: file.deletingPathExtension().lastPathComponent,
            start: start,
            end: end,
            workingDirectory: workingDirectory,
            workItems: workItems,
            tokens: totalTokens,
            agentCount: 1 + subagents
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

struct AgentSession {
    let id: String?
    let start: Date
    let end: Date
    let workingDirectory: URL?
    let workItems: Int
    let tokens: Int
    let agentCount: Int

    var activeMinutes: Int {
        max(1, min(480, Int(end.timeIntervalSince(start) / 60)))
    }
}

struct GitCommit {
    let hash: String
    let date: Date
    let additions: Int
    let deletions: Int
}

enum GitCommitCorrelator {
    static func commits(matching sessions: [AgentSession]) -> [GitCommit] {
        let allowedRoots = LocalGitAccess.allowedRoots
        guard !allowedRoots.isEmpty else { return [] }

        var rootByWorkingDirectory: [String: URL] = [:]
        var unresolvedWorkingDirectories = Set<String>()
        var resolvedSessions: [(URL, AgentSession)] = []

        for session in sessions {
            guard let directory = session.workingDirectory,
                  allowedRoots.contains(where: { directory.isDescendant(of: $0) }) else { continue }
            let directoryPath = directory.path
            if let cached = rootByWorkingDirectory[directoryPath] {
                resolvedSessions.append((cached, session))
                continue
            }
            if unresolvedWorkingDirectories.contains(directoryPath) { continue }
            guard let repository = gitRoot(for: directory) else {
                unresolvedWorkingDirectories.insert(directoryPath)
                continue
            }
            rootByWorkingDirectory[directoryPath] = repository
            resolvedSessions.append((repository, session))
        }

        let sessionsByRepository = Dictionary(grouping: resolvedSessions, by: { $0.0.path })

        var matchedByHash: [String: GitCommit] = [:]
        for (repositoryPath, entries) in sessionsByRepository {
            let repository = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            let repositorySessions = entries.map(\.1)
            guard let first = repositorySessions.map(\.start).min(),
                  let last = repositorySessions.map(\.end).max() else { continue }
            let commits = gitLog(
                repository: repository,
                since: first.addingTimeInterval(-1_800),
                until: last.addingTimeInterval(1_800)
            )
            for commit in commits where repositorySessions.contains(where: {
                commit.date >= $0.start.addingTimeInterval(-1_800)
                    && commit.date <= $0.end.addingTimeInterval(1_800)
            }) {
                matchedByHash[commit.hash] = commit
            }
        }
        return Array(matchedByHash.values)
    }

    private static func gitRoot(for directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }

        while candidate.path != "/" {
            let marker = candidate.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: marker.path) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func gitLog(repository: URL, since: Date, until: Date) -> [GitCommit] {
        let gitDirectory = repository.appendingPathComponent(".git").path
        var arguments = [
            "--git-dir=\(gitDirectory)",
            "log", "--all",
            "--since=@\(Int(since.timeIntervalSince1970))",
            "--until=@\(Int(until.timeIntervalSince1970))",
            "--format=@@%H|%cI",
            "--numstat",
        ]
        if let email = authorEmail, !email.isEmpty {
            arguments.insert("--author=\(email)", at: 5)
        }

        guard let output = run(executable: "/usr/bin/git", arguments: arguments) else { return [] }
        var commits: [GitCommit] = []
        var currentHash: String?
        var currentDate: Date?
        var additions = 0
        var deletions = 0

        func finishCurrent() {
            if let hash = currentHash, let date = currentDate {
                commits.append(GitCommit(hash: hash, date: date, additions: additions, deletions: deletions))
            }
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                finishCurrent()
                let metadata = line.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
                currentHash = metadata.first
                currentDate = metadata.count > 1 ? ISO8601Parser.date(from: metadata[1]) : nil
                additions = 0
                deletions = 0
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            if columns.count >= 2 {
                additions += Int(columns[0]) ?? 0
                deletions += Int(columns[1]) ?? 0
            }
        }
        finishCurrent()
        return commits
    }

    private static let authorEmail: String? = run(
        executable: "/usr/bin/git",
        arguments: ["config", "--global", "user.email"]
    )?.trimmingCharacters(in: .whitespacesAndNewlines)

    private static func run(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        // LaunchServices may give a bundled app a transient/deleted working directory
        // after an in-place rebuild. Child tools must start from a stable directory.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

enum LocalGitAccess {
    private static let defaultsKey = "authorizedRepositoryRoots"

    static var allowedRoots: [URL] {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    static func save(_ roots: [URL]) {
        let paths = roots.map { $0.standardizedFileURL.path }
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }
}

private extension URL {
    func isDescendant(of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

private enum JSONLReader {
    static func read(_ file: URL, body: @escaping ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return }
        let contents = String(decoding: data, as: UTF8.self)
        contents.enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
            body(object)
        }
    }
}

enum ISO8601Parser {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
