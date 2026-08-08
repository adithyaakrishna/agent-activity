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
  private var activeRefreshID: UUID?
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
    cancelRefresh()
    selectedSource = source
    refreshError = nil
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
    cancelRefresh()
    guard selectedSource != .others else {
      refreshError = Self.othersUnavailableMessage
      loadState = .unavailable(Self.othersUnavailableMessage)
      return
    }

    let requestedSource = selectedSource
    let refreshID = UUID()
    activeRefreshID = refreshID
    loadState = .loading
    refreshTask = Task { [weak self] in
      do {
        guard let self else { return }
        let result = try await sourceLoader(requestedSource)
        try Task.checkCancellation()
        guard isCurrentRefresh(refreshID, source: requestedSource) else { return }
        cachedResults[requestedSource] = result
        dataset = result.dataset
        summary = result.summary
        loadState = .available
        refreshError = nil
        replayID = UUID()
        finishRefresh(refreshID)
      } catch is CancellationError {
        guard let self, self.isCurrentRefresh(refreshID, source: requestedSource) else { return }
        finishRefresh(refreshID)
        return
      } catch {
        guard let self, self.isCurrentRefresh(refreshID, source: requestedSource) else { return }
        refreshError = error.localizedDescription
        loadState = .unavailable(error.localizedDescription)
        finishRefresh(refreshID)
      }
    }
  }

  private func cancelRefresh() {
    refreshTask?.cancel()
    refreshTask = nil
    activeRefreshID = nil
  }

  private func isCurrentRefresh(_ refreshID: UUID, source: AgentSource) -> Bool {
    activeRefreshID == refreshID && selectedSource == source
  }

  private func finishRefresh(_ refreshID: UUID) {
    guard activeRefreshID == refreshID else { return }
    refreshTask = nil
    activeRefreshID = nil
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
