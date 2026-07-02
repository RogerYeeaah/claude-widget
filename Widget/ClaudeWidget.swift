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

    var resetText: String? {
        guard let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let hours = Int(remaining / 3600)
        let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
        if hours >= 24 { return "resets in \(hours / 24)d \(hours % 24)h" }
        if hours > 0  { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }
}

struct UsageData {
    let claudeFive: UsageWindow?
    let claudeSeven: UsageWindow?
    let fetchedAt: Date?
    let history: [HistoryPoint]

    var isOffline: Bool { fetchedAt == nil }

    static let empty = UsageData(claudeFive: nil, claudeSeven: nil, fetchedAt: nil, history: [])
    static let placeholder = UsageData(
        claudeFive: UsageWindow(percent: 42, resetAt: Date().addingTimeInterval(9000)),
        claudeSeven: UsageWindow(percent: 18, resetAt: Date().addingTimeInterval(3600 * 72)),
        fetchedAt: Date(),
        history: stride(from: -120.0, through: 0, by: 2).map { offset in
            HistoryPoint(ts: Date().addingTimeInterval(offset * 60).timeIntervalSince1970 * 1000,
                         date: Date().addingTimeInterval(offset * 60),
                         five: max(0, 42 + Double.random(in: -8...8)),
                         seven: max(0, 18 + Double.random(in: -4...4)))
        }
    )

    static func fetch() async -> UsageData {
        guard let usageURL = URL(string: "http://127.0.0.1:8787/api/usage"),
              let historyURL = URL(string: "http://127.0.0.1:8787/api/history")
        else { return .empty }

        async let usageData = fetchRaw(usageURL)
        async let historyData = fetchRaw(historyURL)
        let (usage, hist) = await (usageData, historyData)

        let parsed = parseUsage(usage)
        return UsageData(
            claudeFive: parsed.0,
            claudeSeven: parsed.1,
            fetchedAt: parsed.2,
            history: parseHistory(hist)
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
                five: (p["five"] as? NSNumber)?.doubleValue,
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
        completion(ClaudeEntry(date: Date(), usage: .placeholder))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeEntry>) -> Void) {
        Task {
            let usage = await UsageData.fetch()
            let entry = ClaudeEntry(date: Date(), usage: usage)
            let maxPct = [usage.claudeFive?.percent, usage.claudeSeven?.percent].compactMap { $0 }.max() ?? 0
            let minutes = maxPct >= 80 ? 2 : 5
            let next = Calendar.current.date(byAdding: .minute, value: minutes, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Shared Components

private let claudeColor  = Color(red: 0.745, green: 0.455, blue: 0.341)
private let weeklyColor  = Color(red: 0.463, green: 0.498, blue: 0.776)

struct UsageColumn: View {
    let label: String
    let window: UsageWindow?
    var tintColor: Color = claudeColor

    private var pct: Double { window?.percent ?? 0 }
    private var valueColor: Color {
        if pct >= 85 { return .red }
        if pct >= 70 { return .orange }
        return tintColor
    }

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
            Text(window?.resetText ?? " ").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

private func segments(_ points: [HistoryPoint], gap: TimeInterval = 300) -> [[HistoryPoint]] {
    guard !points.isEmpty else { return [] }
    var result: [[HistoryPoint]] = [[points[0]]]
    for i in 1..<points.count {
        if points[i].date.timeIntervalSince(points[i - 1].date) > gap {
            result.append([])
        }
        result[result.count - 1].append(points[i])
    }
    return result
}

private func yDomain(_ points: [HistoryPoint]) -> ClosedRange<Double> {
    let values = points.flatMap { [$0.five, $0.seven].compactMap { $0 } }
    let dataMax = values.max() ?? 0
    let top = min(ceil(max(dataMax * 2, 10) / 5) * 5, 100)
    return 0...top
}

struct SparklineChart: View {
    let points: [HistoryPoint]
    var lastFiveReset: Date? = nil

    private var sparkDomain: ClosedRange<Double> {
        var pts = sampled
        if let reset = lastFiveReset {
            let postReset = sampled.filter { $0.date >= reset }
            if !postReset.isEmpty { pts = postReset }
        }
        return yDomain(pts)
    }

    private var sampled: [HistoryPoint] {
        guard points.count > 1,
              let first = points.first, let last = points.last else { return points }
        let duration = last.ts - first.ts
        guard duration > 0 else { return points }
        let n = min(points.count, 40)
        let bucketSize = duration / Double(n)
        return (0..<n).compactMap { b in
            let lo = first.ts + Double(b) * bucketSize
            let hi = lo + bucketSize
            let bucket = points.filter { $0.ts >= lo && $0.ts < hi }
            guard !bucket.isEmpty else { return nil }
            let midTs = (lo + hi) / 2
            let fives = bucket.compactMap { $0.five }
            let sevens = bucket.compactMap { $0.seven }
            return HistoryPoint(
                ts: midTs,
                date: Date(timeIntervalSince1970: midTs / 1000),
                five: fives.isEmpty ? nil : fives.reduce(0, +) / Double(fives.count),
                seven: sevens.isEmpty ? nil : sevens.reduce(0, +) / Double(sevens.count)
            )
        }
    }

    var body: some View {
        Chart {
            ForEach(sampled) { p in
                if let v = p.five {
                    LineMark(x: .value("t", p.date), y: .value("%", v),
                             series: .value("s", "five"))
                        .foregroundStyle(claudeColor.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.0))
                        .interpolationMethod(.monotone)
                }
            }
            if let reset = lastFiveReset {
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(claudeColor.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: sparkDomain)
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

    // 3-point moving average — smooths discrete step data into flowing curves
    private var smoothed: [HistoryPoint] {
        guard points.count > 2 else { return points }
        return points.enumerated().map { (i, p) in
            let lo = max(0, i - 1), hi = min(points.count - 1, i + 1)
            let slice = points[lo...hi]
            let fv = slice.compactMap(\.five);  let sv = slice.compactMap(\.seven)
            return HistoryPoint(ts: p.ts, date: p.date,
                                five:  fv.isEmpty ? p.five  : fv.reduce(0,+) / Double(fv.count),
                                seven: sv.isEmpty ? p.seven : sv.reduce(0,+) / Double(sv.count))
        }
    }

    var body: some View {
        Chart {
            ForEach(Array(segments(smoothed).enumerated()), id: \.offset) { _, seg in
                ForEach(seg) { p in
                    if let v = p.five {
                        LineMark(x: .value("t", p.date), y: .value("%", v),
                                 series: .value("s", "five"))
                            .foregroundStyle(claudeColor)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    if let v = p.seven {
                        LineMark(x: .value("t", p.date), y: .value("%", v),
                                 series: .value("s", "seven"))
                            .foregroundStyle(weeklyColor)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                    }
                }
            }
            if let reset = lastFiveReset {
                RuleMark(x: .value("5h Reset", reset))
                    .foregroundStyle(claudeColor.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", reset), y: .value("%", domain.upperBound))
                    .opacity(0)
                    .annotation(position: .bottom, alignment: .center) {
                        Text(reset, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: 8))
                            .foregroundStyle(claudeColor.opacity(0.7))
                    }
            }
            if let reset = lastSevenReset {
                RuleMark(x: .value("7d Reset", reset))
                    .foregroundStyle(claudeColor.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", reset), y: .value("%", domain.upperBound))
                    .opacity(0)
                    .annotation(position: .bottom, alignment: .center) {
                        Text(reset, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: 8))
                            .foregroundStyle(weeklyColor.opacity(0.7))
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
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
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

struct OfflineView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(claudeColor)
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

// MARK: - Widget Views

private func isStale(_ fetchedAt: Date?) -> Bool {
    guard let t = fetchedAt else { return false }
    return -t.timeIntervalSinceNow > 1800
}

private func ageText(_ fetchedAt: Date?) -> String {
    guard let t = fetchedAt else { return "" }
    let s = Int(-t.timeIntervalSinceNow)
    if s < 60 { return "Just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

struct SmallView: View {
    let entry: ClaudeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(claudeColor)
                Spacer()
                Text(ageText(entry.usage.fetchedAt)).font(.system(size: 11)).foregroundStyle(isStale(entry.usage.fetchedAt) ? Color.orange : Color.secondary.opacity(0.5))
            }
            .padding(.bottom, 10)
            UsageColumn(label: "5 Hours", window: entry.usage.claudeFive)
            Spacer().frame(height: 10)
            UsageColumn(label: "Weekly", window: entry.usage.claudeSeven, tintColor: weeklyColor)
        }
        .padding(14)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct MediumView: View {
    let entry: ClaudeEntry

    private var sparkPoints: [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        return entry.usage.history.filter { $0.date >= cutoff }
    }

    private var lastFiveReset: Date? {
        guard let resetAt = entry.usage.claudeFive?.resetAt else { return nil }
        let lastReset = resetAt.addingTimeInterval(-5 * 3600)
        return lastReset >= Date().addingTimeInterval(-4 * 3600) ? lastReset : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(claudeColor)
                Spacer()
                Text(ageText(entry.usage.fetchedAt)).font(.system(size: 11)).foregroundStyle(isStale(entry.usage.fetchedAt) ? Color.orange : Color.secondary.opacity(0.5))
            }
            .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 20) {
                UsageColumn(label: "5 Hours", window: entry.usage.claudeFive)
                Divider()
                UsageColumn(label: "Weekly", window: entry.usage.claudeSeven, tintColor: weeklyColor)
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
        return entry.usage.history.filter { $0.date >= cutoff }
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
            HStack(alignment: .firstTextBaseline) {
                Text("Claude").font(.system(size: 15, weight: .bold)).foregroundStyle(claudeColor)
                Spacer()
                Text(ageText(entry.usage.fetchedAt)).font(.system(size: 11)).foregroundStyle(isStale(entry.usage.fetchedAt) ? Color.orange : Color.secondary.opacity(0.5))
            }
            .padding(.bottom, 12)
            HStack(alignment: .top, spacing: 20) {
                UsageColumn(label: "5 Hours", window: entry.usage.claudeFive)
                Divider()
                UsageColumn(label: "Weekly", window: entry.usage.claudeSeven, tintColor: weeklyColor)
            }
            Spacer().frame(height: 14)
            HStack(spacing: 10) {
                Circle().fill(claudeColor).frame(width: 7, height: 7)
                Text("5 Hours").font(.system(size: 10)).foregroundStyle(.secondary)
                Circle().fill(weeklyColor).frame(width: 7, height: 7)
                Text("Weekly").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer().frame(height: 6)
            if chartPoints.count >= 3 {
                FullChart(points: chartPoints, lastFiveReset: lastFiveReset, lastSevenReset: lastSevenReset).frame(maxHeight: .infinity)
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
