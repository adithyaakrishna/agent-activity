import XCTest

@testable import AgentActivity

final class ActivitySourceIntegrationTests: XCTestCase {
  func testLiveConfiguredSourceProducesActivity() async throws {
    guard let rawSource = ProcessInfo.processInfo.environment["AGENT_ACTIVITY_INTEGRATION_SOURCE"],
      let source = AgentSource(rawValue: rawSource)
    else {
      throw XCTSkip("Set AGENT_ACTIVITY_INTEGRATION_SOURCE to run a live source check")
    }

    let result: ActivityHistoryResult
    if source == .github {
      result = try await GitHubActivityService.load()
    } else if source == .codex {
      result = try await CodexActivityService.load()
    } else {
      result = try await LocalAgentActivityService.load(source: source)
    }

    XCTAssertEqual(result.dataset.weeks.count, 53)
    XCTAssertGreaterThan(result.summary.activeDays, 0)
    XCTAssertGreaterThan(result.summary.totalCommits, 0)
  }
}
