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

    init() {
        // #21b: Auto-check 5 seconds after launch
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.check()
        }
    }

    func check() {
        if case .checking = state { return }
        guard let repo = repoPath else { state = .idle; return }
        state = .checking

        // #7: Revert to .idle if git fetch blocks for more than 30 seconds
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, case .checking = self.state else { return }
            self.state = .idle
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            gitRun(repo, ["fetch", "origin", "--quiet"])
            timeoutTask.cancel()
            let head   = gitOut(repo, ["rev-parse", "HEAD"])
            let remote = gitOut(repo, ["rev-parse", "origin/main"])
            let n: Int? = (head != nil && head != remote)
                ? (Int(gitOut(repo, ["rev-list", "--count", "HEAD..origin/main"]) ?? "1") ?? 1)
                : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let h = head, let r = remote else { self.state = .idle; return }
                // #9: n == 0 means local is ahead or equal — treat as up-to-date
                if h == r || n == 0 {
                    self.state = .upToDate
                    // #21a: Auto-clear "Already up to date" after 5 seconds
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        guard let self, case .upToDate = self.state else { return }
                        self.state = .idle
                    }
                    return
                }
                self.state = .available(n ?? 1)
            }
        }
    }

    func installUpdate() {
        guard let repo = repoPath else { return }

        // Require explicit confirmation before pulling and executing remote code
        // (git pull + deploy.sh) — an update is arbitrary code execution on this machine.
        let alert = NSAlert()
        alert.messageText = "安裝更新？"
        alert.informativeText = "將從 origin/main 執行 git pull 並跑 deploy.sh 重新部署，完成後 app 會自動重啟。"
        alert.addButton(withTitle: "更新並重啟")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // #10c: Escape single quotes to prevent shell injection, use unique tmp filename
        let safePath = repo.replacingOccurrences(of: "'", with: "'\\''")
        let tmpFile = NSTemporaryDirectory() + "claude-widget-update-\(arc4random()).sh"
        // Per-user temp path (not a fixed name in world-writable /tmp) avoids a symlink
        // pre-placed by another local user redirecting our log writes.
        let logFile = NSTemporaryDirectory() + "claude-widget-update-\(arc4random()).log"
        let script = """
        #!/bin/bash
        until ! pgrep -xq ClaudeWidget; do sleep 0.3; done
        cd '\(safePath)' && git pull && ./deploy.sh
        """
        try? script.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "chmod +x '\(tmpFile)' && nohup '\(tmpFile)' >'\(logFile)' 2>&1 &"]
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        NSApp.terminate(nil)
    }
}

// #17: Guard run() before waitUntilExit — avoids crash if git binary is missing
private func gitOut(_ repo: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    // Discard stderr instead of piping it: an unread stderr Pipe deadlocks git
    // once it fills the ~64 KB buffer (e.g. fetch progress on a large repo).
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    // Read to EOF *before* waitUntilExit: if git's stdout exceeds the pipe buffer,
    // git blocks on write while we'd block on wait — a classic pipe deadlock.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func gitRun(_ repo: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo] + args
    // Discard output: piping stdout/stderr without reading deadlocks git once the buffer fills.
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    p.waitUntilExit()
}

// MARK: - App

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var updater = Updater()

    init() {
        UsageServer.shared.start()
        MouseLabView.initializeOnStartup()
    }

    var body: some Scene {
        // #8: Named window group — enables openWindow(id: "main") from MenuBarExtra
        WindowGroup(id: "main") {
            ContentView(updater: updater)
                .onOpenURL { _ in
                    // #U3: widget tap (claudewidget://open) — surface the main window.
                    // SwiftUI opens a window for this group to deliver the URL if none exists.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
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
    // #8: Use openWindow instead of NSApp.windows.first (which may grab wrong window)
    @Environment(\.openWindow) private var openWindow

    private var isChecking: Bool {
        if case .checking = updater.state { return true }
        return false
    }

    var body: some View {
        if case .upToDate = updater.state {
            Text("已是最新版本").foregroundStyle(.secondary)
        }
        if case .available(let n) = updater.state {
            Text("有 \(n) 個更新可用")
            Button("安裝更新並重啟") { updater.installUpdate() }
        }

        Button(isChecking ? "檢查中…" : "檢查更新") { updater.check() }
            .disabled(isChecking)

        Divider()

        Button("開啟視窗") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        Button("結束 ClaudeWidget") { NSApp.terminate(nil) }
    }
}

// MARK: - Main window

struct ContentView: View {
    let updater: Updater
    @State private var isLoginItem = SMAppService.mainApp.status == .enabled
    @State private var dataReady = false
    @State private var currentFive: Double?
    @State private var currentSeven: Double?
    @State private var showMouseLab = false

    private func barColor(_ pct: Double) -> Color { Theme.usageColor(pct, fallback: .secondary) }

    private func refreshSnapshot() {
        let snap = UsageServer.shared.snapshot  // #6: thread-safe read via queue.sync
        dataReady    = snap.ready
        currentFive  = snap.five
        currentSeven = snap.seven
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.claude)
            Text("Claude 用量 Widget")
                .font(.headline)
            HStack(spacing: 6) {
                Circle().fill(dataReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(dataReady ? "用量資料已同步" : "等待 Claude Code 用量資料…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if currentFive != nil || currentSeven != nil {
                HStack(spacing: 16) {
                    if let f = currentFive {
                        Label("\(Int(f.rounded()))%", systemImage: "clock")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(barColor(f))
                    }
                    if let s = currentSeven {
                        Label("\(Int(s.rounded()))%", systemImage: "calendar")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(barColor(s))
                    }
                }
                .padding(.vertical, 2)
            }
            if case .available(let n) = updater.state {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
                    Text("有 \(n) 個更新可用")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("更新") { updater.installUpdate() }.font(.caption)
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
            if MouseLabView.isAvailable {
                Divider()
                Button(action: { showMouseLab = true }) {
                    Label("開啟鍵鼠錄製面板", systemImage: "hand.tap")
                        .font(.caption)
                }
                .sheet(isPresented: $showMouseLab) {
                    MouseLabView()
                }
            }
        }
        .padding(32)
        .frame(width: 320)
        .onAppear {
            refreshSnapshot()
            updater.check()  // #21b: Check for updates whenever window opens
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        // #13: .task cancels automatically when view disappears — no leaked timer
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                refreshSnapshot()
            }
        }
    }
}
