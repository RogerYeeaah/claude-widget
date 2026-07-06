import SwiftUI
import ServiceManagement

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        UsageServer.shared.flush()
    }
}

// MARK: - Updater

@Observable
final class Updater {
    enum State { case idle, checking, upToDate, available(Int) }
    var state: State = .idle

    private var repoPathCache: String?
    private var repoPathLoaded = false

    var repoPath: String? {
        if !repoPathLoaded {
            repoPathLoaded = true
            repoPathCache = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude/widget-repo-path", encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return repoPathCache
    }

    var hasUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    func check() {
        if case .checking = state { return }
        guard let repo = repoPath else { state = .idle; return }
        state = .checking
        Task.detached(priority: .userInitiated) { [weak self] in
            gitRun(repo, ["fetch", "origin", "--quiet"])
            let head   = gitOut(repo, ["rev-parse", "HEAD"])
            let remote = gitOut(repo, ["rev-parse", "origin/main"])
            let n: Int? = (head != nil && head != remote)
                ? (Int(gitOut(repo, ["rev-list", "--count", "HEAD..origin/main"]) ?? "1") ?? 1)
                : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let h = head, let r = remote else { self.state = .idle; return }
                if h == r { self.state = .upToDate; return }
                self.state = .available(n ?? 1)
            }
        }
    }

    func installUpdate() {
        guard let repo = repoPath else { return }
        let script = """
        #!/bin/bash
        until ! pgrep -xq ClaudeWidget; do sleep 0.3; done
        cd '\(repo)' && git pull && ./deploy.sh
        """
        let tmp = "/tmp/claude-widget-update.sh"
        try? script.write(toFile: tmp, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "chmod +x '\(tmp)' && nohup '\(tmp)' >/tmp/claude-widget-update.log 2>&1 &"]
        try? p.run(); p.waitUntilExit()
        NSApp.terminate(nil)
    }
}

private func gitOut(_ repo: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func gitRun(_ repo: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo] + args
    p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
}

// MARK: - App

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var updater = Updater()

    init() {
        UsageServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(updater: updater)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent(updater: updater)
        } label: {
            Image(systemName: updater.hasUpdate ? "arrow.up.circle" : "gauge.medium")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu

struct MenuContent: View {
    let updater: Updater

    private var isChecking: Bool {
        if case .checking = updater.state { return true }
        return false
    }

    var body: some View {
        if case .upToDate = updater.state {
            Text("Already up to date").foregroundStyle(.secondary)
        }
        if case .available(let n) = updater.state {
            Text("\(n) update\(n == 1 ? "" : "s") available")
            Button("Install Update & Restart") { updater.installUpdate() }
        }

        Button(isChecking ? "Checking…" : "Check for Updates") { updater.check() }
            .disabled(isChecking)

        Divider()

        Button("Open Window") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        Divider()

        Button("Quit ClaudeWidget") { NSApp.terminate(nil) }
    }
}

// MARK: - Main window

struct ContentView: View {
    let updater: Updater
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
            if case .available(let n) = updater.state {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
                    Text("\(n) update\(n == 1 ? "" : "s") available")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Update") { updater.installUpdate() }.font(.caption)
                }
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
        .frame(width: 320, height: 240)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
