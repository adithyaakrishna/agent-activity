import AppKit
import SwiftUI
import XCTest

@testable import AgentActivity

final class ActivityDataFactoryTests: XCTestCase {
  func testSourceOrderKeepsPrimaryAgentsFirst() {
    XCTAssertEqual(AgentSource.allCases, [.cursor, .codex, .claude, .github, .others])
  }

  func testDatasetContainsExactlyFiftyThreeCompleteWeeks() {
    let dataset = ActivityDataFactory.make(for: .codex)

    XCTAssertEqual(dataset.weeks.count, 53)
    XCTAssertTrue(dataset.weeks.allSatisfy { $0.count == 7 })
  }

  func testGeneratedCommitsMatchEachSourceSummary() {
    for source in AgentSource.allCases {
      let dataset = ActivityDataFactory.make(for: source)
      let commitTotal = dataset.weeks
        .flatMap { $0 }
        .reduce(0) { $0 + $1.commits }

      XCTAssertEqual(commitTotal, source.summary.totalCommits, source.displayName)
    }
  }

  func testCodexShowcaseDayContainsRichHoverMetrics() throws {
    let dataset = ActivityDataFactory.make(for: .codex)
    let day = try XCTUnwrap(
      dataset.weeks.flatMap { $0 }.first(where: { $0.key == "2026-08-06" })
    )

    XCTAssertEqual(day.intensity, 4)
    XCTAssertEqual(day.thingsWorkedOn, 8)
    XCTAssertEqual(day.commits, 5)
    XCTAssertEqual(day.tokens, 128_000)
    XCTAssertEqual(day.agents, 3)
    XCTAssertEqual(day.additions, 842)
    XCTAssertEqual(day.deletions, 219)
    XCTAssertEqual(day.activeTimeLabel, "2h 14m")
  }

  @MainActor
  func testOthersStartsUnavailableWithoutSyntheticActivity() {
    let store = ActivityStore(
      selectedSource: .others,
      sourceLoader: { _ in
        XCTFail("Others must not invoke a live provider loader")
        throw FixtureLoadError.unavailable
      }
    )

    guard case .unavailable(let reason) = store.loadState else {
      return XCTFail("Others must have an unavailable state")
    }
    XCTAssertEqual(reason, "No live provider is configured for Others")
    assertEmpty(store)
  }

  @MainActor
  func testFailedProviderRefreshKeepsHonestEmptyValues() async {
    let attempted = expectation(description: "provider load attempted")
    let store = ActivityStore(
      selectedSource: .codex,
      sourceLoader: { _ in
        attempted.fulfill()
        throw FixtureLoadError.unavailable
      }
    )

    await fulfillment(of: [attempted], timeout: 1)
    for _ in 0..<100 where store.loadState == .loading {
      await Task.yield()
    }

    guard case .unavailable = store.loadState else {
      return XCTFail("A failed refresh must become unavailable")
    }
    XCTAssertNotNil(store.refreshError)
    assertEmpty(store)
  }

  @MainActor
  func testNativePopoverRendersAtItsExactSize() throws {
    let content = ActivityPopoverView(
      store: ActivityStore(loadsLiveData: false),
      animateWeeks: false
    )
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2

    guard let cgImage = renderer.cgImage else {
      XCTFail("SwiftUI did not render a CGImage")
      return
    }
    XCTAssertEqual(cgImage.width, 1_120)
    XCTAssertEqual(cgImage.height, 596)

    guard let outputPath = ProcessInfo.processInfo.environment["AGENT_ACTIVITY_SNAPSHOT_PATH"]
    else {
      return
    }

    let representation = NSBitmapImageRep(cgImage: cgImage)
    guard
      let png = representation.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
      )
    else {
      XCTFail("Could not encode native snapshot")
      return
    }
    try png.write(
      to: URL(fileURLWithPath: outputPath),
      options: Data.WritingOptions.atomic
    )
  }

  @MainActor
  private func assertEmpty(_ store: ActivityStore) {
    XCTAssertEqual(
      store.summary,
      ActivitySummary(totalCommits: 0, activeDays: 0, longestStreak: 0, currentStreak: 0)
    )
    let days = store.dataset.weeks.flatMap { $0 }
    XCTAssertTrue(
      days.allSatisfy { day in
        day.intensity == 0 && day.commits == 0 && day.thingsWorkedOn == 0
      })
  }
}

private enum FixtureLoadError: LocalizedError {
  case unavailable

  var errorDescription: String? { "Fixture provider unavailable" }
}
