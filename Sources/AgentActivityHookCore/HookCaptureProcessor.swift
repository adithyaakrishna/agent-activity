import Foundation

public struct HookCaptureProcessor {
  private let git: any GitHeadInspecting

  public init(git: any GitHeadInspecting = GitHeadInspector()) {
    self.git = git
  }

  public func makeRecord(
    input: Data,
    provider: HookProvider,
    capturedAt: Date,
    environment: [String: String]
  ) throws -> [String: Any]? {
    _ = environment
    guard let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
      return nil
    }

    let sessionID: String?
    let candidatePath: String?
    switch provider {
    case .cursor:
      sessionID = payload["conversation_id"] as? String
      candidatePath = (payload["workspace_roots"] as? [Any])?.first as? String
    case .claude:
      guard (payload["transcript_path"] as? String)?.contains("/.claude/projects/") == true else {
        return nil
      }
      sessionID = payload["session_id"] as? String
      candidatePath = payload["cwd"] as? String
    }

    guard let sessionID, !sessionID.isEmpty else { return nil }
    let event = payload["hook_event_name"] as? String
    let candidateDirectory = candidatePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let repositoryRoot = candidateDirectory.flatMap { git.repositoryRoot(for: $0) }

    var record: [String: Any] = [
      "schema_version": 1,
      "provider": provider.rawValue,
      "captured_at": ISO8601DateFormatter().string(from: capturedAt),
      "session_id": sessionID,
    ]
    if let event, !event.isEmpty {
      record["event"] = event
    }
    if let repositoryRoot {
      record["repository_root"] = repositoryRoot.path
    } else if let candidatePath, !candidatePath.isEmpty {
      record["repository_root"] = candidatePath
    }
    if let agentID = payload["agent_id"] as? String, !agentID.isEmpty {
      record["agent_id"] = agentID
    }

    if let event,
      ["stop", "sessionEnd", "SessionEnd", "afterFileEdit"].contains(event),
      let repositoryRoot,
      let head = git.headMetadata(at: repositoryRoot),
      isValidSHA(head.sha)
    {
      record["head_sha"] = head.sha
      record["head_committed_at"] = ISO8601DateFormatter().string(from: head.committedAt)
      record["head_additions"] = head.additions
      record["head_deletions"] = head.deletions
    }

    return record
  }

  private func isValidSHA(_ value: String) -> Bool {
    value.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
  }
}
