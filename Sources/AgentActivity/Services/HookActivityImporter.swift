import Foundation

struct HookImportResult {
    let sessions: [AgentSession]
    let commits: [GitCommit]

    static let empty = HookImportResult(sessions: [], commits: [])
}

enum HookActivityImporter {
    static func load(
        source: AgentSource,
        rangeStart: Date,
        rangeEnd: Date,
        inboxDirectory: URL? = nil
    ) -> HookImportResult {
        guard source == .cursor || source == .claude else { return .empty }

        let provider = source.rawValue
        let directory = inboxDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentActivity/hooks", isDirectory: true)
        let files = [
            directory.appendingPathComponent("\(provider).jsonl.1"),
            directory.appendingPathComponent("\(provider).jsonl"),
        ]

        var states: [String: HookSessionState] = [:]
        var commitCandidates: [HookCommitCandidate] = []

        for file in files where FileManager.default.fileExists(atPath: file.path) {
            readJSONLines(file) { record in
                guard record["provider"] as? String == provider,
                      let sessionID = record["session_id"] as? String,
                      let captured = record["captured_at"] as? String,
                      let timestamp = ISO8601Parser.date(from: captured),
                      timestamp >= rangeStart,
                      timestamp <= rangeEnd else { return }

                var state = states[sessionID, default: HookSessionState(id: sessionID, timestamp: timestamp)]
                state.start = min(state.start, timestamp)
                state.end = max(state.end, timestamp)

                if let root = record["repository_root"] as? String, !root.isEmpty {
                    state.workingDirectory = URL(fileURLWithPath: root, isDirectory: true)
                }
                if let event = record["event"] as? String {
                    if event == "beforeSubmitPrompt" || event == "UserPromptSubmit" {
                        state.workItems += 1
                    }
                    if event == "subagentStart" || event == "SubagentStart",
                       let agentID = record["agent_id"] as? String {
                        state.agentIDs.insert(agentID)
                    }
                }
                states[sessionID] = state

                guard let hash = record["head_sha"] as? String,
                      hash.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil,
                      let committedAt = record["head_committed_at"] as? String,
                      let commitDate = ISO8601Parser.date(from: committedAt) else { return }
                commitCandidates.append(
                    HookCommitCandidate(
                        sessionID: sessionID,
                        commit: GitCommit(
                            hash: hash,
                            date: commitDate,
                            additions: (record["head_additions"] as? NSNumber)?.intValue ?? 0,
                            deletions: (record["head_deletions"] as? NSNumber)?.intValue ?? 0
                        )
                    )
                )
            }
        }

        let sessions = states.values.map { state in
            AgentSession(
                id: state.id,
                start: state.start,
                end: state.end,
                workingDirectory: state.workingDirectory,
                workItems: max(1, state.workItems),
                tokens: 0,
                agentCount: max(1, 1 + state.agentIDs.count)
            )
        }
        let commits = commitCandidates.compactMap { candidate -> GitCommit? in
            guard let session = states[candidate.sessionID],
                  candidate.commit.date >= session.start.addingTimeInterval(-1_800),
                  candidate.commit.date <= session.end.addingTimeInterval(1_800) else { return nil }
            return candidate.commit
        }

        return HookImportResult(
            sessions: sessions,
            commits: Array(
                Dictionary(
                    commits.map { ($0.hash, $0) },
                    uniquingKeysWith: { existing, _ in existing }
                ).values
            )
        )
    }

    private static func readJSONLines(_ file: URL, body: @escaping ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return }
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }
            body(object)
        }
    }
}

private struct HookSessionState {
    let id: String
    var start: Date
    var end: Date
    var workingDirectory: URL?
    var workItems = 0
    var agentIDs = Set<String>()

    init(id: String, timestamp: Date) {
        self.id = id
        start = timestamp
        end = timestamp
    }
}

private struct HookCommitCandidate {
    let sessionID: String
    let commit: GitCommit
}
