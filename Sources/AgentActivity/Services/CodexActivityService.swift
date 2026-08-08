import Foundation

enum CodexActivityError: LocalizedError {
    case cliUnavailable
    case serverExited
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            "Codex CLI is not installed"
        case .serverExited:
            "Codex App Server exited before returning activity"
        case let .malformedResponse(method):
            "Codex App Server returned an unreadable \(method) response"
        }
    }
}

enum CodexActivityService {
    static func load(endingOn endDate: Date = Date()) async throws -> ActivityHistoryResult {
        try await Task.detached(priority: .utility) {
            try loadSynchronously(endingOn: endDate)
        }.value
    }

    private static func loadSynchronously(endingOn endDate: Date) throws -> ActivityHistoryResult {
        guard let executable = codexCLIURL() else { throw CodexActivityError.cliUnavailable }

        let client = try AppServerClient(executable: executable)
        defer { client.stop() }
        try client.initialize()

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rangeEnd = calendar.startOfDay(for: endDate).addingTimeInterval(86_399)
        let rangeStart = calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: endDate))!

        let threads = try client.threads(createdAfter: rangeStart)
        let usage = try client.dailyUsage()
        let childCounts = Dictionary(grouping: threads.compactMap { thread -> (String, CodexThread)? in
            guard let parent = thread.parentThreadID else { return nil }
            return (parent, thread)
        }, by: \.0).mapValues(\.count)

        let roots = threads.filter { $0.parentThreadID == nil }
        var metricsByDate: [String: ActivityDayMetrics] = [:]
        var sessions: [AgentSession] = []

        for thread in roots where thread.createdAt <= rangeEnd && thread.updatedAt >= rangeStart {
            let key = ActivityFormatters.dateKey.string(from: thread.createdAt)
            var metrics = metricsByDate[key, default: ActivityDayMetrics()]
            metrics.thingsWorkedOn += 1
            metrics.agents = max(metrics.agents, 1 + (childCounts[thread.id] ?? 0))
            metrics.activeMinutes += max(
                1,
                min(480, Int(thread.updatedAt.timeIntervalSince(thread.createdAt) / 60))
            )
            metricsByDate[key] = metrics

            sessions.append(
                AgentSession(
                    id: thread.id,
                    start: thread.createdAt,
                    end: max(thread.createdAt, thread.updatedAt),
                    workingDirectory: thread.cwd,
                    workItems: 1,
                    tokens: 0,
                    agentCount: 1 + (childCounts[thread.id] ?? 0)
                )
            )
        }

        for bucket in usage {
            var metrics = metricsByDate[bucket.date, default: ActivityDayMetrics()]
            metrics.thingsWorkedOn = max(1, metrics.thingsWorkedOn)
            metrics.tokens = bucket.tokens
            metricsByDate[bucket.date] = metrics
        }

        for commit in GitCommitCorrelator.commits(matching: sessions) {
            let key = ActivityFormatters.dateKey.string(from: commit.date)
            var metrics = metricsByDate[key, default: ActivityDayMetrics()]
            metrics.commits += 1
            metrics.additions += commit.additions
            metrics.deletions += commit.deletions
            metricsByDate[key] = metrics
        }

        return ActivityDataFactory.make(from: metricsByDate, endingOn: endDate)
    }

    private static func codexCLIURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }
}

private struct CodexThread {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let cwd: URL
    let parentThreadID: String?
}

private struct CodexUsageBucket {
    let date: String
    let tokens: Int
}

private final class AppServerClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var readBuffer = Data()
    private var nextRequestID = 1

    init(executable: URL) throws {
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func initialize() throws {
        let response = try request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "agent-activity",
                    "version": "0.1",
                ],
            ]
        )
        guard response["result"] != nil else {
            throw CodexActivityError.malformedResponse("initialize")
        }
        try notify(method: "initialized")
    }

    func threads(createdAfter rangeStart: Date) throws -> [CodexThread] {
        let sourceKinds = [
            "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
            "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
        ]
        var threads: [CodexThread] = []

        for archived in [false, true] {
            var cursor: String?
            repeat {
                var params: [String: Any] = [
                    "archived": archived,
                    "limit": 200,
                    "sortKey": "created_at",
                    "sortDirection": "desc",
                    "sourceKinds": sourceKinds,
                    "useStateDbOnly": true,
                ]
                if let cursor { params["cursor"] = cursor }

                let response = try request(method: "thread/list", params: params)
                guard let result = response["result"] as? [String: Any],
                      let data = result["data"] as? [[String: Any]] else {
                    throw CodexActivityError.malformedResponse("thread/list")
                }

                let page = data.compactMap(Self.decodeThread)
                threads.append(contentsOf: page.filter { $0.updatedAt >= rangeStart })
                let oldestCreation = page.map(\.createdAt).min()
                cursor = result["nextCursor"] as? String
                if let oldestCreation, oldestCreation < rangeStart { cursor = nil }
            } while cursor != nil
        }
        return threads
    }

    func dailyUsage() throws -> [CodexUsageBucket] {
        let response = try request(method: "account/usage/read", params: NSNull())
        guard let result = response["result"] as? [String: Any],
              let buckets = result["dailyUsageBuckets"] as? [[String: Any]] else {
            return []
        }
        return buckets.compactMap { bucket in
            guard let date = bucket["startDate"] as? String,
                  let tokens = (bucket["tokens"] as? NSNumber)?.intValue else { return nil }
            return CodexUsageBucket(date: date, tokens: tokens)
        }
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func request(method: String, params: Any) throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        try send(["id": id, "method": method, "params": params])

        while let message = try readMessage() {
            if (message["id"] as? NSNumber)?.intValue == id { return message }
        }
        throw CodexActivityError.serverExited
    }

    private func notify(method: String) throws {
        try send(["method": method])
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage() throws -> [String: Any]? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    return object
                }
                continue
            }

            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { return nil }
            readBuffer.append(chunk)
        }
    }

    private static func decodeThread(_ object: [String: Any]) -> CodexThread? {
        guard let id = object["id"] as? String,
              let created = (object["createdAt"] as? NSNumber)?.doubleValue,
              let updated = (object["updatedAt"] as? NSNumber)?.doubleValue,
              let cwd = object["cwd"] as? String else { return nil }
        return CodexThread(
            id: id,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated),
            cwd: URL(fileURLWithPath: cwd, isDirectory: true),
            parentThreadID: object["parentThreadId"] as? String
        )
    }
}
