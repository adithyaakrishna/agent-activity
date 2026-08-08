import AgentActivityHookCore
import Darwin
import Foundation

@main
enum AgentActivityHookMain {
  static func main() {
    let arguments = CommandLine.arguments
    let commandArguments = Array(arguments.dropFirst())
    if commandArguments.count == 2, commandArguments[0] == "capture" {
      capture(provider: commandArguments[1])
    } else if commandArguments == ["install"] {
      if !configure(installing: true) { Darwin.exit(EXIT_FAILURE) }
    } else if commandArguments == ["uninstall"] {
      if !configure(installing: false) { Darwin.exit(EXIT_FAILURE) }
    }
  }

  private static func capture(provider providerName: String) {
    guard let provider = HookProvider(rawValue: providerName) else { return }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    do {
      guard
        let record = try HookCaptureProcessor().makeRecord(
          input: input,
          provider: provider,
          capturedAt: Date(),
          environment: ProcessInfo.processInfo.environment
        )
      else {
        return
      }
      let directory = homeDirectory()
        .appendingPathComponent(
          "Library/Application Support/AgentActivity/hooks", isDirectory: true)
      try HookRecordStore().append(record, provider: provider, directory: directory)
    } catch {
      // Capture is intentionally fail-open so provider workflows are never blocked.
    }
  }

  private static func configure(installing: Bool) -> Bool {
    do {
      let manager = HookConfigurationManager()
      let home = homeDirectory()
      if installing {
        try manager.install(
          helperSource: try executableURL(), homeDirectory: home, timestamp: Date())
        print("Installed AgentActivity hooks.")
      } else {
        try manager.uninstall(homeDirectory: home, timestamp: Date())
        print("Removed AgentActivity hooks.")
      }
      return true
    } catch {
      FileHandle.standardError.write(Data("AgentActivity hook configuration failed.\n".utf8))
      return false
    }
  }

  private static func homeDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["AGENT_ACTIVITY_HOME_DIRECTORY_OVERRIDE"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  private static func executableURL() throws -> URL {
    let executable = CommandLine.arguments[0]
    if executable.hasPrefix("/") {
      return URL(fileURLWithPath: executable).standardizedFileURL
    }
    if executable.contains("/") {
      return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        executable
      ).standardizedFileURL
    }
    let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
    if let path = paths.first(where: {
      FileManager.default.isExecutableFile(atPath: String($0) + "/" + executable)
    }) {
      return URL(fileURLWithPath: String(path)).appendingPathComponent(executable)
        .standardizedFileURL
    }
    throw NSError(domain: "AgentActivityHook", code: 1)
  }
}
