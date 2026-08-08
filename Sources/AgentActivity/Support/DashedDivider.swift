import SwiftUI

struct DashedDivider: View {
  var body: some View {
    GeometryReader { proxy in
      Path { path in
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
      }
      .stroke(
        Color.agentZinc200.opacity(0.8),
        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
      )
    }
    .frame(height: 1)
    .accessibilityHidden(true)
  }
}
