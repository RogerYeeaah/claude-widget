import SwiftUI

enum Theme {
    static let claude = Color(red: 0.745, green: 0.455, blue: 0.341)
    static let weekly = Color(red: 0.463, green: 0.498, blue: 0.776)

    static func usageColor(_ pct: Double, fallback: Color = claude) -> Color {
        pct >= 85 ? .red : pct >= 70 ? .orange : fallback
    }
}
