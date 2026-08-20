import SwiftUI
import Charts

struct StatsSummary: Codable {
    let totalRequests: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

struct StatsAggregate: Codable, Identifiable {
    let label: String
    let vendor: String
    let protocolName: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let requests: Int

    var id: String { "\(label)-\(vendor)-\(model)-\(protocolName)" }

    enum CodingKeys: String, CodingKey {
        case label, vendor, model, inputTokens, outputTokens, totalTokens, requests
        case protocolName = "protocol"
    }
}

struct StatsEntry: Codable, Identifiable {
    let id: Int
    let timestamp: String
    let vendor: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let durationMs: Int
}

struct StatsRecentPage: Codable {
    let items: [StatsEntry]
    let total: Int
    let page: Int
    let pageSize: Int
}

enum StatsRange: String, CaseIterable, Identifiable {
    case seven, thirty, all
    var id: String { rawValue }
    var days: Int? { self == .seven ? 7 : (self == .thirty ? 30 : nil) }
    func label(_ copy: Copy) -> String {
        switch self {
        case .seven: return copy.statsRangeSeven
        case .thirty: return copy.statsRangeThirty
        case .all: return copy.statsRangeAll
        }
    }
}

struct StatsView: View {
    @EnvironmentObject private var mothx: MothxServiceManager
    @EnvironmentObject private var languageStore: LanguageStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var range: StatsRange = .seven
    @State private var summary = StatsSummary(totalRequests: 0, inputTokens: 0, outputTokens: 0, totalTokens: 0)
    @State private var allSummary = StatsSummary(totalRequests: 0, inputTokens: 0, outputTokens: 0, totalTokens: 0)
    @State private var timeseries: [StatsAggregate] = []
    @State private var providers: [StatsAggregate] = []
    @State private var models: [StatsAggregate] = []
    @State private var recent = StatsRecentPage(items: [], total: 0, page: 1, pageSize: 12)
    @State private var page = 1
    @State private var isLoading = false

    private var query: String {
        guard let days = range.days else { return "" }
        let today = Calendar.current.startOfDay(for: Date())
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return "?from=\(dateString(from))&to=\(dateString(today))"
    }

    var body: some View {
        let c = languageStore.copy
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(c.statsTitle).font(.system(size: 25, weight: .bold))
                Text(c.statsSubtitle).foregroundStyle(.secondary)
                Spacer()
                Button(c.close) { dismiss() }.buttonStyle(.bordered)
            }.padding(.horizontal, 28).padding(.vertical, 22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Picker(c.statsTimeRange, selection: $range) {
                            ForEach(StatsRange.allCases) { Text($0.label(c)).tag($0) }
                        }.labelsHidden().frame(width: 150)
                        Button { Task { await load() } } label: {
                            Label(isLoading ? c.statsLoading : c.statsRefresh, systemImage: "arrow.clockwise")
                        }.buttonStyle(.bordered).disabled(isLoading)
                        Spacer()
                    }
                    GeometryReader { proxy in
                        let cardWidth = (proxy.size.width - 42) / 4

                        HStack(spacing: 14) {
                            StatsMetricCard(title: c.statsRequests, value: formatStatsNumber(summary.totalRequests)).frame(width: cardWidth)
                            StatsMetricCard(title: c.statsTotalTokens, value: formatStatsNumber(summary.totalTokens)).frame(width: cardWidth)
                            StatsMetricCard(title: c.statsInputTokens, value: formatStatsNumber(summary.inputTokens)).frame(width: cardWidth)
                            StatsMetricCard(title: c.statsOutputTokens, value: formatStatsNumber(summary.outputTokens)).frame(width: cardWidth)
                        }
                    }.frame(height: 112)
                    GeometryReader { proxy in
                        let rankingWidth = (proxy.size.width - 28) / 3.6
                        HStack(spacing: 14) {
                            StatsTrendCard(data: timeseries, total: summary.totalTokens, copy: c).frame(width: rankingWidth * 1.6)
                            StatsRankingCard(title: c.statsProviderRanking, rows: providers, label: { $0.label }, copy: c).frame(width: rankingWidth)
                            StatsRankingCard(title: c.statsModelRanking, rows: models, label: { $0.model.isEmpty ? $0.label : $0.model }, copy: c).frame(width: rankingWidth)
                        }
                    }.frame(height: 300)
                    StatsRecentCard(page: $page, data: recent, allTotal: allSummary.totalRequests, copy: c, loadPage: { target in
                        page = target
                        Task { await loadRecent(page: target) }
                    })
                }.padding(28)
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await load() } }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        page = 1
        let q = query
        let trendPath = q.isEmpty ? "api/stats/timeseries?groupBy=day" : "api/stats/timeseries\(q)&groupBy=day"
        async let summaryData = mothx.fetchStats(path: "api/stats/summary\(q)")
        async let allSummaryData = mothx.fetchStats(path: "api/stats/summary")
        async let trendData = mothx.fetchStats(path: trendPath)
        async let providerData = mothx.fetchStats(path: "api/stats/by-provider\(q)")
        async let modelData = mothx.fetchStats(path: "api/stats/by-model\(q)")
        async let recentData = mothx.fetchStats(path: "api/stats/recent\(q)\(q.isEmpty ? "?" : "&")page=1&pageSize=12")
        let values = await (summaryData, allSummaryData, trendData, providerData, modelData, recentData)
        if let data = values.0, let value = try? JSONDecoder().decode(StatsSummary.self, from: data) { summary = value }
        if let data = values.1, let value = try? JSONDecoder().decode(StatsSummary.self, from: data) { allSummary = value }
        if let data = values.2, let value = try? JSONDecoder().decode([StatsAggregate].self, from: data) { timeseries = value }
        if let data = values.3, let value = try? JSONDecoder().decode([StatsAggregate].self, from: data) { providers = value }
        if let data = values.4, let value = try? JSONDecoder().decode([StatsAggregate].self, from: data) { models = value }
        if let data = values.5, let value = try? JSONDecoder().decode(StatsRecentPage.self, from: data) { recent = value }
        isLoading = false
    }

    func loadRecent(page: Int) async {
        let q = query
        guard let data = await mothx.fetchStats(path: "api/stats/recent\(q)\(q.isEmpty ? "?" : "&")page=\(page)&pageSize=12"),
              let value = try? JSONDecoder().decode(StatsRecentPage.self, from: data) else { return }
        recent = value
    }

    func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

struct StatsMetricCard: View {
    let title: String
    let value: String
    var body: some View {
        StatsCard { VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline).foregroundStyle(.secondary); Text(value).font(.system(size: 28, weight: .bold, design: .rounded)) } }.frame(maxWidth: .infinity).frame(minHeight: 112, alignment: .leading)
    }
}

struct StatsTrendCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let data: [StatsAggregate]
    let total: Int
    let copy: Copy
    var body: some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(copy.statsUsageTrend).font(.headline); Spacer(); Text(copy.statsTotalTokenLabel(formatStatsNumber(total))).foregroundStyle(.secondary) }
                if data.isEmpty { ContentUnavailableView(copy.statsNoData, systemImage: "chart.bar") .frame(maxWidth: .infinity, minHeight: 210) }
                else {
                    Chart(data) { item in
                        BarMark(x: .value(copy.statsDate, shortDate(item.label)), y: .value("Token", item.totalTokens)).foregroundStyle(.linearGradient(colors: colorScheme == .light ? [.black.opacity(0.9), .green] : [.green.opacity(0.55), .green], startPoint: .top, endPoint: .bottom))
                    }.chartYAxis { AxisMarks(position: .leading) }.chartLegend(.hidden).frame(height: 230)
                }
            }
        }.frame(maxWidth: .infinity).frame(height: 300)
    }
}

struct StatsRankingCard: View {
    let title: String
    let rows: [StatsAggregate]
    let label: (StatsAggregate) -> String
    let copy: Copy
    var body: some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(title).font(.headline); Spacer(); Text(copy.statsItemsCount(rows.count)).foregroundStyle(.secondary) }
                if rows.isEmpty { Text(copy.statsNoData).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 215, alignment: .center) }
                else { VStack(alignment: .leading, spacing: 15) { ForEach(Array(rows.prefix(6))) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(label(row)).lineLimit(1); Spacer(); Text(formatStatsNumber(row.totalTokens)).foregroundStyle(.secondary) }
                        GeometryReader { proxy in RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 4).fill(.green).frame(width: proxy.size.width * CGFloat(row.totalTokens) / CGFloat(max(1, rows[0].totalTokens))) } }.frame(height: 8)
                    }
                } }.frame(minHeight: 215, alignment: .top) }
            }
        }.frame(maxWidth: .infinity).frame(height: 300)
    }
}

struct StatsRecentCard: View {
    @Binding var page: Int
    let data: StatsRecentPage
    let allTotal: Int
    let copy: Copy
    let loadPage: (Int) -> Void
    var body: some View {
        StatsCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(copy.statsRecentRequests).font(.headline); Spacer(); Text(copy.statsItemsCount(allTotal)).foregroundStyle(.secondary) }.padding(.bottom, 14)
                HStack { Text(copy.statsColTime).frame(width: 145, alignment: .leading); Text(copy.statsColModel).frame(maxWidth: .infinity, alignment: .leading); Text("Provider").frame(width: 150, alignment: .leading); Text(copy.statsColInput).frame(width: 80, alignment: .trailing); Text(copy.statsColOutput).frame(width: 80, alignment: .trailing); Text(copy.statsColDuration).frame(width: 70, alignment: .trailing) }.font(.caption.bold()).foregroundStyle(.secondary).padding(.vertical, 10).background(Color.primary.opacity(0.05))
                ForEach(data.items) { item in
                    HStack { Text(formatStatsTime(item.timestamp)).frame(width: 145, alignment: .leading); Text(item.model).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading); Text(item.vendor).frame(width: 150, alignment: .leading); Text(formatStatsNumber(item.inputTokens)).frame(width: 80, alignment: .trailing); Text(formatStatsNumber(item.outputTokens)).frame(width: 80, alignment: .trailing); Text(String(format: "%.1fs", Double(item.durationMs) / 1000)).frame(width: 70, alignment: .trailing) }.padding(.vertical, 10).overlay(alignment: .bottom) { Divider().opacity(0.35) }
                }
                HStack(spacing: 5) {
                    Spacer()
                    Button { if page > 1 { loadPage(page - 1) } } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).disabled(page <= 1)
                    ForEach(visiblePages, id: \.self) { pageNumber in
                        Button { if pageNumber != page { loadPage(pageNumber) } } label: {
                            Text("\(pageNumber)").frame(width: 26, height: 24)
                        }.buttonStyle(.plain).background(pageNumber == page ? Color.accentColor.opacity(0.16) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)).foregroundStyle(pageNumber == page ? Color.accentColor : .primary)
                    }
                    Text(copy.statsPageLabel(page, totalPages)).font(.caption).foregroundStyle(.secondary).padding(.leading, 5)
                    Button { if page * data.pageSize < data.total { loadPage(page + 1) } } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).disabled(page * data.pageSize >= data.total)
                }.padding(.top, 14)
            }
        }
    }

    private var totalPages: Int { max(1, Int(ceil(Double(data.total) / Double(max(1, data.pageSize))))) }

    private var visiblePages: [Int] {
        let first = max(1, min(page - 2, totalPages - 4))
        let last = min(totalPages, first + 4)
        return Array(first...last)
    }
}

struct StatsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(18)
            // Apply the flexible size before drawing the background and border.
            // The border must belong to the complete outer card, not only to
            // the intrinsic size of its contents.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor).opacity(0.35) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(colorScheme == .dark ? Color.primary.opacity(0.16) : Color.gray.opacity(0.28)))
    }
}

func formatStatsNumber(_ value: Int) -> String {
    let number = Double(value)
    if value >= 1_000_000_000 { return String(format: "%.1fB", number / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", number / 1_000) }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

func shortDate(_ value: String) -> String { String(value.split(separator: " ").first?.suffix(5) ?? value.suffix(5)) }
func formatStatsTime(_ value: String) -> String { value.replacingOccurrences(of: "T", with: " ").prefix(16).description }
