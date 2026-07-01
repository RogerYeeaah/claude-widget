import SwiftUI
import ServiceManagement

@main
struct ClaudeUsageApp: App {
    init() {
        UsageServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var isLoginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color(red: 0.745, green: 0.455, blue: 0.341))
            Text("Claude Usage Widget")
                .font(.headline)
            HStack(spacing: 6) {
                Circle().fill(UsageServer.shared.isRunning ? .green : .orange).frame(width: 8, height: 8)
                Text(UsageServer.shared.isRunning ? "Server running on :8787" : "Port :8787 已由另一實例使用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("右鍵點擊桌面 → 編輯小工具 → 加入 Claude Usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Divider()
            Toggle("開機自動啟動", isOn: $isLoginItem)
                .font(.caption)
                .onChange(of: isLoginItem) { _, newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else        { try SMAppService.mainApp.unregister() }
                    } catch {
                        isLoginItem = !newValue
                    }
                }
        }
        .padding(32)
        .frame(width: 320, height: 220)
    }
}
