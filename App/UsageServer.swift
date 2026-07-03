import Foundation
import Network
import WidgetKit

final class UsageServer {
    static let shared = UsageServer()

    private var listener: NWListener?
    private var history: [[String: Any]] = []
    private var lastHistoryTs: Double = 0
    private let queue = DispatchQueue(label: "usage-server", qos: .utility)
    private var cacheSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    private let usageCacheURL: URL
    private let historyFileURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        usageCacheURL = home.appendingPathComponent(".claude/usage-cache.json")
        historyFileURL = home.appendingPathComponent(".claude/widget-history.json")
        loadHistory()
    }

    private(set) var isRunning = false

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: 8787),
              let listener = try? NWListener(using: params, on: port) else { return }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
            case .failed:
                // port 已被另一個實例佔用，靜默跳過
                self?.isRunning = false
                self?.listener?.cancel()
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
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self else { return }
            self.scheduleWidgetReload()
            if let events = src?.data, !events.intersection([.rename, .delete]).isEmpty {
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.watchCacheFile() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        cacheSource = src
    }

    private func scheduleWidgetReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem {
            WidgetCenter.shared.reloadAllTimelines()
        }
        pendingReload = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

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

    // MARK: - Usage

    private func makeUsageJSON() -> Data {
        var claude: [String: Any] = ["fetchedAt": NSNull(), "five": NSNull(), "seven": NSNull()]

        if let data = try? Data(contentsOf: usageCacheURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rateLimits = json["rate_limits"] as? [String: Any] {
            claude["fetchedAt"] = json["fetchedAt"] ?? NSNull()
            claude["five"] = normalizeWindow(rateLimits["five_hour"] as? [String: Any])
            claude["seven"] = normalizeWindow(rateLimits["seven_day"] as? [String: Any])

            let fiveResetAt = (claude["five"] as? [String: Any])?["resetAt"] as? Double
            appendHistory(
                five: (claude["five"] as? [String: Any])?["used"] as? Double,
                seven: (claude["seven"] as? [String: Any])?["used"] as? Double,
                fiveResetAt: fiveResetAt
            )
        }

        let result: [String: Any] = ["claude": claude]
        return (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
    }

    private func normalizeWindow(_ win: [String: Any]?) -> Any {
        guard let win, let used = (win["used_percentage"] as? NSNumber)?.doubleValue else { return NSNull() }
        if let resetsAt = (win["resets_at"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: resetsAt) < Date() {
            return NSNull()
        }
        var out: [String: Any] = ["used": used]
        if let resetsAt = (win["resets_at"] as? NSNumber)?.doubleValue { out["resetAt"] = resetsAt * 1000 }
        return out
    }

    // MARK: - History

    private func appendHistory(five: Double?, seven: Double?, fiveResetAt: Double? = nil) {
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastHistoryTs >= 30_000, five != nil || seven != nil else { return }

        // 若 gap > 30 分鐘，用線性插值補假資料點讓 sparkline 平滑
        let gapMs = now - lastHistoryTs
        if gapMs > 1_800_000, let currentFive = five, let resetAt = fiveResetAt {
            let windowStartMs = resetAt - 18_000_000 // 5h window
            let backfillFrom = lastHistoryTs > windowStartMs ? lastHistoryTs : windowStartMs
            let startFive = lastHistoryTs > windowStartMs
                ? (history.last?["five"] as? Double ?? 0.0)
                : 0.0
            var t = backfillFrom + 1_800_000
            while t < now - 15_000 {
                let progress = (t - backfillFrom) / (now - backfillFrom)
                history.append(["ts": t, "five": startFive + (currentFive - startFive) * progress])
                t += 1_800_000
            }
        }

        lastHistoryTs = now
        var point: [String: Any] = ["ts": now]
        if let five { point["five"] = five }
        if let seven { point["seven"] = seven }
        history.append(point)
        if history.count > 1440 { history.removeFirst() }
        saveHistory()
    }

    private func makeHistoryJSON() -> Data {
        let result: [String: Any] = ["points": history]
        return (try? JSONSerialization.data(withJSONObject: result)) ?? Data(#"{"points":[]}"#.utf8)
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let pts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let cutoff = Date().timeIntervalSince1970 * 1000 - 86_400_000
        history = pts.filter { ($0["ts"] as? Double ?? 0) > cutoff }
        lastHistoryTs = history.last?["ts"] as? Double ?? 0
    }

    private func saveHistory() {
        guard let data = try? JSONSerialization.data(withJSONObject: history) else { return }
        try? data.write(to: historyFileURL)
    }
}
