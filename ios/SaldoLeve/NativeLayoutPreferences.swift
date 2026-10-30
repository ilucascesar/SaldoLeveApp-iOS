import Foundation

struct NativeLayoutPreferences: Codable, Equatable {
    static let key = "nativeLayoutPreferencesV1"
    var layoutRevision = 2
    var startPage = "tasks"
    var tabOrder = ["dashboard", "expenses", "tasks"]
    var showBottomBar = true
    var compactHeader = true
    var showSearch = true
    var showMonth = true
    var density = "comfortable"
    var textScale = 1.0
    var roundedValues = true
    var cardStyle = "cards"
    var cardColumns = 3
    var cardRadius = 20.0
    var cardShowIcon = true
    var cardShowType = true
    var cardShowShare = true
    var cardShowBreakdown = true
    var cardShowActions = true
    var expenseOrder = "manual"
    var expenseGrouping = "none"
    var expenseDefaultFilter = "all"
    var expenseCustomOrder: [String] = []
    var pinnedExpenses: [String] = []
    var dashboardOrder = ["balance", "totals", "expenses", "pending", "shortcuts"]
    var dashboardHidden: [String] = []
    var dashboardShowPaid = true
    var dashboardExpenseLimit = 0
    var taskShowSummaries = true
    var taskShowCategory = true
    var taskShowAmounts = true
    var taskShowTags = true
    var taskQuickCapture = true
    var taskShowCompleted = true
    var taskGroupByDate = true
    var taskDefaultScope = "all"
    var taskDefaultView = "list"

    var spacing: Double { density == "compact" ? 8 : density == "spacious" ? 20 : 14 }
    var rowPadding: Double { density == "compact" ? 2 : density == "spacious" ? 10 : 5 }
    var visibleDashboard: [String] { dashboardOrder.filter { !dashboardHidden.contains($0) } }
    mutating func normalize() {
        let tabs = ["dashboard", "expenses", "tasks"]
        let blocks = ["balance", "totals", "expenses", "pending", "shortcuts"]
        func ordered(_ supplied: [String], _ allowed: [String]) -> [String] {
            var seen = Set<String>(); return (supplied + allowed).filter { allowed.contains($0) && seen.insert($0).inserted }
        }
        tabOrder = ordered(tabOrder, tabs); dashboardOrder = ordered(dashboardOrder, blocks)
        dashboardHidden = Array(Set(dashboardHidden.filter { blocks.contains($0) })).sorted()
        if !tabs.contains(startPage) { startPage = "tasks" }
        if !["compact", "comfortable", "spacious"].contains(density) { density = "comfortable" }
        textScale = textScale.isFinite ? min(1.3, max(0.85, textScale)) : 1
        cardRadius = cardRadius.isFinite ? min(30, max(8, cardRadius)) : 20
        cardColumns = min(4, max(1, cardColumns))
        if !["cards", "compact"].contains(cardStyle) { cardStyle = "cards" }
        if !["manual", "name", "amount", "pending"].contains(expenseOrder) { expenseOrder = "manual" }
        if !["none", "type", "status"].contains(expenseGrouping) { expenseGrouping = "none" }
        if !["active", "all", "pending", "paid", "inactive"].contains(expenseDefaultFilter) { expenseDefaultFilter = "all" }
        var seen = Set<String>(); expenseCustomOrder = expenseCustomOrder.filter { !$0.isEmpty && $0.count <= 30 && seen.insert($0).inserted }
        if ![0, 3, 5, 10].contains(dashboardExpenseLimit) { dashboardExpenseLimit = 0 }
        pinnedExpenses = Array(Set(pinnedExpenses.filter { !$0.isEmpty && $0.count <= 30 })).sorted()
        if !["all", "today", "tomorrow", "next", "overdue", "assigned", "done"].contains(taskDefaultScope) { taskDefaultScope = "all" }
        if !["list", "calendar", "habits"].contains(taskDefaultView) { taskDefaultView = "list" }
    }
    static func read(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let initial = try? JSONEncoder().encode(Self()), let base = try? JSONSerialization.jsonObject(with: initial) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(saved) { _, next in next }),
              var result = try? JSONDecoder().decode(Self.self, from: merged) else { return Self() }
        if (saved["layoutRevision"] as? Int ?? 0) < 2 {
            result.layoutRevision = 2; result.cardColumns = 3
            result.taskDefaultScope = "all"; result.expenseDefaultFilter = "all"
            result.dashboardShowPaid = true; result.dashboardExpenseLimit = 0; result.dashboardHidden = []
        }
        result.normalize(); return result
    }
    func save(_ defaults: UserDefaults = .standard) { var copy = self; copy.normalize(); if let data = try? JSONEncoder().encode(copy) { defaults.set(data, forKey: Self.key) } }
}
