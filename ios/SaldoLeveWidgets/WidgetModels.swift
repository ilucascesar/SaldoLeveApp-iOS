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
    var states: [String] { scope == "focus" ? [("today", showToday), ("overdue", showOverdue), ("upcoming", showUpcoming)].filter { $0.1 }.map { $0.0 } : ["today", "overdue", "upcoming"] }
}

enum SaldoWidgetLayout {
    // Header, optional subtotals, group headings, footer and VStack gaps must
    // fit before rows are allocated. The taller family uses the same list.
    static func capacity(height: Double, rowHeight: Double, showSubtotals: Bool, groupCount: Int, requested: Int) -> Int {
        guard height.isFinite, rowHeight.isFinite, rowHeight > 0 else { return 0 }
        let groups = max(0, groupCount)
        let children = 3 + (showSubtotals ? 1 : 0) + (groups > 0 ? groups * 2 : 1)
        let reserved = Double(32 + (showSubtotals ? 29 : 0) + groups * 12 + max(0, children - 1) * 4)
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
        let order = (focus ? states : ["today", "overdue", "upcoming"]) + ["undated"]
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
