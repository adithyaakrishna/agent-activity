import AppKit
import SwiftUI

struct ActivityPopoverView: View {
  @ObservedObject var store: ActivityStore
  var animateWeeks = true

  var body: some View {
    VStack(spacing: 0) {
      ActivityHeaderView(onReplay: store.replay)
      AgentSourceTabs(
        selectedSource: store.selectedSource,
        onSelect: store.select
      )
      .padding(.horizontal, 16)
      .padding(.bottom, 12)

      ActivityCalendarPanel(
        source: store.selectedSource,
        dataset: store.dataset,
        summary: store.summary,
        loadState: store.loadState,
        replayID: store.replayID,
        animateWeeks: animateWeeks
      )
      .padding(.horizontal, 10)
      .padding(.bottom, 10)
    }
    .frame(width: 560, height: 298, alignment: .top)
    .background(Color.agentZinc100)
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .contextMenu {
      Button("Replay year") {
        store.replay()
      }
      Button("Choose repository folders…") {
        store.chooseRepositoryFolders()
      }
      Divider()
      Button("Quit Agent Activity") {
        NSApplication.shared.terminate(nil)
      }
    }
    .preferredColorScheme(.light)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent activity")
  }
}

private struct ActivityHeaderView: View {
  let onReplay: () -> Void
  @State private var rotation = 0.0

  var body: some View {
    HStack(spacing: 8) {
      Text("Activity")
        .font(.system(size: 15, weight: .semibold))
        .tracking(-0.25)
        .foregroundStyle(Color.agentZinc900)

      Text("Aug 2025 – Aug 2026")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(Color.agentZinc600)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(Color.agentZinc200.opacity(0.8), in: Capsule())

      Spacer(minLength: 0)

      Button {
        onReplay()
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.45)) {
          rotation -= 360
        }
      } label: {
        Image(systemName: "arrow.counterclockwise")
          .font(.system(size: 12, weight: .bold))
          .rotationEffect(.degrees(rotation))
          .frame(width: 28, height: 28)
          .foregroundStyle(Color.agentZinc500)
          .background(Color.agentZinc200.opacity(0.7), in: Circle())
      }
      .buttonStyle(.plain)
      .help("Replay year")
      .accessibilityLabel("Replay year")
    }
    .padding(.horizontal, 24)
    .padding(.top, 20)
    .padding(.bottom, 10)
  }
}

private struct AgentSourceTabs: View {
  let selectedSource: AgentSource
  let onSelect: (AgentSource) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(AgentSource.allCases) { source in
        let isSelected = source == selectedSource
        Button {
          onSelect(source)
        } label: {
          HStack(spacing: 6) {
            Circle()
              .fill(source.palette.dot)
              .frame(width: 8, height: 8)
            Text(source.displayName)
              .font(.system(size: 12, weight: .medium))
              .tracking(-0.2)
          }
          .foregroundStyle(isSelected ? source.palette.ink : Color.agentZinc500)
          .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
          .background {
            if isSelected {
              Capsule()
                .fill(source.palette.soft)
                .overlay {
                  Capsule()
                    .stroke(source.palette.ring, lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.06), radius: 1, y: 1)
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
      }
    }
    .padding(2)
    .frame(height: 32)
    .background(Color.agentZinc200.opacity(0.7), in: Capsule())
    .animation(.easeOut(duration: 0.18), value: selectedSource)
  }
}
