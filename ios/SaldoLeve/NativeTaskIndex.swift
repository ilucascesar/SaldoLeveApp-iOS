import Foundation

// Derived once per snapshot, outside the main actor. Calendar cells and drawer
// counters read this index instead of repeatedly filtering and sorting tasks.
struct NativeTaskIndex {
    var categories: [String: NativeCategory] = [:]
    var scopes: [String: Int] = [:]
    var categoryCounts: [String: Int] = [:]
    var calendarCounts: [String: [Date: Int]] = [:]
    var tags: [String] = []
    var revision = UUID()
    init() {}
    init(_ snapshot: NativeSnapshot, userID: String, now: Date = Date(), calendar: Calendar = .current) {
        categories = Dictionary(snapshot.lists.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var allTags = Set<String>()
        for task in snapshot.items {
            if task.status != "trashed" { allTags.formUnion(task.tags) }
            guard let category = categories[task.categoryID] else { continue }
            if task.status == "trashed" { scopes["trash", default: 0] += 1; continue }
            if category.archived || task.status == "archived" { scopes["archived", default: 0] += 1 }
            guard !category.archived else { continue }
            if task.isDone { scopes["done", default: 0] += 1 }
            guard task.isActive else { continue }
            categoryCounts[task.categoryID, default: 0] += 1
            scopes["all", default: 0] += 1
            if task.fields.text("assignedTo") == userID { scopes["assigned", default: 0] += 1 }
            for scope in [TaskScope.today, .tomorrow, .overdue, .upcoming] where scope.matches(task, day: now, calendar: calendar) { scopes[scope.key, default: 0] += 1 }
            for day in Set(Self.dates(task).map { calendar.startOfDay(for: $0) }) {
                calendarCounts["", default: [:]][day, default: 0] += 1
                calendarCounts[task.categoryID, default: [:]][day, default: 0] += 1
            }
        }
        tags = allTags.sorted()
    }
    static func dates(_ task: NativeTask) -> [Date] {
        let dates = task.dates
        return dates.isEmpty ? [task.listDate ?? NativeDate.parse(task.fields.text("createdAt"))].compactMap { $0 } : dates
    }
    func count(day: Date, categoryID: String = "", calendar: Calendar = .current) -> Int { calendarCounts[categoryID]?[calendar.startOfDay(for: day)] ?? 0 }
}

enum NativeExpenseOrder {
    static func moving(_ source: String, before target: String, in ids: [String]) -> [String]? {
        guard source != target, ids.contains(source), ids.contains(target) else { return nil }
        var result = ids.filter { $0 != source }
        guard let index = result.firstIndex(of: target) else { return nil }
        result.insert(source, at: index); return result
    }
}

struct NativeTaskRequest: Hashable {
    var revision: UUID
    var scope: String
    var category: String
    var tag: String
    var search: String
    var sort: String
    var page: String
    var day: Date?
    var groupDates: Bool
    var showDone: Bool
    var userID: String
    var dateFilter = NativeTaskDateFilter()
}
struct NativeTaskProjection {
    var items: [NativeTask] = []
    var groups: [NativeTaskGroup] = []
    init() {}
    init(_ snapshot: NativeSnapshot, request: NativeTaskRequest) {
        let calendar = request.page == "calendar"
        let scope = calendar ? TaskScope.all : TaskScope(key: request.scope)
        let sort = NativeTaskSort(rawValue: request.sort) ?? .due
        func select(_ includeDone: Bool) -> [NativeTask] { NativeTaskQuery.select(snapshot, scope: scope, categoryID: request.category, tag: request.tag, search: request.search, sort: sort, userID: request.userID, includeDone: includeDone, day: request.day, dateFilter: request.dateFilter) }
        items = select(calendar)
        groups = request.groupDates ? NativeTaskQuery.groups(items, scope: calendar ? .done : scope, sort: sort) : [.init(id: "all", title: "", items: items)]
        if request.showDone && !calendar && ![.done, .trash, .archived].contains(scope) {
            let selectedDone = select(true).filter(\.isDone)
            let done = sort == .due ? selectedDone.sorted { $0.fields.text("completedAt") > $1.fields.text("completedAt") } : selectedDone
            if !done.isEmpty { groups.append(.init(id: "done", title: "Concluídas", items: done)) }
        }
    }
}
