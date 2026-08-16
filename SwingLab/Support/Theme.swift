import SwiftUI
import UIKit

/// SwingLab brand palette: deep fairway green + electric lime accent.
/// Crisp, high-contrast, sporty — works in light and dark mode.
enum Theme {
    static let fairway = Color(red: 0.05, green: 0.36, blue: 0.22)
    static let fairwayDeep = Color(red: 0.02, green: 0.22, blue: 0.14)
    static let lime = Color(red: 0.66, green: 0.91, blue: 0.18)
    static let amber = Color(red: 0.98, green: 0.69, blue: 0.15)
    static let good = Color(red: 0.20, green: 0.78, blue: 0.42)

    static func scoreColor(_ score: Double) -> Color {
        switch score {
        case 80...: return good
        case 60..<80: return amber
        default: return .red
        }
    }

    static var heroGradient: LinearGradient {
        LinearGradient(colors: [fairway, fairwayDeep],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum Haptics {
    static func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
