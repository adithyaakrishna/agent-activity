import Foundation
import XCTest

final class HookCommandLineTests: XCTestCase {
    func testInstallAndUninstallFailuresReturnNonzeroWhileCaptureRemainsFailOpen() throws {
        let home = try malformedFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let install = try run(executable: try hookExecutable(), arguments: ["install"], home: home)
        let uninstall = try run(executable: try hookExecutable(), arguments: ["uninstall"], home: home)
        let capture = try run(
            executable: try hookExecutable(),
            arguments: ["capture", "cursor"],
            home: home,
            input: Data("not-json".utf8)
        )

        XCTAssertNotEqual(install.status, 0)
        XCTAssertNotEqual(uninstall.status, 0)
        XCTAssertEqual(capture.status, 0)
        XCTAssertTrue(install.output.isEmpty)
        XCTAssertTrue(uninstall.output.isEmpty)
        XCTAssertTrue(capture.output.isEmpty)
    }

    func testDevelopmentWrapperIsFailOpenForCaptureAndUnsupportedProviders() throws {
        let home = try malformedFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let wrapper = repositoryRoot().appendingPathComponent("script/agent_activity_hook.sh")

        let capture = try run(
            executable: wrapper,
            arguments: ["cursor"],
            home: home,
            input: Data("not-json".utf8)
        )
        let unsupported = try run(executable: wrapper, arguments: ["other"], home: home)

        XCTAssertEqual(capture.status, 0)
        XCTAssertEqual(unsupported.status, 0)
        XCTAssertTrue(capture.output.isEmpty)
        XCTAssertTrue(unsupported.output.isEmpty)
    }

    private func malformedFixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cursorURL = home.appendingPathComponent(".cursor/hooks.json")
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: cursorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cursorURL)
        try Data("not-json".utf8).write(to: claudeURL)
        return home
    }

    private func hookExecutable() throws -> URL {
        let standardBuildPath = repositoryRoot().appendingPathComponent(".build/debug/AgentActivityHook")
        if FileManager.default.isExecutableFile(atPath: standardBuildPath.path) { return standardBuildPath }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("AgentActivityHook")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "HookCommandLineTests", code: 1)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func run(
        executable: URL,
        arguments: [String],
        home: URL,
        input: Data = Data()
    ) throws -> (status: Int32, output: Data) {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["AGENT_ACTIVITY_HOME_DIRECTORY_OVERRIDE"] = home.path
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = Pipe()
        try process.run()
        standardInput.fileHandleForWriting.write(input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, standardOutput.fileHandleForReading.readDataToEndOfFile())
    }
}
