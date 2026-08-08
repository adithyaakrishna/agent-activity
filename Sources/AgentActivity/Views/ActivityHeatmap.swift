import SwiftUI

struct ActivityHeatmap: View {
  let source: AgentSource
  let dataset: ActivityDataset
  let replayID: UUID
  let animateWeeks: Bool

  var body: some View {
    HStack(spacing: 6) {
      WeekdayAxis()
      VStack(alignment: .leading, spacing: 0) {
        MonthAxis(months: dataset.months)
        HStack(spacing: 2) {
          ForEach(Array(dataset.weeks.enumerated()), id: \.offset) { index, week in
            HeatmapWeek(source: source, days: week, index: index, animate: animateWeeks)
          }
        }
        .frame(width: 475, height: 61, alignment: .topLeading)
      }
      .frame(width: 475, height: 77, alignment: .topLeading)
    }
    .frame(width: 503, height: 77, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent activity by day")
  }
}

private struct WeekdayAxis: View {
  private let labels = ["", "Mon", "", "Wed", "", "Fri", ""]

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: 16)
      VStack(spacing: 2) {
        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
          Text(label)
            .font(.system(size: 9, weight: .medium))
            .tracking(-0.15)
            .foregroundStyle(Color.agentZinc500)
            .frame(width: 22, height: 7, alignment: .leading)
        }
      }
    }
    .frame(width: 22, height: 77, alignment: .topLeading)
    .accessibilityHidden(true)
  }
}

private struct MonthAxis: View {
  let months: [ActivityMonthLabel]

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      ForEach(months) { month in
        Text(month.title)
          .font(.system(size: 10, weight: .medium))
          .tracking(-0.15)
          .foregroundStyle(Color.agentZinc500)
          .offset(x: CGFloat(month.weekIndex * 9), y: -3)
      }
    }
    .frame(width: 475, height: 16, alignment: .bottomLeading)
    .accessibilityHidden(true)
  }
}

private struct HeatmapWeek: View {
  let source: AgentSource
  let days: [ActivityDay]
  let index: Int
  let animate: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isVisible = false

  var body: some View {
    VStack(spacing: 2) {
      ForEach(days) { day in
        HeatmapCell(source: source, day: day)
      }
    }
    .frame(width: 7, height: 61, alignment: .top)
    .opacity(!animate || reduceMotion || isVisible ? 1 : 0)
    .offset(y: !animate || reduceMotion || isVisible ? 0 : 4)
    .onAppear {
      guard animate && !reduceMotion else {
        isVisible = true
        return
      }
      isVisible = false
      withAnimation(
        .timingCurve(0.23, 1, 0.32, 1, duration: 0.3)
          .delay(Double(index) * 0.016)
      ) {
        isVisible = true
      }
    }
  }
}

private struct HeatmapCell: View {
  let source: AgentSource
  let day: ActivityDay
  @State private var isHovered = false
  @State private var isDetailPresented = false

  var body: some View {
    Group {
      if day.isInRange {
        Button {
          guard day.intensity > 0 else { return }
          isDetailPresented.toggle()
        } label: {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.heatmapIntensity(day.intensity))
            .frame(width: 7, height: 7)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.4 : 1)
        .zIndex(isHovered ? 10 : 0)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14), value: isHovered)
        .onHover { hovering in
          isHovered = hovering
          isDetailPresented = hovering && day.intensity > 0
        }
        .popover(
          isPresented: $isDetailPresented,
          attachmentAnchor: .rect(.bounds),
          arrowEdge: .trailing
        ) {
          ActivityDayDetail(source: source, day: day)
        }
        .accessibilityLabel(day.accessibilitySummary)
      } else {
        Color.clear.frame(width: 7, height: 7)
      }
    }
    .frame(width: 7, height: 7)
  }
}
