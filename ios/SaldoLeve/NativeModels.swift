import Foundation

enum NativeRequestError {
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

struct NativeFailure: LocalizedError {
    let message: String
    let status: Int
    let details: JSONObject?
    var errorDescription: String? { message }
    init(_ message: String, status: Int = 0, details: JSONObject? = nil) { self.message = message; self.status = status; self.details = details }
}

// Preserve every server field when editing, including payment/cycle metadata
// and fields that a future web version introduces.
enum JSONValue: Codable, Equatable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v):
            if v.rounded(.towardZero) == v && v >= Double(Int64.min) && v < Double(Int64.max) { try c.encode(Int64(v)) }
            else { try c.encode(v) }
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String { if case .string(let v) = self { return v }; if case .number(let v) = self { return String(Int(v)) }; return "" }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
}
typealias JSONObject = [String: JSONValue]
extension Dictionary where Key == String, Value == JSONValue {
    func text(_ key: String) -> String { self[key]?.string ?? "" }
    func flag(_ key: String) -> Bool { self[key]?.bool ?? false }
    func integer(_ key: String) -> Int { self[key]?.number.map { Int($0) } ?? Int(self[key]?.string ?? "") ?? 0 }
    func objects(_ key: String) -> [JSONObject] { self[key]?.array.compactMap { if case .object(let v) = $0 { return v }; return nil } ?? [] }
}
enum NativeDate {
    private static let parsed = NSCache<NSString, NSDate>()
    private static let lock = NSLock()
    private static let standard = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f }()
    static func parse(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let cached = parsed.object(forKey: raw as NSString) { return cached as Date }
        lock.lock(); defer { lock.unlock() }
        guard let date = standard.date(from: raw) ?? fractional.date(from: raw) else { return nil }
        parsed.countLimit = 20000; parsed.setObject(date as NSDate, forKey: raw as NSString)
        return date
    }
    static func iso(_ date: Date) -> String { lock.lock(); defer { lock.unlock() }; return standard.string(from: date) }
    static func formatter(_ pattern: String, zone: String, locale: String = "en_US_POSIX") -> DateFormatter {
        let key = "SaldoLeve.formatter|" + pattern + "|" + zone + "|" + locale
        if let saved = Thread.current.threadDictionary[key] as? DateFormatter { return saved }
        let f = DateFormatter(); f.locale = Locale(identifier: locale); f.timeZone = TimeZone(identifier: zone); f.dateFormat = pattern; f.isLenient = false
        Thread.current.threadDictionary[key] = f; return f
    }
    static func quarter(_ date: Date) -> Date { Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970 / 900) * 900) }
    static func money(_ cents: Double?) -> String {
        guard let cents else { return "Valor a definir" }
        return (cents / 100).formatted(.currency(code: "BRL").locale(Locale(identifier: "pt_BR")))
    }
    static func cents(_ text: String) -> Int? {
        let cleaned = text.replacingOccurrences(of: "R$", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        let normalized = cleaned.contains(",") ? cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") : cleaned
        guard normalized.range(of: #"^(?:[0-9]+(?:\.[0-9]{0,2})?|\.[0-9]{1,2})$"#, options: .regularExpression) != nil,
              let number = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), number >= 0,
              number <= Decimal(string: "999999999.99")! else { return nil }
        return NSDecimalNumber(decimal: number * 100).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)).intValue
    }
}
struct NativeTask: Codable, Identifiable, Equatable {
    var fields: JSONObject
    init(_ fields: JSONObject) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try JSONObject(from: decoder) }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    var id: String { fields.text("id") }
    var title: String { fields.text("title") }
    var categoryID: String { fields.text("listId") }
    var status: String { fields.text("status") }
    var revision: Int { fields.integer("revision") }
    var checks: [NativeCheck] { fields.objects("checklist").map(NativeCheck.init) }
    var isDone: Bool { status == "done" }
    var isActive: Bool { ["todo", "doing"].contains(status) }
    var paused: Bool { NativeDate.parse(fields.text("pausedUntil")).map { $0 > Date() } ?? false }
    var dates: [Date] {
        if !checks.isEmpty { return checks.filter { !$0.done && !$0.paused }.compactMap(\.date) }
        return NativeDate.parse(fields.text("dueAt")).map { [$0] } ?? []
    }
    var nextDate: Date? { dates.min() }
    var moneyMode: String { fields.text("moneyMode") }
    var isMoney: Bool { ["pay", "receive"].contains(moneyMode) }
    var completionLabel: String { isMoney ? (moneyMode == "receive" ? "Recebido" : "Pago") : "Concluir" }
    static func draft(categoryID: String) -> NativeTask {
        NativeTask(["listId": .string(categoryID), "title": .string(""), "body": .string(""), "status": .string("todo"),
                    "timezone": .string(TimeZone.current.identifier), "moneyMode": .string("normal"), "checklist": .array([]),
                    "repeat": .object(["frequency": .string("none"), "interval": .number(1)]), "dateRemindersEnabled": .bool(true),
                    "captureKey": .string(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())])
    }
}
struct NativeCheck: Identifiable, Equatable {
    var fields: JSONObject
    init(_ fields: JSONObject) { self.fields = fields }
    var id: String { fields.text("id") }
    var title: String { fields.text("text") }
    var done: Bool { fields.flag("done") }
    var date: Date? { NativeDate.parse(fields.text("remindAt")) }
    var paused: Bool { NativeDate.parse(fields.text("pausedUntil")).map { $0 > Date() } ?? false }
}
struct NativeCategory: Codable, Identifiable, Equatable {
    var fields: JSONObject
    init(from decoder: Decoder) throws { fields = try JSONObject(from: decoder) }
    init(_ fields: JSONObject) { self.fields = fields }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    var id: String { fields.text("id") }
    var name: String { fields.text("name") }
    var canEdit: Bool { fields.flag("canEdit") && !fields.flag("archived") }
    var archived: Bool { fields.flag("archived") }
}
struct NativeSnapshot: Codable {
    var configured: Bool = false
    var message: String?
    var lists: [NativeCategory] = []
    var items: [NativeTask] = []
    var hasMoreItems: Bool = false
    var preferences: JSONObject = [:]
    var activity: [JSONObject] = []
    var habits: [JSONObject] = []
    var users: [JSONObject] = []
    init() {}
    enum CodingKeys: String, CodingKey { case configured, message, lists, items, hasMoreItems, preferences, activity, habits, users }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        message = try c.decodeIfPresent(String.self, forKey: .message)
        lists = try c.decodeIfPresent([NativeCategory].self, forKey: .lists) ?? []
        items = try c.decodeIfPresent([NativeTask].self, forKey: .items) ?? []
        hasMoreItems = try c.decodeIfPresent(Bool.self, forKey: .hasMoreItems) ?? false
        preferences = try c.decodeIfPresent(JSONObject.self, forKey: .preferences) ?? [:]
        activity = try c.decodeIfPresent([JSONObject].self, forKey: .activity) ?? []
        habits = try c.decodeIfPresent([JSONObject].self, forKey: .habits) ?? []
        users = try c.decodeIfPresent([JSONObject].self, forKey: .users) ?? []
    }
}
enum TaskScope: String, CaseIterable, Identifiable {
    static let fixedDrawerScopes: [Self] = [.all, .today, .overdue]
    static let additionalDrawerScopes: [Self] = [.tomorrow, .upcoming, .done, .archived, .trash, .assigned]
    case all = "Tudo", today = "Hoje", tomorrow = "Amanhã", upcoming = "Próximos 7 dias", overdue = "Atrasadas", assigned = "Atribuídas a mim", done = "Concluídas", archived = "Arquivo", trash = "Lixeira"
    var id: String { rawValue }
    var key: String { switch self {
        case .all: return "all"; case .today: return "today"; case .tomorrow: return "tomorrow"; case .upcoming: return "next"
        case .overdue: return "overdue"; case .assigned: return "assigned"; case .done: return "done"; case .archived: return "archived"; case .trash: return "trash"
    } }
    var icon: String { switch self {
        case .all: return "tray"; case .today: return "sun.max"; case .tomorrow: return "sunrise"; case .upcoming: return "calendar"
        case .overdue: return "exclamationmark.circle"; case .assigned: return "person"; case .done: return "checkmark.circle"; case .archived: return "archivebox"; case .trash: return "trash"
    } }
    init(key: String) { self = Self.allCases.first { $0.key == key } ?? .all }
    func matches(_ task: NativeTask, day: Date = Date(), calendar: Calendar = .current) -> Bool {
        if self == .trash { return task.status == "trashed" }
        if self == .archived { return task.status == "archived" }
        if self == .done { return task.isDone }
        guard task.isActive else { return false }
        if self == .all || self == .assigned { return true }
        guard let date = task.listDate else { return false }
        if self == .overdue { return task.isOverdue(now: day, calendar: calendar) }
        if self == .today { return calendar.isDate(date, inSameDayAs: day) }
        if self == .tomorrow { return calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: day)!) }
        let end = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: day))!
        return date >= calendar.startOfDay(for: day) && date < end
    }
}

extension NativeTask {
    var listDate: Date? { NativeDate.parse(fields.text("dueAt")) ?? nextDate }
    var tags: [String] { fields["tags"]?.array.map(\.string) ?? [] }
    var pendingAmount: Double? {
        let values = checks.isEmpty ? [fields["amountCents"]?.number] : checks.filter { !$0.done }.map { $0.fields["amountCents"]?.number }
        return values.contains(where: { $0 != nil }) ? values.compactMap { $0 }.reduce(0, +) : nil
    }
    func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isActive, let date = listDate else { return false }
        let midnight = calendar.component(.hour, from: date) == 0 && calendar.component(.minute, from: date) == 0
        return midnight ? date < calendar.startOfDay(for: now) : date < now
    }
    // Apply only edits made while the request was in flight. The server owns
    // revisions, payment history and the next monthly cycle.
    func rebased(after submitted: NativeTask, server: NativeTask) -> NativeTask {
        NativeTaskMerge(local: self, base: submitted, remote: server).task
    }
}

enum NativeTaskSort: String, CaseIterable, Identifiable {
    case due = "Prazo", updated = "Atualização", title = "Título", manual = "Ordem manual"
    case created = "Adicionadas recentemente", oldest = "Adicionadas há mais tempo", titleDescending = "Título Z–A"
    var id: String { rawValue }
    var label: String { switch self { case .due: return "Prazo mais próximo"; case .updated: return "Alteradas recentemente"; case .title: return "Ordem alfabética A–Z"; case .titleDescending: return "Ordem alfabética Z–A"; default: return rawValue } }
}

struct NativeTaskDateFilter: Hashable {
    static let periods = ["all", "today", "week", "month", "last7", "last30", "custom"]
    static let fields = ["due", "created", "updated"]
    static let labels = ["all":"Todo o período", "today":"Hoje", "week":"Esta semana", "month":"Este mês", "last7":"Últimos 7 dias", "last30":"Últimos 30 dias", "custom":"Período personalizado", "due":"Prazo da tarefa ou subtarefa", "created":"Data em que foi adicionada", "updated":"Última alteração"]
    var period = "all"
    var field = "due"
    var from = ""
    var to = ""
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func date(_ value: String, calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, value.count == 10, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])), dayString(date, calendar: calendar) == value else { return nil }
        return date
    }
    var valid: Bool { period != "custom" || (Self.date(from) != nil && Self.date(to) != nil && from <= to) }
    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        func days(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        switch period {
        case "today": return DateInterval(start: today, end: days(1))
        case "week": return calendar.dateInterval(of: .weekOfYear, for: now)
        case "month": return calendar.dateInterval(of: .month, for: now)
        case "last7": return DateInterval(start: days(-6), end: days(1))
        case "last30": return DateInterval(start: days(-29), end: days(1))
        case "custom":
            guard let start = Self.date(from, calendar: calendar), let last = Self.date(to, calendar: calendar), start <= last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
            return DateInterval(start: start, end: end)
        default: return nil
        }
    }
    func matches(_ task: NativeTask, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if period == "all" { return true }
        guard let range = interval(now: now, calendar: calendar) else { return false }
        let dates: [Date]
        switch field {
        case "created": dates = [NativeDate.parse(task.fields.text("createdAt"))].compactMap { $0 }
        case "updated": dates = [NativeDate.parse(task.fields.text("updatedAt"))].compactMap { $0 }
        default: dates = task.dates.isEmpty ? [task.listDate].compactMap { $0 } : task.dates
        }
        return dates.contains { $0 >= range.start && $0 < range.end }
    }
}
enum NativeDailyQuery {
    static func select(_ snapshot: NativeSnapshot, state: String, days: Int = 7, now: Date = Date()) -> [NativeTask] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let today = NativeMonth.day(now, zone: calendar.timeZone.identifier)
        let lastDay = NativeMonth.day(calendar.date(byAdding: .day, value: min(30, max(1, days)), to: now)!, zone: calendar.timeZone.identifier)
        return NativeTaskQuery.select(snapshot, scope: .all, now: now).filter { task in
            guard NativeDate.parse(task.fields.text("pausedUntil")).map({ $0 > now }) != true else { return false }
            let fallback = NativeDate.parse(task.fields.text("dueAt"))
            let hasDates = task.checks.contains { $0.date != nil }
            let dates = task.checks.isEmpty ? [fallback].compactMap { $0 } : task.checks.filter { !$0.done && NativeDate.parse($0.fields.text("pausedUntil")).map({ $0 > now }) != true }.compactMap { $0.date ?? (hasDates ? nil : fallback) }
            var local = calendar; local.timeZone = TimeZone(identifier: task.fields.text("timezone")) ?? calendar.timeZone
            return dates.contains { date in
                let allDay = local.component(.hour, from: date) == 0 && local.component(.minute, from: date) == 0 && local.component(.second, from: date) == 0
                let day = NativeMonth.day(date, zone: allDay ? local.timeZone.identifier : calendar.timeZone.identifier)
                let deadline = allDay ? local.date(byAdding: .day, value: 1, to: date)! : date
                if state == "overdue" { return deadline <= now }
                if state == "today" { return deadline > now && day == today }
                return day > today && day <= lastDay
            }
        }
    }
}
struct NativeTaskGroup: Identifiable {
    let id: String, title: String
    var items: [NativeTask]
}
enum NativeTaskQuery {
    static func select(_ snapshot: NativeSnapshot, scope: TaskScope, categoryID: String = "", tag: String = "", search: String = "", sort: NativeTaskSort = .due, userID: String = "", includeDone: Bool = false, now: Date = Date(), calendar: Calendar = .current, day: Date? = nil, dateFilter: NativeTaskDateFilter = .init()) -> [NativeTask] {
        let categories = Dictionary(snapshot.lists.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let visible = snapshot.items.filter { task in
            guard let category = categories[task.categoryID], categoryID.isEmpty || task.categoryID == categoryID,
                  tag.isEmpty || task.tags.contains(tag) else { return false }
            if !search.isEmpty {
                let haystack = ([task.title, task.fields.text("body")] + task.tags + task.checks.map(\.title)).joined(separator: " ")
                guard haystack.localizedStandardContains(search) else { return false }
            }
            if let day, !NativeTaskIndex.dates(task).contains(where: { calendar.isDate($0, inSameDayAs: day) }) { return false }
            guard dateFilter.matches(task, now: now, calendar: calendar) else { return false }
            if scope == .archived { return task.status != "trashed" && (task.status == "archived" || category.archived) }
            if scope == .trash { return task.status == "trashed" }
            guard !category.archived else { return false }
            if scope == .assigned && task.fields.text("assignedTo") != userID { return false }
            var candidate = task
            if includeDone && task.isDone && scope != .done { candidate.fields["status"] = .string("todo") }
            return scope.matches(candidate, day: now, calendar: calendar)
        }
        if sort == .due {
            return visible.map { ($0, $0.listDate ?? .distantFuture) }.sorted { a, b in
                if a.0.fields.flag("pinned") != b.0.fields.flag("pinned") { return a.0.fields.flag("pinned") }
                return a.1 == b.1 ? (Int(a.0.id) ?? Int.max) < (Int(b.0.id) ?? Int.max) : a.1 < b.1
            }.map { $0.0 }
        }
        if [.created, .oldest, .updated].contains(sort) {
            let key = sort == .updated ? "updatedAt" : "createdAt"
            return visible.map { ($0, NativeDate.parse($0.fields.text(key))) }.sorted { a, b in
                if a.0.fields.flag("pinned") != b.0.fields.flag("pinned") { return a.0.fields.flag("pinned") }
                if a.1 != b.1 { guard let first = a.1 else { return false }; guard let second = b.1 else { return true }; return sort == .oldest ? first < second : first > second }
                return (Int(a.0.id) ?? Int.max) < (Int(b.0.id) ?? Int.max)
            }.map { $0.0 }
        }
        return visible.sorted { a, b in
            if a.fields.flag("pinned") != b.fields.flag("pinned") { return a.fields.flag("pinned") }
            switch sort {
            case .due: if a.listDate != b.listDate { return (a.listDate ?? .distantFuture) < (b.listDate ?? .distantFuture) }
            case .title: if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case .titleDescending: if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedDescending }
            case .created, .oldest: break
            case .updated: if a.fields.text("updatedAt") != b.fields.text("updatedAt") { return a.fields.text("updatedAt") > b.fields.text("updatedAt") }
            case .manual: if a.fields.integer("sortOrder") != b.fields.integer("sortOrder") { return a.fields.integer("sortOrder") < b.fields.integer("sortOrder") }
            }
            return (Int(a.id) ?? Int.max) < (Int(b.id) ?? Int.max)
        }
    }
    static func groups(_ tasks: [NativeTask], scope: TaskScope, sort: NativeTaskSort, now: Date = Date(), calendar: Calendar = .current) -> [NativeTaskGroup] {
        if sort != .due || [.done, .archived, .trash].contains(scope) { return tasks.isEmpty ? [] : [.init(id: "all", title: "", items: tasks)] }
        let start = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        let week = calendar.date(byAdding: .day, value: 8, to: start)!
        var groups = [("pinned", "Fixados"), ("overdue", "Atrasadas"), ("today", "Hoje"), ("tomorrow", "Amanhã"), ("week", "Próximos 7 dias"), ("later", "Mais tarde"), ("nodate", "Sem data")].map { NativeTaskGroup(id: $0.0, title: $0.1, items: []) }
        for task in tasks {
            let key: String
            if task.fields.flag("pinned") { key = "pinned" }
            else if let date = task.listDate {
                key = date < start ? "overdue" : calendar.isDate(date, inSameDayAs: start) ? "today" : calendar.isDate(date, inSameDayAs: tomorrow) ? "tomorrow" : date < week ? "week" : "later"
            } else { key = "nodate" }
            groups[groups.firstIndex { $0.id == key }!].items.append(task)
        }
        groups.removeAll { $0.items.isEmpty }
        if groups.count == 1 && groups[0].id == "nodate" { groups[0] = .init(id: "nodate", title: "", items: groups[0].items) }
        return groups
    }
}

enum NativeQuickCapture {
    static func parse(_ input: String, categoryID: String, categories: [NativeCategory], defaultDate: Date? = nil, now: Date = Date(), calendar: Calendar = .current) -> NativeTask {
        var task = NativeTask.draft(categoryID: categoryID)
        var title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        func matches(_ pattern: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            return regex.matches(in: title, range: NSRange(title.startIndex..., in: title)).compactMap { Range($0.range, in: title).map { String(title[$0]) } }
        }
        for token in matches(#"(?<!\S)#[\p{L}\p{N}_-]+"#) { tags.append(String(token.dropFirst())); title = title.replacingOccurrences(of: token, with: "") }
        for token in matches(#"(?<!\S)~[\p{L}\p{N}_-]+"#) {
            if let category = categories.first(where: { $0.name.compare(String(token.dropFirst()), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                task.fields["listId"] = .string(category.id); title = title.replacingOccurrences(of: token, with: "")
            }
        }
        var due = defaultDate
        for token in matches(#"\b(hoje|amanhã|amanha)\b"#) {
            due = calendar.date(byAdding: .day, value: token.lowercased() == "hoje" ? 0 : 1, to: calendar.startOfDay(for: now))
            title = title.replacingOccurrences(of: token, with: "")
        }
        if let token = matches(#"\b(?:(?:às|as)\s+)?(?:[01]?\d|2[0-3])(?:h(?:[0-5]\d)?|:[0-5]\d)\b"#).first {
            let digits = token.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
            if let hour = digits.first {
                due = calendar.date(bySettingHour: hour, minute: digits.count > 1 ? digits[1] : 0, second: 0, of: due ?? now)
                title = title.replacingOccurrences(of: token, with: "")
            }
        }
        task.fields["title"] = .string(title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines))
        task.fields["tags"] = .array(Array(Set(tags)).sorted().map(JSONValue.string))
        if let due { task.fields["dueAt"] = .string(NativeDate.iso(NativeDate.quarter(due))) }
        return task
    }
}

// Reads phrases dictated to Siri, such as "comprar pão daqui a 2 horas",
// "ligar para o João amanhã às 9" or "pagar a luz em meia hora".
// The due time is rounded up to the next quarter hour, as the server requires.
enum NativeSpokenReminder {
    struct Result: Equatable { var title: String; var due: Date? }
    private static let numbers: [String: Double] = ["um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12, "quinze": 15, "vinte": 20, "trinta": 30, "quarenta": 40, "quarenta e cinco": 45, "meia": 0.5]
    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        var text = " " + input.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        var due: Date?
        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text) else { return nil }
            let groups = (0..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
            text.replaceSubrange(whole, with: " ")
            return groups
        }
        func amount(_ raw: String) -> Double? {
            let value = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if let number = Double(value.replacingOccurrences(of: ",", with: ".")) { return number }
            return numbers[value]
        }
        let quantity = #"(\d+(?:[.,]\d+)?|uma|um|duas|dois|tr[eê]s|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|quinze|vinte|trinta|quarenta(?: e cinco)?|meia)"#
        // "daqui a 2 horas", "em 30 minutos", "daqui meia hora", "daqui a 1 hora e meia"
        if let parts = take(#"\s(?:daqui\s+a|daqui|dentro\s+de|em)\s+"# + quantity + #"\s*(minutos?|min|horas?|h|dias?)(\s+e\s+meia)?(?=\s)"#),
           let value = amount(parts[1]) {
            let unit = parts[2].lowercased()
            var seconds = value * (unit.hasPrefix("d") ? 86400 : unit.hasPrefix("h") ? 3600 : 60)
            if !parts[3].isEmpty && unit.hasPrefix("h") { seconds += 1800 }
            due = now.addingTimeInterval(seconds)
        }
        var day: Date?
        if let parts = take(#"\s(hoje|amanh[ãa]|depois\s+de\s+amanh[ãa])(?=\s)"#) {
            let word = parts[1].lowercased()
            day = calendar.date(byAdding: .day, value: word.hasPrefix("hoje") ? 0 : word.hasPrefix("depois") ? 2 : 1, to: calendar.startOfDay(for: now))
        }
        if let parts = take(#"\s(?:às|as|ao|à|a)\s+(\d{1,2})(?:[:h](\d{2}))?\s*(?:h|horas?)?(?:\s+da\s+(manh[ãa]|tarde|noite))?(?=\s)"#),
           var hour = Int(parts[1]), hour < 24 {
            let minute = Int(parts[2]) ?? 0
            let period = parts[3].lowercased()
            if (period.hasPrefix("tarde") || period.hasPrefix("noite")) && hour < 12 { hour += 12 }
            var base = day ?? calendar.startOfDay(for: now)
            if var candidate = calendar.date(bySettingHour: hour, minute: min(59, minute), second: 0, of: base) {
                // "às 9" said in the evening means tomorrow morning.
                if day == nil && candidate <= now { base = calendar.date(byAdding: .day, value: 1, to: base)!; candidate = calendar.date(bySettingHour: hour, minute: min(59, minute), second: 0, of: base) ?? candidate }
                due = candidate
            }
        } else if let day, due == nil {
            due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
            if let value = due, value <= now { due = NativeDate.quarter(now.addingTimeInterval(3600)) }
        }
        var title = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["me avise de ", "me avisa de ", "me lembre de ", "me lembra de ", "lembrar de ", "avisar de ", "me avise para ", "me lembre para "] where title.lowercased().hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)); break
        }
        if let first = title.first { title = first.uppercased() + title.dropFirst() }
        return Result(title: String(title.prefix(200)), due: due.map(NativeDate.quarter))
    }
}

// The situation of a subtask, shared by every style of the opened task.
enum NativeCheckState {
    static func of(_ check: NativeCheck, now: Date = Date(), calendar: Calendar = .current) -> String {
        if check.done { return "done" }
        guard let date = check.date else { return "nodate" }
        let today = calendar.startOfDay(for: now)
        if date < today { return "overdue" }
        return calendar.isDate(date, inSameDayAs: today) ? "today" : "upcoming"
    }
    static func days(_ check: NativeCheck, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let date = check.date else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
    }
    // The pending subtask that is due first.
    static func next(_ checks: [NativeCheck]) -> String? {
        checks.filter { !$0.done && !$0.paused }.min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }?.id
    }
}

enum NativeMonth {
    static func key(_ date: Date, zone: String = "America/Sao_Paulo") -> String {
        NativeDate.formatter("yyyy-MM", zone: zone).string(from: date)
    }
    static func day(_ date: Date, zone: String) -> String {
        NativeDate.formatter("yyyy-MM-dd", zone: zone).string(from: date)
    }
}
enum NativeTableImport {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    static func parse(_ text: String, categoryID: String) throws -> [NativeTask] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, lines.count <= 200 else { throw Failure.invalid("Cole de 1 a 200 tarefas por vez.") }
        let dateParser = DateFormatter(); dateParser.locale = Locale(identifier: "pt_BR"); dateParser.timeZone = .current; dateParser.dateFormat = "dd/MM/yyyy"; dateParser.isLenient = false
        return try lines.enumerated().map { index, line in
            let columns = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !columns[0].isEmpty, columns[0].count <= 200, columns.count <= 3 else { throw Failure.invalid("Revise o nome e as colunas da linha \(index + 1).") }
            var draft = NativeTask.draft(categoryID: categoryID); draft.fields["title"] = .string(columns[0])
            if columns.count > 1 && !columns[1].isEmpty {
                guard let amount = NativeDate.cents(columns[1]) else { throw Failure.invalid("Valor inválido na linha \(index + 1).") }
                draft.fields["amountCents"] = .number(Double(amount)); draft.fields["moneyMode"] = .string("pay")
            }
            if columns.count > 2 && !columns[2].isEmpty {
                guard let date = dateParser.date(from: columns[2]), dateParser.string(from: date) == columns[2] else { throw Failure.invalid("Data inválida na linha \(index + 1). Use dd/mm/aaaa.") }
                draft.fields["dueAt"] = .string(NativeDate.iso(date))
            }
            return draft
        }
    }
}

struct PlannedReminder: Identifiable, Equatable {
    let id: String, taskID: String, title: String, body: String
    let date: Date
}
enum NativeReminderPlan {
    static func build(_ snapshot: NativeSnapshot, now: Date, limit: Int = 60, preferences: NativeNotificationPreferences = .init()) -> [PlannedReminder] {
        var planned: [PlannedReminder] = []
        guard preferences.tasks else { return [] }
        var quietCalendar = Calendar(identifier: .gregorian)
        quietCalendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        for task in snapshot.items where task.isActive && !task.paused && task.fields["dateRemindersEnabled"] != .bool(false) {
            guard let category = snapshot.lists.first(where: { $0.id == task.categoryID }), !category.archived else { continue }
            let targets: [(String, String, Date)] = task.checks.isEmpty
                ? NativeDate.parse(task.fields.text("dueAt")).map { [("main", task.title, $0)] } ?? []
                : task.checks.filter { preferences.subtasks && !$0.done && !$0.paused }.compactMap { check in check.date.map { (check.id, task.title + " → " + check.title, $0) } }
            for (key, text, due) in targets {
                // Match the existing 2-day/1-day/due schedule. Queue a finite
                // horizon; no fake promise of server push or background sync.
                var due = due
                if task.fields.flag("weekendAdvance") {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: task.fields.text("timezone")) ?? quietCalendar.timeZone
                    let weekday = calendar.component(.weekday, from: due)
                    if weekday == 7 { due = calendar.date(byAdding: .day, value: -1, to: due)! }
                    if weekday == 1 { due = calendar.date(byAdding: .day, value: -2, to: due)! }
                }
                let interval = Double(max(60, task.fields.integer("overdueMinutes"))) * 60
                var events: [(String, String, Date)] = []
                if preferences.twoDaysBefore { events.append(("before2", "Vence em 2 dias", due.addingTimeInterval(-172800))) }
                if preferences.oneDayBefore { events.append(("before1", "Vence amanhã", due.addingTimeInterval(-86400))) }
                if preferences.atDueTime { events.append(("due", "Tarefa pendente", due)) }
                if preferences.repeatOverdue {
                    let firstRepeat = due.addingTimeInterval(max(1, floor(now.timeIntervalSince(due) / interval) + 1) * interval)
                    for index in 0..<8 { events.append(("repeat-\(index)", "Tarefa pendente", firstRepeat.addingTimeInterval(Double(index) * interval))) }
                }
                var seen = Set<Date>()
                for (suffix, title, candidate) in events {
                    // A due event inside quiet time can still be delivered this
                    // morning when the app synchronizes before quiet time ends.
                    let fire = preferences.deliveryDate(candidate)
                    if fire <= now { continue }
                    guard seen.insert(fire).inserted else { continue }
                    planned.append(PlannedReminder(id: "sl-task-\(task.id)-\(key)-\(suffix)", taskID: task.id, title: title, body: text, date: fire))
                }
            }
        }
        return Array(planned.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.prefix(limit))
    }
}

struct NativeIdentity: Codable {
    let id: String, name: String, login: String
}
// Only server-confirmed data is cached. Extra legacy draft keys are ignored
// when decoding, and are never encoded again.
struct NativeLocalData: Codable {
    var user: NativeIdentity
    var snapshot: NativeSnapshot
    var syncedAt: Date?
}
