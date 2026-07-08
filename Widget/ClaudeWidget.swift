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
            // #19: This .after() policy is only a fallback — the app pushes reloads via
            // reloadAllTimelines() when usage-cache.json changes. Keep it well within the
            // WidgetKit daily reload budget (~40-70/day) so the system doesn't throttle us;
            // offline is a bit tighter to recover quickly once the server is back.
            let minutes = usage.isOffline ? 5 : 15
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
    private var isWarning: Bool { window != nil && pct >= 85 }

    private var a11yLabel: String {
        guard window != nil else { return "\(label) 無資料" }
        return "\(label) 用量 \(Int(pct.rounded()))%" + (isWarning ? "，接近上限" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    // Non-color cue so color-blind users still see the near-limit warning
                    if isWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(valueColor)
                    }
                    if let w = window {
                        Text("\(Int(w.percent.rounded()))%").foregroundStyle(valueColor)
                    } else {
                        Text("--").foregroundStyle(.secondary)
                    }
                }
                .font(.system(.title2, design: .rounded).weight(.bold))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 5)
                    Capsule().fill(window != nil ? valueColor : Color.clear)
                        .frame(width: geo.size.width * CGFloat(min(pct, 100) / 100), height: 5)
                }
            }
            .frame(height: 5)
            // #18: Live reset countdown — timerInterval stops at 0 rather than counting up past reset
            Group {
                if let date = window?.resetAt, date > .now {
                    HStack(spacing: 2) {
                        Text("重置").font(.caption2).foregroundStyle(.tertiary)
                        Text(timerInterval: .now...date, countsDown: true)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(" ").font(.caption2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
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
                        .interpolationMethod(.linear)
                }
            }
            if let reset = lastFiveReset {
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(Theme.claude.opacity(0.30))  // #U8: was 0.18, too faint on light backgrounds
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: sparkDomain(for: pts))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)  // #U2: trend chart is decorative; numbers are read by UsageColumn
    }
}

struct FullChart: View {
    let points: [HistoryPoint]
    var fiveResets: [Date] = []
    var lastSevenReset: Date? = nil

    private var domain: ClosedRange<Double> { yDomain(points) }
    private var topLabel: Int { Int(domain.upperBound.rounded()) }

    // Catmull-Rom spline value at t ∈ (0,1) given four control points
    private func crSpline(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * ((2*p1) + (-p0+p2)*t + (2*p0-5*p1+4*p2-p3)*t2 + (-p0+3*p1-3*p2+p3)*t3)
    }

    // Insert (steps-1) interpolated points between each consecutive pair
    private func crInterp(_ pts: [HistoryPoint], steps: Int = 4) -> [HistoryPoint] {
        guard pts.count >= 2 else { return pts }
        var out: [HistoryPoint] = []
        for i in 0..<(pts.count - 1) {
            out.append(pts[i])
            let p0 = pts[max(0, i - 1)], p1 = pts[i]
            let p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
            for s in 1..<steps {
                let t  = Double(s) / Double(steps)
                let ts = p1.ts + (p2.ts - p1.ts) * t
                // Clamp to [min(p1,p2), max(p1,p2)] to prevent Catmull-Rom overshoot dips
                let five: Double?  = (p1.five  != nil && p2.five  != nil) ? {
                    let lo = min(p1.five!, p2.five!), hi = max(p1.five!, p2.five!)
                    return max(lo, min(hi, crSpline(p0.five  ?? p1.five!, p1.five!, p2.five!, p3.five  ?? p2.five!,  t: t)))
                }() : nil
                let seven: Double? = (p1.seven != nil && p2.seven != nil) ? {
                    let lo = min(p1.seven!, p2.seven!), hi = max(p1.seven!, p2.seven!)
                    return max(lo, min(hi, crSpline(p0.seven ?? p1.seven!, p1.seven!, p2.seven!, p3.seven ?? p2.seven!, t: t)))
                }() : nil
                out.append(HistoryPoint(ts: ts, date: Date(timeIntervalSince1970: ts / 1000),
                                        five: five, seven: seven))
            }
        }
        if let last = pts.last { out.append(last) }
        return out
    }

    // Which 5h window does this date fall in (used as series key to avoid cross-reset connections)
    private func fiveWindowIdx(_ date: Date) -> Int {
        fiveResets.filter { date >= $0 }.count
    }

    // Split segment at every five-reset boundary before interpolating
    private func interpSeg(_ seg: [HistoryPoint]) -> [HistoryPoint] {
        guard !fiveResets.isEmpty else { return crInterp(seg) }
        let boundaries = ([Date.distantPast] + fiveResets.sorted() + [Date.distantFuture])
        var result: [HistoryPoint] = []
        for i in 0..<(boundaries.count - 1) {
            let lo = boundaries[i], hi = boundaries[i + 1]
            result += crInterp(seg.filter { $0.date >= lo && $0.date < hi })
        }
        return result
    }

    var body: some View {
        Chart {
            // Single loop keeps Chart domain intact; five series uses different keys
            // pre/post reset so the two segments aren't visually connected
            ForEach(Array(segments(points, gap: 2100).enumerated()), id: \.offset) { idx, seg in
                ForEach(interpSeg(seg)) { p in
                    if let v = p.five {
                        LineMark(x: .value("t", p.date), y: .value("%", v),
                                 series: .value("s", "five-\(idx)-\(fiveWindowIdx(p.date))"))
                            .foregroundStyle(Theme.claude)
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    if let v = p.seven {
                        LineMark(x: .value("t", p.date), y: .value("%", v),
                                 series: .value("s", "seven-\(idx)"))
                            .foregroundStyle(Theme.weekly)
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                    }
                }
            }
            ForEach(Array(fiveResets.enumerated()), id: \.offset) { _, reset in
                RuleMark(x: .value("5h Reset", reset))
                    .foregroundStyle(Theme.claude.opacity(0.30))  // #U8: was 0.22
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
                    .foregroundStyle(Theme.weekly.opacity(0.30))  // #U8: was 0.22
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
        .accessibilityHidden(true)  // #U2: trend chart is decorative; numbers are read by UsageColumn
    }
}

// #22: "Server offline" — HTTP connection failed
struct OfflineView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude").font(.headline).foregroundStyle(Theme.claude)
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("伺服器離線").font(.caption).foregroundStyle(.secondary)
                    // #U3: tell the user how to recover (widgetURL below launches the app)
                    Text("點擊開啟 ClaudeWidget").font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
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
            Text("Claude").font(.headline).foregroundStyle(Theme.claude)
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("等待資料").font(.caption).foregroundStyle(.secondary)
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
            Text("Claude").font(.headline).foregroundStyle(Theme.claude)
            Spacer()
            // #18: Text(.relative) updates live in the widget without new timeline entries
            if let t = fetchedAt {
                Text(t, style: .relative)
                    .font(.caption2)
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
            UsageColumn(label: "5 小時", window: entry.usage.claudeFive)
            Spacer().frame(height: 10)
            UsageColumn(label: "每週", window: entry.usage.claudeSeven, tintColor: Theme.weekly)
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
            return Array(entry.usage.history.suffix(24))
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
                UsageColumn(label: "5 小時", window: entry.usage.claudeFive)
                Divider()
                UsageColumn(label: "每週", window: entry.usage.claudeSeven, tintColor: Theme.weekly)
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
        let cutoff = Date().addingTimeInterval(-8 * 3600)
        return entry.usage.history.filter { $0.date >= cutoff }
    }

    private var visibleFiveResets: [Date] {
        guard let resetAt = entry.usage.claudeFive?.resetAt else { return [] }
        let windowStart = Date().addingTimeInterval(-8 * 3600)
        var resets: [Date] = []
        var t = resetAt.addingTimeInterval(-5 * 3600) // most recent past reset
        while t >= windowStart {
            resets.append(t)
            t = t.addingTimeInterval(-5 * 3600)
        }
        return resets.sorted()
    }

    private var lastSevenReset: Date? {
        guard let resetAt = entry.usage.claudeSeven?.resetAt else { return nil }
        let lastReset = resetAt.addingTimeInterval(-7 * 24 * 3600)
        return lastReset >= Date().addingTimeInterval(-8 * 3600) ? lastReset : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(fetchedAt: entry.usage.fetchedAt, bottomPadding: 12)
            HStack(alignment: .top, spacing: 20) {
                UsageColumn(label: "5 小時", window: entry.usage.claudeFive)
                Divider()
                UsageColumn(label: "每週", window: entry.usage.claudeSeven, tintColor: Theme.weekly)
            }
            Spacer().frame(height: 14)
            HStack(spacing: 10) {
                // #U5: legend swatches mirror the chart's line styles (solid 5h vs dashed weekly)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.claude).frame(width: 14, height: 2)
                    Text("5 小時").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.weekly).frame(width: 5, height: 2)
                        RoundedRectangle(cornerRadius: 1).fill(Theme.weekly).frame(width: 5, height: 2)
                    }
                    Text("每週").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            Spacer().frame(height: 6)
            if chartPoints.count >= 3 {
                FullChart(points: chartPoints, fiveResets: visibleFiveResets, lastSevenReset: lastSevenReset)
                    .frame(maxHeight: .infinity)
            } else {
                HStack {
                    Spacer()
                    Text("收集紀錄中…").font(.caption).foregroundStyle(.tertiary)
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
        content
            // #U3: tapping the widget opens the app (handled via onOpenURL in AppMain)
            .widgetURL(URL(string: "claudewidget://open"))
    }

    @ViewBuilder private var content: some View {
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
        .configurationDisplayName("Claude 用量")
        .description("Claude Code 用量")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
