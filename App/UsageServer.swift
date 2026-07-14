import Foundation
import WidgetKit
import UserNotifications

// Reads Claude Code's usage-cache.json, accumulates history, and publishes both usage and
// history into the shared App Group container for the widget to read directly.
// (Previously this hosted a loopback HTTP server; App Group replaces that entirely.)
final class UsageServer {
    static let shared = UsageServer()

    // MARK: - Constants (#16)
    private enum C {
        static let minSampleIntervalMs: Double = 600_000     // 10 min
        static let backfillStepMs: Double     = 600_000     // 10 min
        static let fiveHourWindowMs: Double   = 18_000_000  // 5 h
        static let gapThresholdMs: Double     = 600_000     // 10 min gap → backfill
        static let maxHistoryPoints           = 300         // ~2 days at 10-min granularity
        static let backfillLeadMs: Double     = 15_000      // stop backfill 15 s before now
        static let sevenDayWindowMs: Double   = 604_800_000 // 7 d
        static let maxBackfillMs: Double      = 28_800_000  // 8 h, aligns with the Large chart window
    }

    // All mutable state lives on `queue`
    private var history: [[String: Any]] = []
    private var lastHistoryTs: Double = 0
    private let queue = DispatchQueue(label: "usage-store", qos: .utility)
    private var cacheSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?
    private var _ready = false
    private var _currentFive: Double?
    private var _currentSeven: Double?
    // #E1: reset time of the window we last notified for, so each window alerts at most once
    private var notifiedFiveWindow: Double?
    private var notifiedSevenWindow: Double?

    private let usageCacheURL: URL  // Claude Code writes this; we read it

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        usageCacheURL = home.appendingPathComponent(".claude/usage-cache.json")
        // `history` is queue-confined state and init runs on the main thread, so load
        // it on the queue (also keeps file I/O off the main thread during app launch).
        queue.async { [weak self] in self?.loadHistory() }
    }

    // #6: Thread-safe read — safe to call from any thread (including MainActor).
    var snapshot: (ready: Bool, five: Double?, seven: Double?) {
        queue.sync { (_ready, _currentFive, _currentSeven) }
    }

    // MARK: - Start

    // Called from App.init() on the main thread; hop onto `queue` so all mutable state is
    // only ever touched there.
    func start() {
        // #E1: ask once for permission to post near-limit notifications (no-op after first grant/deny)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        queue.async { [weak self] in self?.watchCacheFile() }
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
            // #3: Partial-write guard — a bad/partial read keeps the last published usage.json
            // rather than overwriting it with empty data.
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
        _ready = true

        let claude: [String: Any] = [
            "fetchedAt": cache.fetchedAt ?? NSNull(),
            "five":  five  ?? NSNull(),
            "seven": seven ?? NSNull()
        ]
        publishUsage(["claude": claude])
        appendHistory(five: _currentFive, seven: _currentSeven,
                      fiveResetAt: five?["resetAt"] as? Double,
                      sevenResetAt: seven?["resetAt"] as? Double)
        checkThresholds(five: _currentFive, fiveResetAt: five?["resetAt"] as? Double,
                        seven: _currentSeven, sevenResetAt: seven?["resetAt"] as? Double)
        // Flush history alongside usage.json so the widget's chart stays in sync with the
        // live number (cache updates are ~10 min apart, so writing every time is cheap).
        saveHistory()
    }

    // Write the current usage into the shared container (atomic) for the widget to read.
    private func publishUsage(_ obj: [String: Any]) {
        guard let url = SharedStore.usageURL,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Threshold notifications (#E1)

    private func checkThresholds(five: Double?, fiveResetAt: Double?,
                                 seven: Double?, sevenResetAt: Double?) {
        notify(used: five, resetAt: fiveResetAt, threshold: 85,
               label: "5 小時", lastWindow: &notifiedFiveWindow)
        notify(used: seven, resetAt: sevenResetAt, threshold: 90,
               label: "每週", lastWindow: &notifiedSevenWindow)
    }

    // Fire at most once per window: resetAt identifies the window, so a new window (new resetAt)
    // re-arms automatically and no persistent state is needed.
    private func notify(used: Double?, resetAt: Double?, threshold: Double,
                        label: String, lastWindow: inout Double?) {
        guard let u = used, u >= threshold, let reset = resetAt, lastWindow != reset else { return }
        lastWindow = reset
        let content = UNMutableNotificationContent()
        content.title = "Claude \(label)額度已達 \(Int(u.rounded()))%"
        let resetTime = Date(timeIntervalSince1970: reset / 1000)
            .formatted(date: .omitted, time: .shortened)
        content.body = "額度將於 \(resetTime) 重置"
        let req = UNNotificationRequest(identifier: "\(label)-\(reset)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - History

    private func appendHistory(five: Double?, seven: Double?,
                               fiveResetAt: Double? = nil, sevenResetAt: Double? = nil) {
        let now = Date().timeIntervalSince1970 * 1000
        guard now - lastHistoryTs >= C.minSampleIntervalMs, five != nil || seven != nil else { return }

        let gapMs = now - lastHistoryTs
        if gapMs > C.gapThresholdMs {
            // Backfill the whole gap, capped at the 8h the Large chart shows (also handles
            // the cold-start case where lastHistoryTs == 0).
            let backfillFrom = max(lastHistoryTs, now - C.maxBackfillMs)

            // five interpolation is only valid inside the current 5h window
            let fiveFrom: Double? = {
                guard five != nil, let resetAt = fiveResetAt else { return nil }
                return max(backfillFrom, resetAt - C.fiveHourWindowMs)
            }()
            // #10b: Find the last history point that actually carries each value
            let lastFivePt  = history.reversed().first(where: { $0["five"]  != nil })
            let lastSevenPt = history.reversed().first(where: { $0["seven"] != nil })
            // If the last five sample belongs to a *previous* 5h window (its ts is before the
            // current window start), the new window must ramp from 0 — not from the old value.
            let startFive: Double = {
                guard let p = lastFivePt, let v = p["five"] as? Double else { return 0 }
                if let from = fiveFrom, (p["ts"] as? Double ?? 0) < from { return 0 }
                return v
            }()
            let startSeven  = lastSevenPt?["seven"] as? Double
            let lastSevenTs = lastSevenPt?["ts"]    as? Double ?? 0
            // sevenResetAt is the *next* weekly reset; the last one is 7 days earlier
            let lastSevenResetMs = sevenResetAt.map { $0 - C.sevenDayWindowMs }

            var t = backfillFrom + C.backfillStepMs
            while t < now - C.backfillLeadMs {
                var point: [String: Any] = ["ts": t]

                if let from = fiveFrom, let currentFive = five, t > from {
                    let progress = (t - from) / (now - from)
                    point["five"] = startFive + (currentFive - startFive) * progress
                }

                if let currentSeven = seven {
                    // If a weekly reset happened since the last known sample, anchor the ramp at
                    // the reset (0 → current) and hold the old value only before it. This also
                    // covers a reset that fell outside the 8h backfill cap.
                    if let resetMs = lastSevenResetMs, resetMs < now, lastSevenTs < resetMs {
                        if t >= resetMs {
                            point["seven"] = currentSeven * ((t - resetMs) / (now - resetMs))
                        } else if let s = startSeven {
                            point["seven"] = s
                        }
                    } else {
                        // normal case: interpolate old → current; with no old value, hold current
                        let s = startSeven ?? currentSeven
                        point["seven"] = s + (currentSeven - s) * ((t - backfillFrom) / (now - backfillFrom))
                    }
                }

                if point.count > 1 { history.append(point) }  // skip empty points
                t += C.backfillStepMs
            }
        }

        lastHistoryTs = now
        var point: [String: Any] = ["ts": now]
        if let five  { point["five"]  = five  }
        if let seven { point["seven"] = seven }
        history.append(point)
        if history.count > C.maxHistoryPoints { history.removeFirst(history.count - C.maxHistoryPoints) }
        // (saveHistory is called by rebuildUsageCache after each update — see there)
    }

    private func loadHistory() {
        guard let url = SharedStore.historyURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pts = json["points"] as? [[String: Any]] else { return }
        let cutoff = Date().timeIntervalSince1970 * 1000 - 86_400_000
        history = pts.filter { ($0["ts"] as? Double ?? 0) > cutoff }
        lastHistoryTs = history.last?["ts"] as? Double ?? 0
    }

    func flush() { queue.sync { saveHistory() } }

    private func saveHistory() {
        guard let url = SharedStore.historyURL,
              let data = try? JSONSerialization.data(withJSONObject: ["points": history]) else { return }
        // .atomic: write to a temp file then rename, so a crash mid-write can't leave a
        // truncated JSON that loadHistory would fail to decode (losing all history).
        try? data.write(to: url, options: .atomic)
    }
}
