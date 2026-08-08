import Foundation
import AgentActivityHookCore

@main
enum AgentActivityHookMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              arguments[1] == "capture",
              let provider = HookProvider(rawValue: arguments[2])
        else {
            return
        }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        do {
            guard let record = try HookCaptureProcessor().makeRecord(
                input: input,
                provider: provider,
                capturedAt: Date(),
                environment: ProcessInfo.processInfo.environment
            ) else {
                return
            }
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AgentActivity/hooks", isDirectory: true)
            try HookRecordStore().append(record, provider: provider, directory: directory)
        } catch {
            // Capture is intentionally fail-open so provider workflows are never blocked.
        }
    }
}
