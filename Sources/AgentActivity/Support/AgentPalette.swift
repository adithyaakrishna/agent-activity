import SwiftUI

struct AgentSourcePalette {
    let dot: Color
    let soft: Color
    let ring: Color
    let ink: Color
}

extension AgentSource {
    var palette: AgentSourcePalette {
        switch self {
        case .cursor:
            AgentSourcePalette(
                dot: Color(hex: 0x8B5CF6),
                soft: Color(hex: 0xF5F3FF),
                ring: Color(hex: 0xDDD6FE),
                ink: Color(hex: 0x6D28D9)
            )
        case .codex:
            AgentSourcePalette(
                dot: .agentEmerald500,
                soft: .agentEmerald50,
                ring: .agentEmerald200,
                ink: .agentEmerald700
            )
        case .claude:
            AgentSourcePalette(
                dot: Color(hex: 0xD97757),
                soft: Color(hex: 0xFFF7ED),
                ring: Color(hex: 0xFED7AA),
                ink: Color(hex: 0x9A3412)
            )
        case .github:
            AgentSourcePalette(
                dot: Color(hex: 0x24292F),
                soft: Color(hex: 0xF6F8FA),
                ring: Color(hex: 0xD0D7DE),
                ink: Color(hex: 0x24292F)
            )
        case .others:
            AgentSourcePalette(
                dot: Color(hex: 0xF97316),
                soft: Color(hex: 0xFFF7ED),
                ring: Color(hex: 0xFED7AA),
                ink: Color(hex: 0xC2410C)
            )
        }
    }
}

extension Color {
    init(hex: Int, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static let agentZinc100 = Color(hex: 0xF4F4F5)
    static let agentZinc200 = Color(hex: 0xE4E4E7)
    static let agentZinc500 = Color(hex: 0x71717A)
    static let agentZinc600 = Color(hex: 0x52525B)
    static let agentZinc900 = Color(hex: 0x18181B)
    static let agentEmerald50 = Color(hex: 0xECFDF5)
    static let agentEmerald200 = Color(hex: 0xA7F3D0)
    static let agentEmerald300 = Color(hex: 0x6EE7B7)
    static let agentEmerald500 = Color(hex: 0x10B981)
    static let agentEmerald600 = Color(hex: 0x059669)
    static let agentEmerald700 = Color(hex: 0x047857)

    static func heatmapIntensity(_ level: Int) -> Color {
        switch level {
        case 1: .agentEmerald200
        case 2: .agentEmerald300
        case 3: .agentEmerald500
        case 4...: .agentEmerald600
        default: .agentZinc100
        }
    }
}
