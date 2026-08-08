import SwiftUI

struct ActivityCalendarPanel: View {
    let source: AgentSource
    let dataset: ActivityDataset
    let summary: ActivitySummary
    let replayID: UUID
    let animateWeeks: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommitSummary(total: summary.totalCommits, noun: source.summaryNoun)
                .frame(height: 17, alignment: .leading)

            Spacer().frame(height: 14)

            ActivityHeatmap(
                source: source,
                dataset: dataset,
                replayID: replayID,
                animateWeeks: animateWeeks
            )
                .id(replayID)

            Spacer().frame(height: 14)
            DashedDivider()
            Spacer().frame(height: 12)
            ActivitySummaryFooter(summary: summary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: 540, height: 186, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(source.displayName) activity")
    }
}

private struct CommitSummary: View {
    let total: Int
    let noun: String

    var body: some View {
        HStack(spacing: 4) {
            Text(total.formatted(.number.grouping(.automatic)))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.agentZinc900)
            Text("\(noun) in the last year")
                .font(.system(size: 13, weight: .medium))
                .tracking(-0.2)
                .foregroundStyle(Color.agentZinc500)
        }
    }
}

private struct ActivitySummaryFooter: View {
    let summary: ActivitySummary

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                InlineMetric(title: "Active", value: "\(summary.activeDays)d")
                InlineMetric(title: "Longest", value: "\(summary.longestStreak)d")
                InlineMetric(title: "Current", value: "\(summary.currentStreak)d")
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Text("Less")
                    .padding(.trailing, 2)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.heatmapIntensity(level))
                        .frame(width: 7, height: 7)
                }
                Text("More")
                    .padding(.leading, 2)
            }
            .font(.system(size: 10.5, weight: .medium))
            .tracking(-0.15)
            .foregroundStyle(Color.agentZinc500)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heatmap intensity from less to more")
        }
        .frame(height: 14)
    }
}

private struct InlineMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(Color.agentZinc500)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.agentEmerald600)
        }
        .font(.system(size: 11.5, weight: .medium))
        .tracking(-0.15)
    }
}
