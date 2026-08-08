import Foundation

enum AgentSource: String, CaseIterable, Identifiable, Sendable {
    case cursor
    case codex
    case claude
    case github
    case others

    var id: Self { self }

    var displayName: String {
        switch self {
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .claude: "Claude"
        case .github: "GitHub"
        case .others: "Others"
        }
    }

    var summary: ActivitySummary {
        switch self {
        case .cursor:
            ActivitySummary(totalCommits: 946, activeDays: 216, longestStreak: 14, currentStreak: 4)
        case .codex:
            ActivitySummary(totalCommits: 1_284, activeDays: 241, longestStreak: 18, currentStreak: 6)
        case .claude:
            ActivitySummary(totalCommits: 684, activeDays: 187, longestStreak: 11, currentStreak: 3)
        case .github:
            ActivitySummary(totalCommits: 2_755, activeDays: 281, longestStreak: 20, currentStreak: 7)
        case .others:
            ActivitySummary(totalCommits: 327, activeDays: 128, longestStreak: 8, currentStreak: 2)
        }
    }

    var activityRate: Double {
        switch self {
        case .cursor: 0.59
        case .codex: 0.67
        case .claude: 0.51
        case .github: 0.75
        case .others: 0.35
        }
    }

    var seed: UInt32 {
        switch self {
        case .cursor: 0x9E37_79B1
        case .codex: 0x85EB_CA6B
        case .claude: 0xC2B2_AE35
        case .github: 0x1656_679B
        case .others: 0x27D4_EB2F
        }
    }

    var summaryNoun: String {
        switch self {
        case .github: "contributions"
        case .cursor, .codex, .claude, .others: "agent actions"
        }
    }
}

struct ActivitySummary: Equatable, Sendable {
    let totalCommits: Int
    let activeDays: Int
    let longestStreak: Int
    let currentStreak: Int
}
