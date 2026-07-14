import Foundation

// Shared App Group container used to pass data from the app to the widget.
// macOS App Group IDs must be prefixed with the Team ID.
enum SharedStore {
    static let appGroupID = "8JRSUP34HG.com.local.ClaudeWidget"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    static var usageURL: URL?   { containerURL?.appendingPathComponent("usage.json") }
    static var historyURL: URL? { containerURL?.appendingPathComponent("history.json") }
}
