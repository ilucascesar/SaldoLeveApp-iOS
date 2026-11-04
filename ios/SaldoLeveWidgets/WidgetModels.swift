import Foundation

struct SaldoWidgetEnvelope: Decodable { let ok: Bool; let data: SaldoWidgetFeed?; let message: String? }
struct SaldoWidgetFeed: Codable {
    let account: String
    let generatedAt: String
    let counts: [String: Int]
    let total: Int
    let limited: Bool
    let items: [SaldoWidgetItem]
    var overview: [String: Int]? = nil
    var display: SaldoWidgetDisplay? = nil
    var taskCounts: [String: Int] { overview ?? counts }
    static let sample = Self(account: "SaldoLeve", generatedAt: "", counts: ["today": 3, "overdue": 1, "upcoming": 4], total: 8, limited: false, items: [
        .init(id: "1", itemId: "1", title: "Organizar a semana", subtitle: "Revisar os compromissos", dueAt: nil, dueDay: nil, state: "today", dueLabel: "Hoje, 09:00", amountLabel: nil),
        .init(id: "2", itemId: "2", title: "Mensalidades da casa", subtitle: "Internet", dueAt: nil, dueDay: nil, state: "overdue", dueLabel: "Atrasada", amountLabel: "R$ 99,90"),
        .init(id: "3", itemId: "3", title: "Preparar apresentação", subtitle: nil, dueAt: nil, dueDay: nil, state: "upcoming", dueLabel: "Amanhã", amountLabel: nil)])
}
struct SaldoWidgetDisplay: Codable, Equatable {
    static let maximumRows = 30
    var scope = "focus"
    var count = 10
    var textSize = 12
    var upcomingDays = 7
    var compact = true
    var showSubtotals = true
    var showDates = true
    var showSubtasks = true
    var groupByDate = true
    var showToday = true
    var showOverdue = true
    var showUpcoming = true
    var showHeader = false
    var showFooter = true
    var separators = false
    var groupCounts = true
    var overdueFirst = false
    var accent = "blue"
    var background = "system"
    var marker = "circle"
    var fontWeight = "medium"
    private var order: [String] { overdueFirst ? ["overdue", "today", "upcoming"] : ["today", "overdue", "upcoming"] }
    var states: [String] { scope == "focus" ? order.filter { ["today": showToday, "overdue": showOverdue, "upcoming": showUpcoming][$0] ?? true } : order }
    init() {}
    // Older servers and cached feeds do not send the 2.7.0 appearance keys;
    // every missing key keeps its default instead of failing the whole feed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        let base = Self()
        scope = value(.scope, base.scope); count = value(.count, base.count); textSize = value(.textSize, base.textSize); upcomingDays = value(.upcomingDays, base.upcomingDays)
        compact = value(.compact, base.compact); showSubtotals = value(.showSubtotals, base.showSubtotals); showDates = value(.showDates, base.showDates)
        showSubtasks = value(.showSubtasks, base.showSubtasks); groupByDate = value(.groupByDate, base.groupByDate)
        showToday = value(.showToday, base.showToday); showOverdue = value(.showOverdue, base.showOverdue); showUpcoming = value(.showUpcoming, base.showUpcoming)
        showHeader = value(.showHeader, base.showHeader); showFooter = value(.showFooter, base.showFooter); separators = value(.separators, base.separators)
        groupCounts = value(.groupCounts, base.groupCounts); overdueFirst = value(.overdueFirst, base.overdueFirst)
        accent = value(.accent, base.accent); background = value(.background, base.background); marker = value(.marker, base.marker); fontWeight = value(.fontWeight, base.fontWeight)
    }
    private enum CodingKeys: String, CodingKey {
        case scope, count, textSize, upcomingDays, compact, showSubtotals, showDates, showSubtasks, groupByDate, showToday, showOverdue, showUpcoming
        case showHeader, showFooter, separators, groupCounts, overdueFirst, accent, background, marker, fontWeight
    }
}

enum SaldoWidgetLayout {
    // Header, optional subtotals, group headings, footer and VStack gaps must
    // fit before rows are allocated. The taller family uses the same list.
    static func capacity(height: Double, rowHeight: Double, showSubtotals: Bool, groupCount: Int, requested: Int, header: Bool = true, footer: Bool = true) -> Int {
        guard height.isFinite, rowHeight.isFinite, rowHeight > 0 else { return 0 }
        let groups = max(0, groupCount)
        let children = 1 + (header ? 1 : 0) + (footer ? 1 : 0) + (showSubtotals ? 1 : 0) + (groups > 0 ? groups * 2 : 1)
        let reserved = Double((header ? 20 : 0) + (footer ? 12 : 0) + (showSubtotals ? 29 : 0) + groups * 12 + max(0, children - 1) * 4)
        let available = max(0, min(Double(SaldoWidgetDisplay.maximumRows), floor((height - reserved) / rowHeight)))
        return min(max(0, requested), Int(available))
    }
}
enum SaldoWidgetSelection {
    // Reserve at least one visible entry for each selected group, then fill the
    // available rows in date order. A backlog cannot hide today's entire list.
    static func items(_ input: [SaldoWidgetItem], limit: Int, grouped: Bool, states: [String], focus: Bool) -> [SaldoWidgetItem] {
        let items = focus ? input.filter { states.contains($0.state) } : input
        guard grouped else { return Array(items.prefix(max(0, limit))) }
        let base = ["today", "overdue", "upcoming"]
        let order = (focus || Set(states) == Set(base) ? states : base) + ["undated"]
        let buckets = order.map { state in items.filter { $0.state == state } }
        var chosen = Set<String>()
        for bucket in buckets where chosen.count < limit { if let first = bucket.first { chosen.insert(first.id) } }
        for item in items where chosen.count < limit { chosen.insert(item.id) }
        return buckets.flatMap { $0.filter { chosen.contains($0.id) } }
    }
}
struct SaldoWidgetItem: Codable, Identifiable {
    let id: String
    let itemId: String
    let title: String
    let subtitle: String?
    let dueAt: String?
    let dueDay: String?
    let state: String
    let dueLabel: String
    let amountLabel: String?
    var deepLink: URL { var url = URLComponents(); url.scheme = "saldoleve"; url.host = "tasks"; url.queryItems = [URLQueryItem(name: "id", value: itemId)]; return url.url! }
}
