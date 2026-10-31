import Foundation

struct NativeLayoutPreferences: Codable, Equatable {
    static let key = "nativeLayoutPreferencesV1"
    var layoutRevision = 2
    var startPage = "tasks"
    var tabOrder = ["dashboard", "tasks"]
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
    var taskDefaultSort = "Prazo"
    var taskDefaultPeriod = "all"
    var taskDefaultPeriodField = "due"
    var taskDefaultFrom = ""
    var taskDefaultTo = ""
    var taskDetailLayout = "elegant"
    var taskDetailGrouping = "status"
    var taskDetailProgress = true
    var taskDetailMetadata = true
    var taskDetailExpandDone = true
    var taskDetailHighlightNext = true
    var taskDetailNumbers = false
    var taskDetailAmounts = true
    var taskDetailPills = true
    var taskDetailDensity = "regular"
    static let taskDetailStyles = ["elegant", "cards", "timeline", "ledger", "minimal"]
    static let taskDetailGroupings = ["status", "date", "none"]
    // Choosing a style starts from its recommended options; each one can still
    // be changed afterwards without losing the chosen style.
    mutating func applyTaskDetailPreset(_ style: String) {
        guard Self.taskDetailStyles.contains(style) else { return }
        taskDetailLayout = style
        // grouping, progress, metadata, completed open, next highlighted, numbers, situation, density
        let preset: (String, Bool, Bool, Bool, Bool, Bool, Bool, String)
        switch style {
        case "cards": preset = ("status", true, true, false, true, false, true, "regular")
        case "timeline": preset = ("date", true, true, true, true, false, true, "regular")
        case "ledger": preset = ("none", true, true, true, true, true, false, "compact")
        case "minimal": preset = ("none", false, false, true, false, false, false, "compact")
        default: preset = ("status", true, true, true, true, false, true, "regular")
        }
        taskDetailGrouping = preset.0; taskDetailProgress = preset.1; taskDetailMetadata = preset.2; taskDetailExpandDone = preset.3
        taskDetailHighlightNext = preset.4; taskDetailNumbers = preset.5; taskDetailPills = preset.6; taskDetailDensity = preset.7; taskDetailAmounts = true
    }
    var taskDateFilter: NativeTaskDateFilter {
        get { NativeTaskDateFilter(period: taskDefaultPeriod, field: taskDefaultPeriodField, from: taskDefaultFrom, to: taskDefaultTo) }
        set { taskDefaultPeriod = newValue.period; taskDefaultPeriodField = newValue.field; taskDefaultFrom = newValue.from; taskDefaultTo = newValue.to }
    }

    var spacing: Double { density == "compact" ? 8 : density == "spacious" ? 20 : 14 }
    var rowPadding: Double { density == "compact" ? 2 : density == "spacious" ? 10 : 5 }
    var visibleDashboard: [String] { dashboardOrder.filter { !dashboardHidden.contains($0) } }
    mutating func normalize() {
        let tabs = ["dashboard", "tasks"]
        let blocks = ["balance", "totals", "expenses", "pending", "shortcuts"]
        func ordered(_ supplied: [String], _ allowed: [String]) -> [String] {
            var seen = Set<String>(); return (supplied + allowed).filter { allowed.contains($0) && seen.insert($0).inserted }
        }
        tabOrder = ordered(tabOrder.map { $0 == "expenses" ? "dashboard" : $0 }, tabs); dashboardOrder = ordered(dashboardOrder, blocks)
        dashboardHidden = Array(Set(dashboardHidden.filter { blocks.contains($0) })).sorted()
        if startPage == "expenses" { startPage = "dashboard" }
        if !tabs.contains(startPage) { startPage = "tasks" }
        if !Self.taskDetailStyles.contains(taskDetailLayout) { taskDetailLayout = "elegant" }
        if !Self.taskDetailGroupings.contains(taskDetailGrouping) { taskDetailGrouping = "status" }
        if !["regular", "compact"].contains(taskDetailDensity) { taskDetailDensity = "regular" }
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
        taskDefaultScope = "all"
        if NativeTaskSort(rawValue: taskDefaultSort) == nil { taskDefaultSort = "Prazo" }
        if !NativeTaskDateFilter.periods.contains(taskDefaultPeriod) { taskDefaultPeriod = "all" }
        if !NativeTaskDateFilter.fields.contains(taskDefaultPeriodField) { taskDefaultPeriodField = "due" }
        if !taskDateFilter.valid { taskDefaultPeriod = "all"; taskDefaultFrom = ""; taskDefaultTo = "" }
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
