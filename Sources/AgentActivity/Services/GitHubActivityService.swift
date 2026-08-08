import Foundation

enum GitHubActivityError: LocalizedError {
  case cliUnavailable
  case commandFailed(String)
  case malformedResponse

  var errorDescription: String? {
    switch self {
    case .cliUnavailable:
      "GitHub CLI is not installed"
    case .commandFailed(let message):
      message.isEmpty ? "GitHub CLI request failed" : message
    case .malformedResponse:
      "GitHub returned an unreadable contribution calendar"
    }
  }
}

enum GitHubActivityService {
  private static let query = """
    query($from: DateTime!, $to: DateTime!) {
      viewer {
        contributionsCollection(from: $from, to: $to) {
          contributionCalendar {
            weeks { contributionDays { date contributionCount } }
          }
        }
      }
    }
    """

  static func load(endingOn endDate: Date = Date()) async throws -> ActivityHistoryResult {
    try await Task.detached(priority: .utility) {
      try loadSynchronously(endingOn: endDate)
    }.value
  }

  static func parse(_ data: Data, endingOn endDate: Date) throws -> ActivityHistoryResult {
    let response = try JSONDecoder().decode(GraphQLResponse.self, from: data)
    let days = response.data.viewer.contributionsCollection.contributionCalendar.weeks
      .flatMap(\.contributionDays)

    guard !days.isEmpty else { throw GitHubActivityError.malformedResponse }

    let metrics = Dictionary(
      uniqueKeysWithValues: days.map { day in
        (
          day.date,
          ActivityDayMetrics(
            thingsWorkedOn: day.contributionCount,
            agents: day.contributionCount > 0 ? 1 : 0
          )
        )
      })
    return ActivityHistoryBuilder.make(from: metrics, endingOn: endDate)
  }

  private static func loadSynchronously(endingOn endDate: Date) throws -> ActivityHistoryResult {
    guard let executable = githubCLIURL() else { throw GitHubActivityError.cliUnavailable }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let end = calendar.startOfDay(for: endDate)
    let start = calendar.date(byAdding: .day, value: -364, to: end)!
    let formatter = ISO8601DateFormatter()

    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = [
      "api", "graphql",
      "-f", "query=\(query)",
      "-F", "from=\(formatter.string(from: start))",
      "-F", "to=\(formatter.string(from: end.addingTimeInterval(86_399)))",
    ]
    process.standardOutput = output
    process.standardError = errors

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw GitHubActivityError.commandFailed(
        String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
          ?? ""
      )
    }
    return try parse(data, endingOn: endDate)
  }

  private static func githubCLIURL() -> URL? {
    let candidates = [
      "/opt/homebrew/bin/gh",
      "/usr/local/bin/gh",
      "/usr/bin/gh",
    ]
    return
      candidates
      .first(where: FileManager.default.isExecutableFile(atPath:))
      .map(URL.init(fileURLWithPath:))
  }
}

private struct GraphQLResponse: Decodable {
  let data: GraphQLData
}

private struct GraphQLData: Decodable {
  let viewer: GraphQLViewer
}

private struct GraphQLViewer: Decodable {
  let contributionsCollection: GraphQLContributionCollection
}

private struct GraphQLContributionCollection: Decodable {
  let contributionCalendar: GraphQLContributionCalendar
}

private struct GraphQLContributionCalendar: Decodable {
  let weeks: [GraphQLContributionWeek]
}

private struct GraphQLContributionWeek: Decodable {
  let contributionDays: [GraphQLContributionDay]
}

private struct GraphQLContributionDay: Decodable {
  let date: String
  let contributionCount: Int
}
