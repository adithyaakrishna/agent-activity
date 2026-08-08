import Foundation

enum ActivityDataFactory {
  private static let weekCount = 53
  private static let dayCount = weekCount * 7

  static func make(for source: AgentSource) -> ActivityDataset {
    let calendar = utcCalendar
    let rangeEnd = calendar.startOfDay(for: Date())
    let rangeStart = calendar.date(byAdding: .day, value: -364, to: rangeEnd)!
    let weekdayOffset = calendar.component(.weekday, from: rangeStart) - 1
    let gridStart = calendar.date(byAdding: .day, value: -weekdayOffset, to: rangeStart)!

    var days = (0..<dayCount).map { index -> ActivityDay in
      let date = calendar.date(byAdding: .day, value: index, to: gridStart)!
      let inRange = date >= rangeStart && date <= rangeEnd
      return makeDay(
        source: source, date: date, index: index, isInRange: inRange, calendar: calendar)
    }

    if source == .codex,
      let showcaseIndex = days.firstIndex(where: { $0.key == "2026-08-06" })
    {
      days[showcaseIndex].intensity = 4
      days[showcaseIndex].thingsWorkedOn = 8
      days[showcaseIndex].commits = 5
      days[showcaseIndex].tokens = 128_000
      days[showcaseIndex].agents = 3
      days[showcaseIndex].additions = 842
      days[showcaseIndex].deletions = 219
      days[showcaseIndex].activeMinutes = 134
    }

    fitCommitTotal(
      days: &days,
      target: source.summary.totalCommits,
      lockedKey: source == .codex ? "2026-08-06" : nil
    )

    let weeks = stride(from: 0, to: dayCount, by: 7).map {
      Array(days[$0..<min($0 + 7, days.count)])
    }

    var previousMonth = -1
    var months: [ActivityMonthLabel] = []
    for (weekIndex, week) in weeks.enumerated() {
      guard weekIndex > 2,
        let candidate = week.first(where: {
          $0.isInRange && calendar.component(.day, from: $0.date) <= 7
        })
      else { continue }
      let month = calendar.component(.month, from: candidate.date)
      guard month != previousMonth else { continue }
      months.append(
        ActivityMonthLabel(
          title: ActivityFormatters.month.string(from: candidate.date),
          weekIndex: weekIndex
        )
      )
      previousMonth = month
    }

    return ActivityDataset(weeks: weeks, months: months)
  }
}

enum ActivityHistoryBuilder {
  private static let weekCount = 53
  private static let dayCount = weekCount * 7

  static func make(
    from metricsByDate: [String: ActivityDayMetrics],
    endingOn endDate: Date = Date()
  ) -> ActivityHistoryResult {
    let calendar = utcCalendar
    let rangeEnd = calendar.startOfDay(for: endDate)
    let rangeStart = calendar.date(byAdding: .day, value: -364, to: rangeEnd)!
    let weekdayOffset = calendar.component(.weekday, from: rangeStart) - 1
    let gridStart = calendar.date(byAdding: .day, value: -weekdayOffset, to: rangeStart)!

    let days = (0..<dayCount).map { index -> ActivityDay in
      let date = calendar.date(byAdding: .day, value: index, to: gridStart)!
      let key = ActivityFormatters.dateKey.string(from: date)
      let label = ActivityFormatters.dateLabel.string(from: date)
      let isInRange = date >= rangeStart && date <= rangeEnd
      guard isInRange, let metrics = metricsByDate[key], metrics.activityValue > 0 else {
        return emptyDay(date: date, key: key, label: label, isInRange: isInRange)
      }

      return ActivityDay(
        date: date,
        key: key,
        label: label,
        isInRange: true,
        intensity: intensity(for: metrics.activityValue),
        thingsWorkedOn: metrics.thingsWorkedOn,
        commits: metrics.commits,
        tokens: metrics.tokens,
        agents: metrics.agents,
        additions: metrics.additions,
        deletions: metrics.deletions,
        activeMinutes: metrics.activeMinutes
      )
    }

    let weeks = stride(from: 0, to: dayCount, by: 7).map {
      Array(days[$0..<min($0 + 7, days.count)])
    }
    let dataset = ActivityDataset(weeks: weeks, months: monthLabels(for: weeks, calendar: calendar))
    let inRangeDays = days.filter(\.isInRange)
    let total = inRangeDays.reduce(0) { $0 + $1.thingsWorkedOn }
    let activeDays = inRangeDays.filter { $0.intensity > 0 }.count
    let streaks = streakLengths(in: inRangeDays)

    return ActivityHistoryResult(
      dataset: dataset,
      summary: ActivitySummary(
        totalCommits: total,
        activeDays: activeDays,
        longestStreak: streaks.max() ?? 0,
        currentStreak: currentStreak(in: inRangeDays)
      )
    )
  }

  private static func emptyDay(
    date: Date,
    key: String,
    label: String,
    isInRange: Bool
  ) -> ActivityDay {
    ActivityDay(
      date: date,
      key: key,
      label: label,
      isInRange: isInRange,
      intensity: 0,
      thingsWorkedOn: 0,
      commits: 0,
      tokens: 0,
      agents: 0,
      additions: 0,
      deletions: 0,
      activeMinutes: 0
    )
  }

  private static func intensity(for value: Int) -> Int {
    switch value {
    case 1: 1
    case 2...4: 2
    case 5...9: 3
    default: 4
    }
  }

  private static func monthLabels(
    for weeks: [[ActivityDay]],
    calendar: Calendar
  ) -> [ActivityMonthLabel] {
    var previousMonth = -1
    var months: [ActivityMonthLabel] = []
    for (weekIndex, week) in weeks.enumerated() {
      guard weekIndex > 2,
        let candidate = week.first(where: {
          $0.isInRange && calendar.component(.day, from: $0.date) <= 7
        })
      else { continue }
      let month = calendar.component(.month, from: candidate.date)
      guard month != previousMonth else { continue }
      months.append(
        ActivityMonthLabel(
          title: ActivityFormatters.month.string(from: candidate.date),
          weekIndex: weekIndex
        )
      )
      previousMonth = month
    }
    return months
  }

  private static func streakLengths(in days: [ActivityDay]) -> [Int] {
    var streaks: [Int] = []
    var running = 0
    for day in days {
      if day.intensity > 0 {
        running += 1
      } else if running > 0 {
        streaks.append(running)
        running = 0
      }
    }
    if running > 0 { streaks.append(running) }
    return streaks
  }

  private static func currentStreak(in days: [ActivityDay]) -> Int {
    var streak = 0
    for day in days.reversed() {
      guard day.intensity > 0 else { break }
      streak += 1
    }
    return streak
  }

  private static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}

extension ActivityDataFactory {
  fileprivate static func makeDay(
    source: AgentSource,
    date: Date,
    index: Int,
    isInRange: Bool,
    calendar: Calendar
  ) -> ActivityDay {
    let key = ActivityFormatters.dateKey.string(from: date)
    let label = ActivityFormatters.dateLabel.string(from: date)
    guard isInRange else {
      return emptyDay(date: date, key: key, label: label, isInRange: false)
    }

    let random = seededValue(source.seed ^ (UInt32(truncatingIfNeeded: index) &* 2_654_435_761))
    let weekday = calendar.component(.weekday, from: date)
    let weekdayBoost = (2...6).contains(weekday) ? 0.1 : -0.18
    guard random < source.activityRate + weekdayBoost else {
      return emptyDay(date: date, key: key, label: label, isInRange: true)
    }

    let detail = seededValue(source.seed ^ (UInt32(truncatingIfNeeded: index) &* 1_597_334_677))
    let intensity = min(4, 1 + Int(detail * 4))
    let commits = 1 + Int(detail * 5) + (intensity == 4 ? 2 : 0)
    let things = max(1, commits + Int(random * 4) - 1)

    return ActivityDay(
      date: date,
      key: key,
      label: label,
      isInRange: true,
      intensity: intensity,
      thingsWorkedOn: things,
      commits: commits,
      tokens: (18 + Int(detail * 132)) * 1_000,
      agents: 1 + Int(detail * 3),
      additions: 94 + Int(detail * 1_120),
      deletions: 18 + Int(random * 340),
      activeMinutes: 28 + Int(random * 188)
    )
  }

  fileprivate static func emptyDay(
    date: Date,
    key: String,
    label: String,
    isInRange: Bool
  ) -> ActivityDay {
    ActivityDay(
      date: date,
      key: key,
      label: label,
      isInRange: isInRange,
      intensity: 0,
      thingsWorkedOn: 0,
      commits: 0,
      tokens: 0,
      agents: 0,
      additions: 0,
      deletions: 0,
      activeMinutes: 0
    )
  }

  fileprivate static func fitCommitTotal(days: inout [ActivityDay], target: Int, lockedKey: String?)
  {
    let activeIndices = days.indices.filter { days[$0].isInRange && days[$0].intensity > 0 }
    guard !activeIndices.isEmpty else { return }

    var difference = target - activeIndices.reduce(0) { $0 + days[$1].commits }
    var cursor = 0

    while difference != 0 && cursor < 20_000 {
      let index = activeIndices[cursor % activeIndices.count]
      defer { cursor += 1 }
      if days[index].key == lockedKey { continue }

      if difference > 0 {
        days[index].commits += 1
        days[index].thingsWorkedOn = max(days[index].thingsWorkedOn, days[index].commits)
        difference -= 1
      } else if days[index].commits > 1 {
        days[index].commits -= 1
        difference += 1
      }
    }
  }

  fileprivate static func seededValue(_ seed: UInt32) -> Double {
    var value = seed
    value ^= value << 13
    value ^= value >> 17
    value ^= value << 5
    return Double(value) / Double(UInt32.max)
  }

  fileprivate static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}
