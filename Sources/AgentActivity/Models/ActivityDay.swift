import Foundation

struct ActivityDay: Identifiable, Hashable, Sendable {
  let date: Date
  let key: String
  let label: String
  let isInRange: Bool
  var intensity: Int
  var thingsWorkedOn: Int
  var commits: Int
  var tokens: Int
  var agents: Int
  var additions: Int
  var deletions: Int
  var activeMinutes: Int

  var id: Date { date }

  var activeTimeLabel: String {
    let hours = activeMinutes / 60
    let minutes = activeMinutes % 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
  }

  var accessibilitySummary: String {
    guard intensity > 0 else { return "\(label), no agent activity" }
    return
      "\(label), \(thingsWorkedOn) things worked on, \(commits) commits, \(tokens) tokens, \(agents) agents"
  }
}

struct ActivityMonthLabel: Identifiable, Hashable, Sendable {
  let title: String
  let weekIndex: Int

  var id: String { "\(title)-\(weekIndex)" }
}

struct ActivityDataset: Equatable, Sendable {
  let weeks: [[ActivityDay]]
  let months: [ActivityMonthLabel]
}

struct ActivityDayMetrics: Equatable, Sendable {
  var thingsWorkedOn = 0
  var commits = 0
  var tokens = 0
  var agents = 0
  var additions = 0
  var deletions = 0
  var activeMinutes = 0

  var activityValue: Int {
    max(thingsWorkedOn, commits)
  }

  mutating func merge(_ other: ActivityDayMetrics) {
    thingsWorkedOn += other.thingsWorkedOn
    commits += other.commits
    tokens += other.tokens
    agents += other.agents
    additions += other.additions
    deletions += other.deletions
    activeMinutes += other.activeMinutes
  }
}

struct ActivityHistoryResult: Sendable {
  let dataset: ActivityDataset
  let summary: ActivitySummary
}
