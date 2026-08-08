import AppKit
import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var selectedSource: AgentSource
    @Published private(set) var dataset: ActivityDataset
    @Published private(set) var summary: ActivitySummary
    @Published private(set) var refreshError: String?
    @Published private(set) var replayID = UUID()
    private var refreshTask: Task<Void, Never>?
    private var cachedResults: [AgentSource: ActivityHistoryResult] = [:]

    init(selectedSource: AgentSource = .codex, loadsLiveData: Bool = true) {
        self.selectedSource = selectedSource
        dataset = ActivityDataFactory.make(for: selectedSource)
        summary = selectedSource.summary
        if loadsLiveData { refresh() }
    }

    func select(_ source: AgentSource) {
        guard source != selectedSource else { return }
        selectedSource = source
        refreshError = nil
        replayID = UUID()
        if let cached = cachedResults[source] {
            dataset = cached.dataset
            summary = cached.summary
            return
        }
        dataset = ActivityDataFactory.make(for: source)
        summary = source.summary
        refresh()
    }

    func replay() {
        replayID = UUID()
        refresh()
    }

    func chooseRepositoryFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose repository folders"
        panel.message = "AgentActivity will only correlate commits inside the folders you select."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        LocalGitAccess.save(panel.urls)
        cachedResults.removeAll()
        dataset = ActivityDataFactory.make(for: selectedSource)
        summary = selectedSource.summary
        replayID = UUID()
        refresh()
    }

    private func refresh() {
        refreshTask?.cancel()
        guard selectedSource != .others else { return }

        let requestedSource = selectedSource
        refreshTask = Task { [weak self] in
            do {
                let result: ActivityHistoryResult
                if requestedSource == .github {
                    result = try await GitHubActivityService.load()
                } else if requestedSource == .codex {
                    result = try await CodexActivityService.load()
                } else {
                    result = try await LocalAgentActivityService.load(source: requestedSource)
                }
                try Task.checkCancellation()
                guard let self, self.selectedSource == requestedSource else { return }
                cachedResults[requestedSource] = result
                dataset = result.dataset
                summary = result.summary
                refreshError = nil
                replayID = UUID()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.selectedSource == requestedSource else { return }
                refreshError = error.localizedDescription
            }
        }
    }
}
