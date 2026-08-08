import Darwin
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
    private let commandTimeout: TimeInterval
    private let executableURL: URL

    public init() {
        self.init(
            commandTimeout: 2,
            executableURL: URL(fileURLWithPath: "/usr/bin/git")
        )
    }

    init(commandTimeout: TimeInterval, executableURL: URL) {
        self.commandTimeout = max(0, commandTimeout)
        self.executableURL = executableURL
    }

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
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let outputRead = DispatchGroup()
        let outputLock = NSLock()
        var outputData = Data()
        outputRead.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            outputData = data
            outputLock.unlock()
            outputRead.leave()
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.closeFile()
            return nil
        }

        let deadline = Date().addingTimeInterval(commandTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard !process.isRunning else {
            stop(process)
            output.fileHandleForReading.closeFile()
            _ = outputRead.wait(timeout: .now() + 0.1)
            return nil
        }

        process.waitUntilExit()
        guard outputRead.wait(timeout: .now() + commandTimeout) == .success else {
            output.fileHandleForReading.closeFile()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        outputLock.lock()
        defer { outputLock.unlock() }
        return String(decoding: outputData, as: UTF8.self)
    }

    private func stop(_ process: Process) {
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.1)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
