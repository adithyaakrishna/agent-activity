import SwiftUI

struct ActivityDayDetail: View {
    let source: AgentSource
    let day: ActivityDay

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(day.label)
                .font(.system(size: 12, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Color.agentZinc900)
                .padding(.bottom, 1)

            if source == .github {
                DetailRow(
                    systemImage: "arrow.triangle.branch",
                    text: "\(day.thingsWorkedOn) GitHub contributions"
                )
                UnavailableDetailRow(text: "Daily contribution types unavailable")
            } else {
                DetailRow(systemImage: "checklist", text: "\(day.thingsWorkedOn) agent actions")

                if day.commits == 0 {
                    UnavailableDetailRow(text: "Commit attribution unavailable")
                } else {
                    DetailRow(
                        systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                        text: "\(day.commits) commits"
                    )
                }

                if day.tokens > 0 {
                    DetailRow(
                        systemImage: "cylinder.split.1x2",
                        text: "\(ActivityFormatters.tokens(day.tokens)) tokens"
                    )
                } else {
                    UnavailableDetailRow(text: "Token usage unavailable")
                }

                DetailRow(systemImage: "person.2", text: "\(day.agents) agents")

                if day.additions > 0 || day.deletions > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .frame(width: 14)
                            .foregroundStyle(Color.agentZinc500)
                        HStack(spacing: 0) {
                            Text("+\(day.additions)")
                                .foregroundStyle(Color(hex: 0x15803D))
                            Text(" / ")
                                .foregroundStyle(Color.agentZinc500.opacity(0.65))
                            Text("−\(day.deletions)")
                                .foregroundStyle(Color(hex: 0xDC2626))
                            Text(" lines")
                                .foregroundStyle(Color.agentZinc600)
                        }
                    }
                } else {
                    UnavailableDetailRow(text: "Line changes unavailable")
                }

                DetailRow(systemImage: "clock", text: "\(day.activeTimeLabel) active")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .tracking(-0.1)
        .padding(12)
        .frame(width: 222, alignment: .leading)
        .background(Color.white)
        .preferredColorScheme(.light)
        .accessibilityElement(children: .combine)
    }
}

private struct UnavailableDetailRow: View {
    let text: String

    var body: some View {
        DetailRow(systemImage: "minus.circle", text: text)
            .opacity(0.7)
    }
}

private struct DetailRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 14)
                .foregroundStyle(Color.agentZinc500)
            Text(text)
                .foregroundStyle(Color.agentZinc600)
        }
    }
}
