import SwiftUI
import Combine
import Observation

// MARK: - Event Struct

struct RecordedEvent: Codable, Identifiable {
    var id = UUID()
    let type: String          // "leftMouseDown", "leftMouseUp", "rightMouseDown", "rightMouseUp", "mouseMove", "keyDown", "keyUp", "flagsChanged", "scrollWheel"
    let timeOffset: TimeInterval
    let location: CGPoint?    // Coordinates (bottom-left origin)
    let keyCode: UInt16?
    let modifierFlags: UInt64?
    let buttonNumber: Int?
    let scrollDeltaX: Double?
    let scrollDeltaY: Double?
    
    init(type: String, timeOffset: TimeInterval, location: CGPoint? = nil, keyCode: UInt16? = nil, modifierFlags: UInt64? = nil, buttonNumber: Int? = nil, scrollDeltaX: Double? = nil, scrollDeltaY: Double? = nil) {
        self.type = type
        self.timeOffset = timeOffset
        self.location = location
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.buttonNumber = buttonNumber
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }
    
    enum CodingKeys: String, CodingKey {
        case type, timeOffset, location, keyCode, modifierFlags, buttonNumber, scrollDeltaX, scrollDeltaY
    }
}

// MARK: - Manager

@Observable
class MouseLabManager {
    static let shared = MouseLabManager()
    
    enum Status {
        case idle
        case recording
        case playing
        
        var isPlaying: Bool {
            self == .playing
        }
        
        var description: String {
            switch self {
            case .idle: return "閒置"
            case .recording: return "錄製中 🔴"
            case .playing: return "播放還原中 🟢"
            }
        }
    }
    
    var status: Status = .idle
    var recordedEvents: [RecordedEvent] = []
    
    // Playback Settings
    var loopPlayback: Bool = false
    
    // Logs for console
    var consoleLogs: [String] = []
    
    // Saved Tracks
    var savedTracks: [String: [RecordedEvent]] = [:]
    var selectedTrackName: String = ""
    var newTrackName: String = ""
    
    private var startTime: Date = Date()
    private var localMonitor: Any? = nil
    private var globalMonitor: Any? = nil
    private var localHotkeyMonitor: Any? = nil
    private var globalHotkeyMonitor: Any? = nil
    private var lastMouseMoveTime: TimeInterval? = nil
    private var playbackTask: Task<Void, Never>? = nil
    
    init() {
        loadTracksFromDefaults()
        setupHotkeys()
    }
    
    var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        addLog("已拉起權限要求。若先前已授權，請在系統設定中將本程式「減號移除」後重加。")
    }
    
    func addLog(_ message: String) {
        DispatchQueue.main.async {
            self.consoleLogs.append("[\(Self.timeFormatter.string(from: Date()))] \(message)")
            if self.consoleLogs.count > 50 {
                self.consoleLogs.removeFirst()
            }
        }
    }
    
    deinit {
        if let local = localHotkeyMonitor {
            NSEvent.removeMonitor(local)
        }
        if let global = globalHotkeyMonitor {
            NSEvent.removeMonitor(global)
        }
    }
    
    private func setupHotkeys() {
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            _ = self?.handleGlobalKeyDown(event)
        }
        
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if let self = self {
                let modifiers = event.modifierFlags
                if modifiers.contains(.control) || modifiers.contains(.option) {
                    let chars = event.charactersIgnoringModifiers ?? ""
                    self.addLog("偵測到本地修飾組合鍵: \(chars) (keycode:\(event.keyCode), flags:\(modifiers.rawValue))")
                }
                if self.handleGlobalKeyDown(event) {
                    return nil
                }
            }
            return event
        }
    }
    
    private func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.option)
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)
        
        guard hasControl && hasOption && !hasCommand && !hasShift else { return false }
        guard let char = event.charactersIgnoringModifiers?.lowercased() else { return false }
        
        if char == "r" {
            DispatchQueue.main.async {
                if self.status == .recording {
                    self.stopRecording()
                } else if self.status == .idle {
                    self.startRecording()
                }
            }
            return true
        } else if char == "p" {
            DispatchQueue.main.async {
                if self.status.isPlaying {
                    self.stopPlayback()
                } else if self.status == .idle {
                    self.startPlayback()
                }
            }
            return true
        }
        return false
    }
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    // MARK: - Recording Control
    
    func startRecording() {
        guard status == .idle else { return }
        recordedEvents.removeAll()
        consoleLogs.removeAll()
        status = .recording
        startTime = Date()
        lastMouseMoveTime = nil
        addLog("開始錄製鍵盤與滑鼠事件...")
        
        let eventMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .keyDown, .keyUp, .flagsChanged, .scrollWheel
        ]
        
        // Setup local monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.recordEvent(event)
            return event
        }
        
        // Setup global monitor
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.recordEvent(event)
        }
        
        // Check accessibility status
        if !AXIsProcessTrusted() {
            addLog("警告：未啟用「輔助使用」權限，在背景時將無法錄製其他應用程式的事件。")
        }
    }
    
    func stopRecording() {
        guard status == .recording else { return }
        
        if let local = localMonitor {
            NSEvent.removeMonitor(local)
            localMonitor = nil
        }
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        
        status = .idle
        addLog("停止錄製。共錄製了 \(recordedEvents.count) 個事件。")
    }
    
    private func recordEvent(_ event: NSEvent) {
        // Prevent recording the global hotkeys themselves
        if event.type == .keyDown || event.type == .keyUp {
            let modifiers = event.modifierFlags
            let hasControl = modifiers.contains(.control)
            let hasOption = modifiers.contains(.option)
            let hasCommand = modifiers.contains(.command)
            let hasShift = modifiers.contains(.shift)
            
            if hasControl && hasOption && !hasCommand && !hasShift {
                if let char = event.charactersIgnoringModifiers?.lowercased(), char == "r" || char == "p" {
                    return
                }
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let type: String
        var location: CGPoint? = nil
        var keyCode: UInt16? = nil
        var modifierFlags: UInt64? = nil
        var buttonNumber: Int? = nil
        var scrollDeltaX: Double? = nil
        var scrollDeltaY: Double? = nil
        
        switch event.type {
        case .leftMouseDown:
            type = "leftMouseDown"
            location = NSEvent.mouseLocation
            buttonNumber = 0
        case .leftMouseUp:
            type = "leftMouseUp"
            location = NSEvent.mouseLocation
            buttonNumber = 0
        case .rightMouseDown:
            type = "rightMouseDown"
            location = NSEvent.mouseLocation
            buttonNumber = 1
        case .rightMouseUp:
            type = "rightMouseUp"
            location = NSEvent.mouseLocation
            buttonNumber = 1
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            type = "mouseMove"
            location = NSEvent.mouseLocation
        case .keyDown:
            type = "keyDown"
            keyCode = event.keyCode
            modifierFlags = UInt64(event.modifierFlags.rawValue)
        case .keyUp:
            type = "keyUp"
            keyCode = event.keyCode
            modifierFlags = UInt64(event.modifierFlags.rawValue)
        case .flagsChanged:
            type = "flagsChanged"
            keyCode = event.keyCode
            modifierFlags = UInt64(event.modifierFlags.rawValue)
        case .scrollWheel:
            type = "scrollWheel"
            location = NSEvent.mouseLocation
            scrollDeltaX = Double(event.scrollingDeltaX)
            scrollDeltaY = Double(event.scrollingDeltaY)
        default:
            return
        }
        
        // Throttle mouse movements to 25ms to reduce data bloat
        if type == "mouseMove" {
            if let lastTime = lastMouseMoveTime, elapsed - lastTime < 0.025 {
                return
            }
            lastMouseMoveTime = elapsed
        }
        
        let newEvent = RecordedEvent(
            type: type,
            timeOffset: elapsed,
            location: location,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            buttonNumber: buttonNumber,
            scrollDeltaX: scrollDeltaX,
            scrollDeltaY: scrollDeltaY
        )
        
        DispatchQueue.main.async {
            self.recordedEvents.append(newEvent)
            
            // Format log preview
            var detail = ""
            if let loc = location {
                detail += String(format: " 位置:(%.0f, %.0f)", loc.x, loc.y)
            }
            if let code = keyCode {
                detail += " 鍵值:\(code)"
            }
            if type == "scrollWheel", let dx = scrollDeltaX, let dy = scrollDeltaY {
                detail += String(format: " 滾動 dy:%.1f, dx:%.1f", dy, dx)
            }
            self.addLog("錄製 \(type)\(detail)")
        }
    }
    
    // MARK: - Playback Control
    
    func startPlayback() {
        guard status == .idle, !recordedEvents.isEmpty else { return }
        status = .playing
        addLog("啟動播放還原...")
        
        playbackTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            repeat {
                var lastEventTime: TimeInterval = 0
                
                for event in self.recordedEvents {
                    if Task.isCancelled { break }
                    
                    let delta = event.timeOffset - lastEventTime
                    lastEventTime = event.timeOffset
                    
                    if delta > 0 {
                        try? await Task.sleep(for: .seconds(delta))
                    }
                    
                    if Task.isCancelled { break }
                    
                    await self.replayEvent(event)
                }
                
            } while self.loopPlayback && !Task.isCancelled
            
            await MainActor.run {
                self.status = .idle
                self.addLog("播放結束。")
            }
        }
    }
    
    func stopPlayback() {
        guard status.isPlaying else { return }
        playbackTask?.cancel()
        playbackTask = nil
        status = .idle
        addLog("播放已手動停止。")
    }
    
    private func replayEvent(_ event: RecordedEvent) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let screenHeight = NSScreen.screens.first?.frame.size.height ?? 1080
        
        var targetLoc: CGPoint? = nil
        if let loc = event.location {
            // Convert bottom-left coordinates (NSEvent) to top-left coordinates (CGEvent)
            targetLoc = CGPoint(x: loc.x, y: screenHeight - loc.y)
        }
        
        if event.type == "mouseMove", let target = targetLoc {
            let moveEvt = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)
            moveEvt?.post(tap: .cgSessionEventTap)
            
        } else if event.type == "leftMouseDown" || event.type == "leftMouseUp" || event.type == "rightMouseDown" || event.type == "rightMouseUp", let target = targetLoc {
            let button: CGMouseButton = event.type.contains("right") ? .right : .left
            let type: CGEventType
            
            switch event.type {
            case "leftMouseDown": type = .leftMouseDown
            case "leftMouseUp": type = .leftMouseUp
            case "rightMouseDown": type = .rightMouseDown
            default: type = .rightMouseUp
            }
            
            let clickEvt = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button)
            clickEvt?.post(tap: .cgSessionEventTap)
            self.addLog("再現滑鼠點擊: \(event.type) 座標:(\(Int(target.x)), \(Int(target.y)))")
            
        } else if event.type == "keyDown" || event.type == "keyUp", let code = event.keyCode {
            let isDown = event.type == "keyDown"
            let keyEvt = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
            if let flags = event.modifierFlags {
                keyEvt?.flags = CGEventFlags(rawValue: flags)
            }
            keyEvt?.post(tap: .cgSessionEventTap)
            self.addLog("再現按鍵: \(event.type) 鍵值:\(code)")
            
        } else if event.type == "flagsChanged", let code = event.keyCode {
            let flagsEvt = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            if let flags = event.modifierFlags {
                flagsEvt?.flags = CGEventFlags(rawValue: flags)
            }
            flagsEvt?.post(tap: .cgSessionEventTap)
            self.addLog("再現修飾鍵狀態變更")
        } else if event.type == "scrollWheel", let dx = event.scrollDeltaX, let dy = event.scrollDeltaY {
            let scrollEvt = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(dy),
                wheel2: Int32(dx),
                wheel3: 0
            )
            scrollEvt?.post(tap: .cgSessionEventTap)
            self.addLog(String(format: "再現滾輪滾動: dy:%.1f, dx:%.1f", dy, dx))
        }
    }
    
    func clearEvents() {
        recordedEvents.removeAll()
        consoleLogs.removeAll()
        addLog("事件記錄已清空。")
    }
    
    // MARK: - Persistence
    
    func saveCurrentTrack() {
        guard !newTrackName.isEmpty else { return }
        guard !recordedEvents.isEmpty else {
            addLog("錯誤：目前沒有錄製的事件可供儲存。")
            return
        }
        
        savedTracks[newTrackName] = recordedEvents
        saveTracksToDefaults()
        selectedTrackName = newTrackName
        UserDefaults.standard.set(selectedTrackName, forKey: "MouseLabSelectedTrackName")
        addLog("成功儲存軌跡「\(newTrackName)」")
        newTrackName = ""
    }
    
    func loadSelectedTrack() {
        guard !selectedTrackName.isEmpty, let track = savedTracks[selectedTrackName] else { return }
        recordedEvents = track
        UserDefaults.standard.set(selectedTrackName, forKey: "MouseLabSelectedTrackName")
        addLog("成功載入軌跡「\(selectedTrackName)」，共計 \(track.count) 個事件。")
    }
    
    func deleteSelectedTrack() {
        guard !selectedTrackName.isEmpty else { return }
        savedTracks.removeValue(forKey: selectedTrackName)
        saveTracksToDefaults()
        addLog("已刪除軌跡「\(selectedTrackName)」")
        selectedTrackName = ""
        UserDefaults.standard.removeObject(forKey: "MouseLabSelectedTrackName")
    }
    
    private func saveTracksToDefaults() {
        if let data = try? JSONEncoder().encode(savedTracks) {
            UserDefaults.standard.set(data, forKey: "MouseLabSavedTracks")
        }
    }
    
    private func loadTracksFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: "MouseLabSavedTracks"),
           let decoded = try? JSONDecoder().decode([String: [RecordedEvent]].self, from: data) {
            savedTracks = decoded
        }
        if let lastSelected = UserDefaults.standard.string(forKey: "MouseLabSelectedTrackName"),
           savedTracks.keys.contains(lastSelected) {
            selectedTrackName = lastSelected
            recordedEvents = savedTracks[lastSelected] ?? []
        }
    }
    
    // MARK: - JSON Export/Import
    
    func exportToJSON() {
        guard !recordedEvents.isEmpty else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = selectedTrackName.isEmpty ? "mouselab_track.json" : "\(selectedTrackName).json"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    let data = try JSONEncoder().encode(self.recordedEvents)
                    try data.write(to: url)
                    self.addLog("成功匯出軌跡至: \(url.lastPathComponent)")
                } catch {
                    self.addLog("匯出 JSON 失敗: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func importFromJSON() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                do {
                    let data = try Data(contentsOf: url)
                    let decoded = try JSONDecoder().decode([RecordedEvent].self, from: data)
                    self.recordedEvents = decoded
                    self.selectedTrackName = ""
                    UserDefaults.standard.removeObject(forKey: "MouseLabSelectedTrackName")
                    self.addLog("成功從 \(url.lastPathComponent) 匯入 \(decoded.count) 個事件")
                } catch {
                    self.addLog("匯入 JSON 失敗: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - SwiftUI View

struct MouseLabView: View {
    static var isAvailable: Bool {
        if UserDefaults.standard.object(forKey: "MouseLabEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "MouseLabEnabled")
        }
        return true
    }
    
    static func initializeOnStartup() {
        _ = MouseLabManager.shared
    }
    
    let manager = MouseLabManager.shared
    
    var body: some View {
        @Bindable var manager = manager
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("鍵鼠錄製與還原實驗室")
                    .font(.headline)
                Spacer()
                
                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(manager.status.description)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            if !manager.isAccessibilityEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("未啟用或需要重置輔助使用權限！")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.primary)
                        Spacer()
                        Button("開啟設定授權") {
                            manager.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                    Text("全域錄製與快捷鍵在背景時需要「輔助使用」權限。若先前已勾選授權但按了無效，這是 macOS 對重新編譯應用的已知問題，請將本程式從「系統設定 > 輔助使用」列表中「減號」移除後重新加入啟用。")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    
                    // Hotkey Info Bar
                    HStack(spacing: 12) {
                        Image(systemName: "keyboard")
                            .font(.title3)
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全域快捷鍵提示：")
                                .font(.caption)
                                .bold()
                            Text("錄製/暫停：⌃⌥R (Control + Option + R)  |  播放還原/暫停：⌃⌥P (Control + Option + P)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                    
                    // Group 1: Recording & Playback Core
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. 錄製與播放控制").font(.subheadline).bold().foregroundStyle(.secondary)
                        
                        HStack(spacing: 12) {
                            if manager.status == .recording {
                                Button(action: { manager.stopRecording() }) {
                                    Label("停止錄製", systemImage: "stop.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            } else {
                                Button(action: { manager.startRecording() }) {
                                    Label("開始錄製", systemImage: "record.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(manager.status.isPlaying)
                            }
                            
                            if manager.status.isPlaying {
                                Button(action: { manager.stopPlayback() }) {
                                    Label("停止播放", systemImage: "stop.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            } else {
                                Button(action: { manager.startPlayback() }) {
                                    Label("開始播放", systemImage: "play.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .disabled(manager.recordedEvents.isEmpty || manager.status == .recording)
                            }
                            
                            Button(role: .destructive, action: { manager.clearEvents() }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(manager.status != .idle || manager.recordedEvents.isEmpty)
                        }
                        
                        Text("目前記憶體已記錄事件數：\(manager.recordedEvents.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                    
                    // Group 2: Playback Settings
                    VStack(alignment: .leading, spacing: 12) {
                        Text("2. 播放設定").font(.subheadline).bold().foregroundStyle(.secondary)
                        
                        Toggle("循環重複播放", isOn: $manager.loopPlayback)
                            .toggleStyle(.checkbox)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                    
                    // Group 3: Track Management
                    VStack(alignment: .leading, spacing: 12) {
                        Text("3. 軌跡存檔與檔案操作").font(.subheadline).bold().foregroundStyle(.secondary)
                        
                        HStack {
                            TextField("新存檔名稱", text: $manager.newTrackName)
                                .textFieldStyle(.roundedBorder)
                            
                            Button("存入記憶體") {
                                manager.saveCurrentTrack()
                            }
                            .buttonStyle(.bordered)
                            .disabled(manager.newTrackName.isEmpty || manager.recordedEvents.isEmpty)
                        }
                        
                        HStack {
                            Picker("選擇載入存檔:", selection: $manager.selectedTrackName) {
                                Text("請選擇...").tag("")
                                ForEach(Array(manager.savedTracks.keys).sorted(), id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: manager.selectedTrackName) { _, _ in
                                manager.loadSelectedTrack()
                            }
                            
                            Button(role: .destructive, action: { manager.deleteSelectedTrack() }) {
                                Text("刪除")
                            }
                            .buttonStyle(.bordered)
                            .disabled(manager.selectedTrackName.isEmpty)
                        }
                        
                        HStack(spacing: 12) {
                            Button(action: { manager.exportToJSON() }) {
                                Label("匯出 JSON...", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(manager.recordedEvents.isEmpty)
                            
                            Button(action: { manager.importFromJSON() }) {
                                Label("匯入 JSON...", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                    
                    // Group 4: Log Output
                    VStack(alignment: .leading, spacing: 8) {
                        Text("運作紀錄日誌").font(.subheadline).bold().foregroundStyle(.secondary)
                        
                        VStack {
                            if manager.consoleLogs.isEmpty {
                                Text("尚無運行日誌，請開始錄製或再現。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            } else {
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 4) {
                                            ForEach(manager.consoleLogs.indices, id: \.self) { idx in
                                                Text(manager.consoleLogs[idx])
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundColor(Color.green)
                                                    .id(idx)
                                            }
                                        }
                                        .padding(8)
                                    }
                                    .frame(height: 120)
                                    .background(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onChange(of: manager.consoleLogs.count) { _, count in
                                        if count > 0 {
                                            proxy.scrollTo(count - 1, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 450, minHeight: 580)
    }
    
    private var statusColor: Color {
        switch manager.status {
        case .idle: return .gray
        case .recording: return .red
        case .playing: return .green
        }
    }
}
