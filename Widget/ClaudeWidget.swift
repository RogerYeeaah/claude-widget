import Charts
import WidgetKit
import SwiftUI

// MARK: - Models

struct HistoryPoint: Identifiable {
    var id: Double { ts }
    let ts: Double
    let date: Date
    let five: Double?
    let seven: Double?
}

struct UsageWindow {
    let percent: Double
    let resetAt: Date?
}

struct UsageData {
    let claudeFive: UsageWindow?
    let claudeSeven: UsageWindow?
    let fetchedAt: Date?
    let history: [HistoryPoint]
    let serverReachable: Bool  // #22: distinguish "offline" from "waiting for data"

    var isOffline: Bool  { !serverReachable }
    var hasData:   Bool  { serverReachable && fetchedAt != nil }

    static let empty = UsageData(claudeFive: nil, claudeSeven: nil,
                                 fetchedAt: nil, history: [], serverReachable: false)
    static let placeholder = UsageData(
        claudeFive: UsageWindow(percent: 42, resetAt: Date().addingTimeInterval(9000)),
        claudeSeven: UsageWindow(percent: 18, resetAt: Date().addingTimeInterval(3600 * 72)),
        fetchedAt: Date(),
        history: stride(from: -120.0, through: 0, by: 2).map { offset in
            HistoryPoint(ts: Date().addingTimeInterval(offset * 60).timeIntervalSince1970 * 1000,
                         date: Date().addingTimeInterval(offset * 60),
                         five: max(0, 42 + Double.random(in: -8...8)),
                         seven: max(0, 18 + Double.random(in: -4...4)))
        },
        serverReachable: true
    )

    static func fetch() async -> UsageData {
        guard let usageURL   = URL(string: "http://127.0.0.1:8787/api/usage"),
              let historyURL = URL(string: "http://127.0.0.1:8787/api/history")
        else { return .empty }

        async let usageData   = fetchRaw(usageURL)
        async let historyData = fetchRaw(historyURL)
        let (usage, hist) = await (usageData, historyData)

        let serverReachable = usage != nil  // HTTP success → server is up
        let parsed = parseUsage(usage)
        return UsageData(
            claudeFive:      parsed.0,
            claudeSeven:     parsed.1,
            fetchedAt:       parsed.2,
            history:         parseHistory(hist),
            serverReachable: serverReachable
        )
    }

    private static func fetchRaw(_ url: URL) async -> Data? {
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
            return data
        } catch { return nil }
    }

    private static func parseUsage(_ data: Data?) -> (UsageWindow?, UsageWindow?, Date?) {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claude = json["claude"] as? [String: Any]
        else { return (nil, nil, nil) }

        func num(_ dict: [String: Any], _ key: String) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }
        func window(_ key: String) -> UsageWindow? {
            guard let w = claude[key] as? [String: Any], let pct = num(w, "used") else { return nil }
            let reset = num(w, "resetAt").map { Date(timeIntervalSince1970: $0 / 1000) }
            return UsageWindow(percent: pct, resetAt: reset)
        }
        let fetchedAt = num(claude, "fetchedAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        return (window("five"), window("seven"), fetchedAt)
    }

    private static func parseHistory(_ data: Data?) -> [HistoryPoint] {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let points = json["points"] as? [[String: Any]]
        else { return [] }
        return points.compactMap { p in
            guard let ts = (p["ts"] as? NSNumber)?.doubleValue else { return nil }
            return HistoryPoint(
                ts: ts,
                date: Date(timeIntervalSince1970: ts / 1000),
                five:  (p["five"]  as? NSNumber)?.doubleValue,
                seven: (p["seven"] as? NSNumber)?.doubleValue
            )
        }
    }
}

// MARK: - Timeline

struct ClaudeEntry: TimelineEntry {
    let date: Date
    let usage: UsageData
}

struct ClaudeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeEntry {
        ClaudeEntry(date: Date(), usage: .placeholder)
    }
    func getSnapshot(in context: Context, completion: @escaping (ClaudeEntry) -> Void) {
        if context.isPreview {
            completion(ClaudeEntry(date: Date(), usage: .placeholder))
            return
        }
        Task {
            let usage = await UsageData.fetch()
            completion(ClaudeEntry(date: Date(), usage: usage.isOffline ? .placeholder : usage))
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeEntry>) -> Void) {
        Task {
            let usage = await UsageData.fetch()
            let entry = ClaudeEntry(date: Date(), usage: usage)
            let maxPct = [usage.claudeFive?.percent, usage.claudeSeven?.percent]
                .compactMap { $0 }.max() ?? 0
            // #19: Offline → 2 min so we pick up as soon as server recovers
            let minutes = usage.isOffline ? 2 : maxPct >= 90 ? 2 : maxPct >= 70 ? 5 : 10
            let next = Calendar.current.date(byAdding: .minute, value: minutes, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Shared Components

private func segments(_ points: [HistoryPoint], gap: TimeInterval = 300) -> [[HistoryPoint]] {
    guard !points.isEmpty else { return [] }
    var result: [[HistoryPoint]] = [[points[0]]]
    for i in 1..<points.count {
        if points[i].date.timeIntervalSince(points[i - 1].date) > gap { result.append([]) }
        result[result.count - 1].append(points[i])
    }
    return result
}

private func yDomain(_ points: [HistoryPoint]) -> ClosedRange<Double> {
    let values = points.flatMap { [$0.five, $0.seven].compactMap { $0 } }
    let dataMax = values.max() ?? 0
    // #20: 1.25× headroom instead of 2× — reduces empty whitespace
    let top = min(ceil(max(dataMax * 1.25, 10) / 5) * 5, 100)
    return 0...top
}

private func isStale(_ fetchedAt: Date?) -> Bool {
    guard let t = fetchedAt else { return false }
    return -t.timeIntervalSinceNow > 1800
}

struct UsageColumn: View {
    let label: String
    let window: UsageWindow?
    var tintColor: Color = Theme.claude

    private var pct: Double { window?.percent ?? 0 }
    private var valueColor: Color { Theme.usageColor(pct, fallback: tintColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Group {
                    if let w = window {
                        Text("\(Int(w.percent.rounded()))%").foregroundStyle(valueColor)
                    } else {
                        Text("--").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 5)
                    Capsule().fill(window != nil ? valueColor : Color.clear)
                        .frame(width: geo.size.width * CGFloat(min(pct, 100) / 100), height: 5)
                }
            }
            .frame(height: 5)
            // #18: Live reset countdown using .relative style — updates without new timeline entry
            Group {
                if let date = window?.resetAt, date > .now {
                    HStack(spacing: 2) {
                        Text("resets").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(" ").font(.system(size: 10))
                }
            }
        }
    }
}

struct SparklineChart: View {
    let points: [HistoryPoint]
    var lastFiveReset: Date? = nil

    // #11: O(n) single-pass bucket assignment — was O(n × 40)
    private var sampled: [HistoryPoint] {
        guard points.count > 1,
              let first = points.first, let last = points.last else { return points }
        let duration = last.ts - first.ts
        guard duration > 0 else { return points }
        let n = min(points.count, 40)
        let bucketSize = duration / Double(n)
        var fiveBuckets  = [[Double]](repeating: [], count: n)
        var sevenBuckets = [[Double]](repeating: [], count: n)
        for p in points {
            let b = min(Int((p.ts - first.ts) / bucketSize), n - 1)
            if let v = p.five  { fiveBuckets[b].append(v) }
            if let v = p.seven { sevenBuckets[b].append(v) }
        }
        return (0..<n).compactMap { b in
            let fives  = fiveBuckets[b]
            let sevens = sevenBuckets[b]
            guard !fives.isEmpty || !sevens.isEmpty else { return nil }
            let midTs = first.ts + (Double(b) + 0.5) * bucketSize
            return HistoryPoint(
                ts:    midTs,
                date:  Date(timeIntervalSince1970: midTs / 1000),
                five:  fives.isEmpty  ? nil : fives.reduce(0,  +) / Double(fives.count),
                seven: sevens.isEmpty ? nil : sevens.reduce(0, +) / Double(sevens.count)
            )
        }
    }

    private func sparkDomain(for pts: [HistoryPoint]) -> ClosedRange<Double> {
        var filtered = pts
        if let reset = lastFiveReset {
            let postReset = pts.filter { $0.date >= reset }
            if !postReset.isEmpty { filtered = postReset }
        }
        return yDomain(filtered)
    }

    var body: some View {
        let pts = sampled  // #11: compute once — was computed 3× before
        Chart {
            ForEach(pts) { p in
                if let v = p.five {
                    LineMark(x: .value("t", p.date), y: .value("%", v),
                             series: .value("s", "five"))
                        .foregroundStyle(Theme.claude.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.0))
                        .interpolationMethod(.monotone)
                }
            }
            if let reset = lastFiveReset {
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(Theme.claude.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: sparkDomain(for: pts))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

struct FullChart: View {
    let points: [HistoryPoint]
    var lastFiveReset: Date? = nil
    var lastSevenReset: Date? = nil

    private var domain: ClosedRange<Double> { yDomain(points) }
    private var topLabel: Int { Int(domain.upperBound.rounded()) }

    private var smoothed: [HistoryPoint] {
        guard points.count > 2 else { return points }
        let w = 6
        var result = points.enumerated().map { (i, p) -> HistoryPoint in
            let lo = max(0, i - w), hi = min(points.count - 1, i + w)
            var fSum = 0.0, sSum = 0.0, wSumF = 0.0, wSumS = 0.0
            for j in lo...hi {
                let weight = exp(-Double((j - i) * (j - i)) / Double(w))
                if let v = points[j].five  { fSum += weight * v; wSumF += weight }
                if let v = points[j].seven { sSum += weight * v; wSumS += weight }
            }
            return HistoryPoint(ts: p.ts, date: p.date,
                                five:  p.five  == nil ? nil : (wSumF > 0 ? fSum / wSumF : p.five),
                                seven: p.seven == nil ? nil : (wSumS > 0 ? sSum / wSumS : p.seven))
        }
        if let last = points.last { result[result.count - 1] = last }
        return result
    }

    var body: some View {
        let pts = smoothed
        Chart {
            // Single loop keeps Chart domain intact; five series uses different keys
            // pre/post reset so the two segments aren't visually connected
            ForEach(Array(segments(pts, gap: 2100).enumerated()), id: \.offset) { idx, seg in
                ForEach(seg) { p in
                    if let v = p.five {
                        let side = lastFiveReset.map { p.date >= $0 ? "b" : "a" } ?? "a"
                        LineMark(x: .value("t", p.date), y: .value("%", v),
                                 series: .value("s", "five-\(idx)\(side)"))
                            .foregroundStyle(Theme.claude)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    if let v = p.seven {
                        LineMark(x: .value("t", p.date), y: .value("%", v),
                                 series: .value("s", "seven-\(idx)"))
                            .foregroundStyle(Theme.weekly)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                    }
                }
            }
            if let reset = lastFiveReset {
                RuleMark(x: .value("5h Reset", reset))
                    .foregroundStyle(Theme.claude.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", reset), y: .value("%", domain.upperBound))
                    .opacity(0)
                    .annotation(position: .bottom, alignment: .center) {
                        Text(reset, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.claude.opacity(0.7))
                    }
            }
            if let reset = lastSevenReset {
                // #10a: 7d reset uses weeklyColor, not claudeColor
                RuleMark(x: .value("7d Reset", reset))
                    .foregroundStyle(Theme.weekly.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", reset), y: .value("%", domain.upperBound))
                    .opacity(0)
                    .annotation(position: .bottom, alignment: .center) {
                        Text(reset, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.weekly.opacity(0.7))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(values: [0, topLabel / 2, topLabel]) { v in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.system(size: 9)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.hour())
                            .font(.system(size: 9))
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}

// #22: "Server offline" — HTTP connection failed
struct OfflineView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.claude)
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("Server offline").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Spacer()
        }
        .padding(14)
        .containerBackground(for: .widget) { Color.clear }
    }
}

// #22: "Waiting for data" — server is reachable but hasn't received usage data yet
struct WaitingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.claude)
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("Waiting for data").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Spacer()
        }
        .padding(14)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct WidgetHeader: View {
    let fetchedAt: Date?
    var bottomPadding: CGFloat = 10
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.claude)
            Spacer()
            // #18: Text(.relative) updates live in the widget without new timeline entries
            if let t = fetchedAt {
                Text(t, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(isStale(t) ? Color.orange : Color.secondary.opacity(0.5))
            }
        }
        .padding(.bottom, bottomPadding)
    }
}

// MARK: - Widget Views

struct SmallView: View {
    let entry: ClaudeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(fetchedAt: entry.usage.fetchedAt)
            UsageColumn(label: "5 Hours", window: entry.usage.claudeFive)
            Spacer().frame(height: 10)
            UsageColumn(label: "Weekly", window: entry.usage.claudeSeven, tintColor: Theme.weekly)
        }
        .padding(14)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct MediumView: View {
    let entry: ClaudeEntry

    private var sparkPoints: [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        let recent = entry.usage.history.filter { $0.date >= cutoff }
        let span = (recent.last?.ts ?? 0) - (recent.first?.ts ?? 0)
        // Fallback to full history when recent data spans less than 30 min
        guard recent.count >= 3, span > 1_800_000 else {
            return Array(entry.usage.history.suffix(20))
        }
        return recent
    }

    private var lastFiveReset: Date? {
        guard let resetAt = entry.usage.claudeFive?.resetAt else { return nil }
        let lastReset = resetAt.addingTimeInterval(-5 * 3600)
        return lastReset >= Date().addingTimeInterval(-4 * 3600) ? lastReset : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(fetchedAt: entry.usage.fetchedAt)
            HStack(alignment: .top, spacing: 20) {
                UsageColumn(label: "5 Hours", window: entry.usage.claudeFive)
                Divider()
                UsageColumn(label: "Weekly", window: entry.usage.claudeSeven, tintColor: Theme.weekly)
            }
            if sparkPoints.count >= 3 {
                Spacer().frame(height: 8)
                SparklineChart(points: sparkPoints, lastFiveReset: lastFiveReset).frame(height: 22)
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct LargeView: View {
    let entry: ClaudeEntry

    private var chartPoints: [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        let recent = entry.usage.history.filter { $0.date >= cutoff }
        let span = (recent.last?.ts ?? 0) - (recent.first?.ts ?? 0)
        // Fallback to full history when recent data spans less than 1 hour
        guard recent.count >= 3, span > 3_600_000 else {
            return Array(entry.usage.history.suffix(40))
        }
        return recent
    }

    private var lastFiveReset: Date? {
        guard let resetAt = entry.usage.claudeFive?.resetAt else { return nil }
        let lastReset = resetAt.addingTimeInterval(-5 * 3600)
        return lastReset >= Date().addingTimeInterval(-12 * 3600) ? lastReset : nil
    }

    private var lastSevenReset: Date? {
        guard let resetAt = entry.usage.claudeSeven?.resetAt else { return nil }
        let lastReset = resetAt.addingTimeInterval(-7 * 24 * 3600)
        return lastReset >= Date().addingTimeInterval(-12 * 3600) ? lastReset : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(fetchedAt: entry.usage.fetchedAt, bottomPadding: 12)
            HStack(alignment: .top, spacing: 20) {
                UsageColumn(label: "5 Hours", window: entry.usage.claudeFive)
                Divider()
                UsageColumn(label: "Weekly", window: entry.usage.claudeSeven, tintColor: Theme.weekly)
            }
            Spacer().frame(height: 14)
            HStack(spacing: 10) {
                Circle().fill(Theme.claude).frame(width: 7, height: 7)
                Text("5 Hours").font(.system(size: 10)).foregroundStyle(.secondary)
                Circle().fill(Theme.weekly).frame(width: 7, height: 7)
                Text("Weekly").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer().frame(height: 6)
            if chartPoints.count >= 3 {
                FullChart(points: chartPoints, lastFiveReset: lastFiveReset, lastSevenReset: lastSevenReset)
                    .frame(maxHeight: .infinity)
            } else {
                HStack {
                    Spacer()
                    Text("Collecting history…").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct ClaudeWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ClaudeEntry
    var body: some View {
        if entry.usage.isOffline {
            OfflineView()
        } else if !entry.usage.hasData {
            // #22: Server reachable but no usage data yet (Claude Code hasn't written cache)
            WaitingView()
        } else {
            switch family {
                case .systemMedium: MediumView(entry: entry)
                case .systemLarge:  LargeView(entry: entry)
                default:            SmallView(entry: entry)
            }
        }
    }
}

// MARK: - Widget

struct ClaudeWidget: Widget {
    let kind = "ClaudeUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeProvider()) { entry in
            ClaudeWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code 用量")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
