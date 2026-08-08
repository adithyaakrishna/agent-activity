import AppKit
import Foundation

enum ActivityLoadState: Equatable {
  case loading
  case available
  case unavailable(String)
}

@MainActor
final class ActivityStore: ObservableObject {
  typealias SourceLoader = (AgentSource) async throws -> ActivityHistoryResult

  @Published private(set) var selectedSource: AgentSource
  @Published private(set) var dataset: ActivityDataset
  @Published private(set) var summary: ActivitySummary
  @Published private(set) var loadState: ActivityLoadState
  @Published private(set) var refreshError: String?
  @Published private(set) var replayID = UUID()
  private var refreshTask: Task<Void, Never>?
  private var cachedResults: [AgentSource: ActivityHistoryResult] = [:]
  private let sourceLoader: SourceLoader

  init(
    selectedSource: AgentSource = .codex,
    loadsLiveData: Bool = true,
    sourceLoader: @escaping SourceLoader = ActivityStore.loadSource
  ) {
    let emptyResult = ActivityHistoryBuilder.make(from: [:])
    self.selectedSource = selectedSource
    dataset = emptyResult.dataset
    summary = emptyResult.summary
    self.sourceLoader = sourceLoader
    loadState =
      selectedSource == .others
      ? .unavailable(Self.othersUnavailableMessage)
      : .unavailable("Activity has not been loaded")
    if loadsLiveData {
      refresh()
    }
  }

  func select(_ source: AgentSource) {
    guard source != selectedSource else { return }
    selectedSource = source
    refreshError = nil
    replayID = UUID()
    if let cached = cachedResults[source] {
      dataset = cached.dataset
      summary = cached.summary
      loadState = .available
      return
    }
    applyEmptyState()
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
    applyEmptyState()
    replayID = UUID()
    refresh()
  }

  private func refresh() {
    refreshTask?.cancel()
    guard selectedSource != .others else {
      refreshError = Self.othersUnavailableMessage
      loadState = .unavailable(Self.othersUnavailableMessage)
      return
    }

    let requestedSource = selectedSource
    loadState = .loading
    refreshTask = Task { [weak self] in
      do {
        guard let self else { return }
        let result = try await sourceLoader(requestedSource)
        try Task.checkCancellation()
        guard selectedSource == requestedSource else { return }
        cachedResults[requestedSource] = result
        dataset = result.dataset
        summary = result.summary
        loadState = .available
        refreshError = nil
        replayID = UUID()
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.selectedSource == requestedSource else { return }
        refreshError = error.localizedDescription
        loadState = .unavailable(error.localizedDescription)
      }
    }
  }

  private func applyEmptyState() {
    let emptyResult = ActivityHistoryBuilder.make(from: [:])
    dataset = emptyResult.dataset
    summary = emptyResult.summary
    loadState =
      selectedSource == .others
      ? .unavailable(Self.othersUnavailableMessage)
      : .unavailable("Activity has not been loaded")
  }

  private static func loadSource(_ source: AgentSource) async throws -> ActivityHistoryResult {
    if source == .github {
      return try await GitHubActivityService.load()
    }
    if source == .codex {
      return try await CodexActivityService.load()
    }
    return try await LocalAgentActivityService.load(source: source)
  }

  private static let othersUnavailableMessage = "No live provider is configured for Others"
}
