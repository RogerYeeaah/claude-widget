import Foundation
import Network
import WidgetKit

final class UsageServer {
    static let shared = UsageServer()

    // MARK: - Constants (#16)
    private enum C {
        static let port: UInt16 = 8787
        static let minSampleIntervalMs: Double = 1_200_000   // 20 min
        static let backfillStepMs: Double     = 1_200_000   // 20 min
        static let fiveHourWindowMs: Double   = 18_000_000  // 5 h
        static let gapThresholdMs: Double     = 1_200_000   // 20 min gap → backfill
        static let saveIntervalMs: Double     = 300_000     // 5 min
        static let maxHistoryPoints           = 200         // ~2.8 days at 20-min granularity
        static let backfillLeadMs: Double     = 15_000      // stop backfill 15 s before now
    }

    // All mutable state lives on `queue`
    private var listener: NWListener?
    private var history: [[String: Any]] = []
    private var lastHistoryTs: Double = 0
    private let queue = DispatchQueue(label: "usage-server", qos: .utility)
    private var cacheSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var cachedUsageResponse: Data?
    private var lastSaveHistoryTs: Double = 0
    private var _isRunning = false
    private var _currentFive: Double?
    private var _currentSeven: Double?

    private let usageCacheURL: URL
    private let historyFileURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        usageCacheURL = home.appendingPathComponent(".claude/usage-cache.json")
        historyFileURL = home.appendingPathComponent(".claude/widget-history.json")
        loadHistory()
    }

    // #6: Thread-safe read — safe to call from any thread (including MainActor).
    var snapshot: (running: Bool, five: Double?, seven: Double?) {
        queue.sync { (_isRunning, _currentFive, _currentSeven) }
    }

    // MARK: - Start

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // #1: Bind to loopback — widget traffic never leaves this machine
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: C.port)!)
        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self._isRunning = true
                self.scheduleWidgetReload()  // #4: Push fresh timeline when server comes up
            case .failed:
                self._isRunning = false
                self.listener?.cancel()
                self.listener = nil
                // #5b: Retry listener after 5 s (port may have freed up)
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        watchCacheFile()
    }

    private func watchCacheFile() {
        cacheSource?.cancel()
        let fd = open(usageCacheURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // #5a: Cache file doesn't exist yet — retry until Claude writes it
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.watchCacheFile() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self else { return }
            self.rebuildUsageCache()
            self.scheduleWidgetReload()
            if let events = src?.data, !events.intersection([.rename, .delete]).isEmpty {
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.watchCacheFile() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        cacheSource = src
        queue.async { [weak self] in self?.rebuildUsageCache() }
    }

    private func scheduleWidgetReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { WidgetCenter.shared.reloadAllTimelines() }
        pendingReload = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { connection.cancel(); return }
            let path = self.extractPath(from: String(data: data, encoding: .utf8) ?? "")
            let response = self.buildResponse(for: path)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func extractPath(from request: String) -> String {
        let firstLine = request.prefix(while: { $0 != "\r" && $0 != "\n" })
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1]).components(separatedBy: "?").first ?? "/"
    }

    private func buildResponse(for path: String) -> Data {
        let body: Data
        switch path {
        case "/api/usage":   body = makeUsageJSON()
        case "/api/history": body = makeHistoryJSON()
        default:             body = Data("{}".utf8)
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    // MARK: - Usage (#12 Codable for usage-cache.json)

    private struct UsageCacheFile: Decodable {
        let fetchedAt: Double?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case fetchedAt
            case rateLimits = "rate_limits"
        }

        struct RateLimits: Decodable {
            let fiveHour: RateLimit?
            let sevenDay: RateLimit?
            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        struct RateLimit: Decodable {
            let usedPercentage: Double?
            let resetsAt: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }
    }

    private func rebuildUsageCache() {
        guard let data = try? Data(contentsOf: usageCacheURL),
              let cache = try? JSONDecoder().decode(UsageCacheFile.self, from: data),
              let rateLimits = cache.rateLimits
        else {
            // #3: Partial-write guard — keep last valid response rather than replacing with empty
            if cachedUsageResponse == nil {
                cachedUsageResponse = Data(#"{"claude":{"fetchedAt":null,"five":null,"seven":null}}"#.utf8)
            }
            return
        }

        func normalize(_ rl: UsageCacheFile.RateLimit?) -> [String: Any]? {
            guard let rl, let used = rl.usedPercentage else { return nil }
            if let resetsAt = rl.resetsAt, Date(timeIntervalSince1970: resetsAt) < Date() { return nil }
            var out: [String: Any] = ["used": used]
            if let resetsAt = rl.resetsAt { out["resetAt"] = resetsAt * 1000 }
            return out
        }

        let five  = normalize(rateLimits.fiveHour)
        let seven = normalize(rateLimits.sevenDay)
        _currentFive  = five?["used"]  as? Double
        _currentSeven = seven?["used"] as? Double

        let claude: [String: Any] = [
            "fetchedAt": cache.fetchedAt ?? NSNull(),
            "five":  five  ?? NSNull(),
            "seven": seven ?? NSNull()
        ]
        cachedUsageResponse = try? JSONSerialization.data(withJSONObject: ["claude": claude])
        appendHistory(five: _currentFive, seven: _currentSeven,
                      fiveResetAt: five?["resetAt"] as? Double)
    }

    private func makeUsageJSON() -> Data {
        if cachedUsageResponse == nil { rebuildUsageCache() }
        return cachedUsageResponse ?? Data(#"{"claude":{"fetchedAt":null,"five":null,"seven":null}}"#.utf8)
    }

    // MARK: - History

    private func appendHistory(five: Double?, seven: Double?, fiveResetAt: Double? = nil) {
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastHistoryTs >= C.minSampleIntervalMs, five != nil || seven != nil else { return }

        let gapMs = now - lastHistoryTs
        if gapMs > C.gapThresholdMs, let currentFive = five, let resetAt = fiveResetAt {
            let windowStartMs = resetAt - C.fiveHourWindowMs
            let backfillFrom  = max(lastHistoryTs, windowStartMs)
            // #10b: Find last history point that actually carries a five value
            let startFive = history.reversed().first(where: { $0["five"] != nil })?["five"] as? Double ?? 0.0
            var t = backfillFrom + C.backfillStepMs
            while t < now - C.backfillLeadMs {
                let progress = (t - backfillFrom) / (now - backfillFrom)
                history.append(["ts": t, "five": startFive + (currentFive - startFive) * progress])
                t += C.backfillStepMs
            }
        }

        lastHistoryTs = now
        var point: [String: Any] = ["ts": now]
        if let five  { point["five"]  = five  }
        if let seven { point["seven"] = seven }
        history.append(point)
        if history.count > C.maxHistoryPoints { history.removeFirst(history.count - C.maxHistoryPoints) }
        if now - lastSaveHistoryTs >= C.saveIntervalMs {
            lastSaveHistoryTs = now
            saveHistory()
        }
    }

    private func makeHistoryJSON() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["points": history]))
            ?? Data(#"{"points":[]}"#.utf8)
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let pts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let cutoff = Date().timeIntervalSince1970 * 1000 - 86_400_000
        history = pts.filter { ($0["ts"] as? Double ?? 0) > cutoff }
        lastHistoryTs = history.last?["ts"] as? Double ?? 0
    }

    func flush() { queue.sync { saveHistory() } }

    private func saveHistory() {
        guard let data = try? JSONSerialization.data(withJSONObject: history) else { return }
        try? data.write(to: historyFileURL)
    }
}
