import Foundation

public struct GitHeadMetadata: Equatable {
    public let sha: String
    public let committedAt: Date
    public let additions: Int
    public let deletions: Int

    public init(sha: String, committedAt: Date, additions: Int, deletions: Int) {
        self.sha = sha
        self.committedAt = committedAt
        self.additions = additions
        self.deletions = deletions
    }
}

public protocol GitHeadInspecting {
    func repositoryRoot(for candidateDirectory: URL) -> URL?
    func headMetadata(at repositoryRoot: URL) -> GitHeadMetadata?
}

public struct GitHeadInspector: GitHeadInspecting {
    public init() {}

    public func repositoryRoot(for candidateDirectory: URL) -> URL? {
        guard let output = gitOutput(arguments: ["-C", candidateDirectory.path, "rev-parse", "--show-toplevel"]) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    public func headMetadata(at repositoryRoot: URL) -> GitHeadMetadata? {
        guard let log = gitOutput(arguments: ["-C", repositoryRoot.path, "log", "-1", "--format=%H%n%cI"]),
              let statistics = gitOutput(arguments: ["-C", repositoryRoot.path, "show", "--numstat", "--format=", "HEAD"])
        else {
            return nil
        }

        let lines = log.split(whereSeparator: \.isNewline)
        guard lines.count >= 2,
              let committedAt = ISO8601DateFormatter().date(from: String(lines[1]))
        else {
            return nil
        }

        let totals = statistics.split(whereSeparator: \.isNewline).reduce(into: (additions: 0, deletions: 0)) { totals, line in
            let columns = line.split(separator: "\t", maxSplits: 2)
            guard columns.count >= 2 else { return }
            totals.additions += Int(columns[0]) ?? 0
            totals.deletions += Int(columns[1]) ?? 0
        }
        return GitHeadMetadata(
            sha: String(lines[0]),
            committedAt: committedAt,
            additions: totals.additions,
            deletions: totals.deletions
        )
    }

    private func gitOutput(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
