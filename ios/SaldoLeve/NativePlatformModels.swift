import Foundation

struct NativeBirthday: Codable, Identifiable, Equatable {
    var fields: JSONObject
    init(_ fields: JSONObject) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try JSONObject(from: decoder) }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    var id: String { fields.text("id").isEmpty ? fields.text("sourceKey") : fields.text("id") }
    var name: String { fields.text("name") }
    var month: Int { fields.integer("month") }
    var day: Int { fields.integer("day") }
    var year: Int? { fields["year"]?.number.map(Int.init) }
    var group: String { fields.text("group").isEmpty ? "Amigos" : fields.text("group") }
    var enabled: Bool { fields["enabled"] != .bool(false) }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: fields.text("timezone")) ?? TimeZone(identifier: "America/Sao_Paulo")!; return c }
    var fingerprint: String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR")).trimmingCharacters(in: .whitespaces) + "|\(month)|\(day)" }
    static func fresh(config: JSONObject = [:]) -> Self {
        var values: JSONObject = ["name": .string(""), "month": .number(1), "day": .number(1), "year": .null, "group": .string("Amigos"), "note": .string(""), "enabled": .bool(true), "daysBefore": .array([.number(0)]), "time": .string("09:00"), "timezone": .string("America/Sao_Paulo"), "leapPolicy": .string("feb28")]
        for (key, value) in config.record("birthdayDefaults") { values[key] = value }
        return Self(values)
    }
    func occurrence(year target: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var m = month, d = day
        let c = calendar
        guard let first = c.date(from: DateComponents(year: target, month: m, day: 1)), let days = c.range(of: .day, in: .month, for: first) else { return nil }
        if !days.contains(d) {
            guard month == 2 && day == 29 else { return nil }
            switch fields.text("leapPolicy") { case "leapOnly": return nil; case "mar01": m = 3; d = 1; default: d = 28 }
        }
        let parts = fields.text("time").split(separator: ":").compactMap { Int($0) }
        return c.date(from: DateComponents(year: target, month: m, day: d, hour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0))
    }
    func nextDate(now: Date = Date()) -> Date? {
        let c = calendar, start = c.startOfDay(for: now), y = c.component(.year, from: now)
        return (y...(y + 8)).compactMap { occurrence(year: $0) }.first { $0 >= start }
    }
    func age(at date: Date) -> Int? { year.map { max(0, calendar.component(.year, from: date) - $0) } }
    var dateLabel: String { String(format: "%02d/%02d", day, month) + (year.map { "/\($0)" } ?? "") }

    // Like a task, each yearly occurrence can be marked as done (for example,
    // after sending a message). The person stays in the same place in the list.
    static let lateDays = 2
    var completedYears: [Int] { fields["completedYears"]?.array.compactMap { $0.number.map(Int.init) } ?? [] }
    var persistent: Bool { fields["persistent"] != .bool(false) }
    var repeatMinutes: Int { [60, 120, 240, 360, 480].contains(fields.integer("overdueMinutes")) ? fields.integer("overdueMinutes") : 60 }
    // The occurrence the checkbox refers to: a birthday from the last two
    // days (done or not, so the person stays in place), otherwise the next one.
    func currentOccurrence(now: Date = Date()) -> Date? {
        let c = calendar, today = c.startOfDay(for: now), y = c.component(.year, from: now)
        let recent = ((y - 1)...y).compactMap { occurrence(year: $0) }.filter { c.startOfDay(for: $0) < today }.max()
        if let recent, let limit = c.date(byAdding: .day, value: Self.lateDays + 1, to: c.startOfDay(for: recent)), today < limit { return recent }
        return nextDate(now: now)
    }
    func isCompleted(now: Date = Date()) -> Bool {
        guard let date = currentOccurrence(now: now) else { return false }
        return completedYears.contains(calendar.component(.year, from: date))
    }
    func isLate(now: Date = Date()) -> Bool {
        guard let date = currentOccurrence(now: now) else { return false }
        return !isCompleted(now: now) && calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
    }
    func settingCompleted(_ done: Bool, now: Date = Date()) -> NativeBirthday {
        guard let date = currentOccurrence(now: now) else { return self }
        let target = calendar.component(.year, from: date)
        var years = Set(completedYears.filter { $0 >= target - 5 })
        if done { years.insert(target) } else { years.remove(target) }
        var copy = self; copy.fields["completedYears"] = .array(years.sorted().map { .number(Double($0)) })
        return copy
    }
}

// A saved place (Configurações → Locais) used by location reminders.
struct NativePlace: Identifiable, Equatable {
    var fields: JSONObject
    init(_ fields: JSONObject) { self.fields = fields }
    var id: String { fields.text("id") }
    var name: String { fields.text("name") }
    var latitude: Double { fields["latitude"]?.number ?? 0 }
    var longitude: Double { fields["longitude"]?.number ?? 0 }
    var radius: Double { min(1000, max(100, fields["radius"]?.number ?? 150)) }
    var valid: Bool { !name.isEmpty && (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0) }
    static let radii: [Double] = [100, 150, 200, 300, 500, 1000]
    static func list(_ config: JSONObject) -> [NativePlace] { (config["places"]?.array ?? []).compactMap { $0.object.isEmpty ? nil : NativePlace($0.object) }.filter(\.valid) }
}

// A task's location reminder: the place and whether to warn on arriving or leaving.
struct NativeLocationReminder: Equatable {
    var placeID: String
    var trigger: String
    init?(_ fields: JSONObject) {
        guard let value = fields["locationReminder"]?.object, !value.text("placeId").isEmpty else { return nil }
        placeID = value.text("placeId"); trigger = value.text("trigger") == "leave" ? "leave" : "arrive"
    }
    // Tasks for the same place and direction share one grouped notification.
    // A location task works as a list (e.g. the market shopping list): it only
    // warns while it has pending subtasks, and the alert shows those items.
    struct Group: Equatable {
        var place: NativePlace; var trigger: String; var titles: [String]; var taskIDs: [String]; var items: [[String]] = []
        // One line per list with its pending items: "Mercado: arroz, leite, pão +2".
        var summary: String {
            func line(_ index: Int) -> String {
                let pending = index < items.count ? items[index] : []
                let shown = pending.prefix(6).joined(separator: ", ") + (pending.count > 6 ? " +\(pending.count - 6)" : "")
                return pending.isEmpty ? titles[index] : titles[index] + ": " + shown
            }
            return titles.indices.prefix(4).map(line).joined(separator: "\n") + (titles.count > 4 ? "\n+\(titles.count - 4) tarefas" : "")
        }
    }
    static func pendingItems(_ task: NativeTask) -> [String] { task.checks.filter { !$0.done && !$0.paused }.map(\.title).filter { !$0.isEmpty } }
    static func groups(_ snapshot: NativeSnapshot, places: [NativePlace], limit: Int = 12) -> [Group] {
        var result: [Group] = []
        for task in snapshot.items where task.isActive && !task.paused {
            guard let reminder = NativeLocationReminder(task.fields), let place = places.first(where: { $0.id == reminder.placeID }) else { continue }
            let items = pendingItems(task)
            guard !items.isEmpty else { continue }
            if let index = result.firstIndex(where: { $0.place.id == place.id && $0.trigger == reminder.trigger }) {
                result[index].titles.append(task.title); result[index].taskIDs.append(task.id); result[index].items.append(items)
            } else { result.append(Group(place: place, trigger: reminder.trigger, titles: [task.title], taskIDs: [task.id], items: [items])) }
        }
        return Array(result.sorted { $0.titles.count > $1.titles.count }.prefix(limit))
    }
}

struct NativePlatformSnapshot: Codable {
    var revision = 0
    var apiVersion = 0
    var config: JSONObject = [:]
    var birthdays: [NativeBirthday] = []
    var serverNow: String?
    init() {}
    enum CodingKeys: String, CodingKey { case revision, apiVersion, config, birthdays, serverNow }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        apiVersion = try c.decodeIfPresent(Int.self, forKey: .apiVersion) ?? 0
        config = try c.decodeIfPresent(JSONObject.self, forKey: .config) ?? [:]
        birthdays = try c.decodeIfPresent([NativeBirthday].self, forKey: .birthdays) ?? []
        serverNow = try c.decodeIfPresent(String.self, forKey: .serverNow)
    }
}

struct NativeSearchPage: Decodable {
    var items: [JSONObject]
    var total: Int
    var nextOffset: Int?
    var users: [JSONObject]
}

enum NativeBirthdayPlan {
    static func build(_ birthdays: [NativeBirthday], now: Date = Date(), preferences: NativeNotificationPreferences) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for birthday in birthdays where birthday.enabled {
            let c = birthday.calendar, y = c.component(.year, from: now)
            let offsets = birthday.fields["daysBefore"]?.array.compactMap { $0.number.map(Int.init) } ?? [0]
            for offset in Set(offsets).filter({ (0...90).contains($0) }) {
                for year in y...(y + 8) where !birthday.completedYears.contains(year) {
                    guard let occasion = birthday.occurrence(year: year), let candidate = c.date(byAdding: .day, value: -offset, to: occasion) else { continue }
                    let delivery = preferences.deliveryDate(candidate)
                    guard delivery > now else { continue }
                    let body = offset == 0 ? "Hoje é aniversário de \(birthday.name)." : "Aniversário de \(birthday.name) em \(offset) dia(s), dia \(String(format: "%02d/%02d", birthday.day, birthday.month))."
                    result.append(PlannedReminder(id: "sl-task-birthday-\(birthday.id)-\(offset)", taskID: "birthday:" + birthday.id, title: "Aniversário · " + birthday.name, body: body, date: delivery))
                    break
                }
            }
            // Persistent alerts, like overdue tasks: after the birthday time,
            // repeat until it is marked as done (at most two days later).
            guard preferences.repeatOverdue, birthday.persistent, !birthday.isCompleted(now: now), let occasion = birthday.currentOccurrence(now: now),
                  occasion.timeIntervalSince(now) < 7 * 86400, let limit = c.date(byAdding: .day, value: NativeBirthday.lateDays + 1, to: c.startOfDay(for: occasion)) else { continue }
            let interval = Double(birthday.repeatMinutes) * 60
            let first = occasion.addingTimeInterval(max(1, floor(now.timeIntervalSince(occasion) / interval) + 1) * interval)
            var seen = Set<Date>()
            for index in 0..<8 {
                let delivery = preferences.deliveryDate(first.addingTimeInterval(Double(index) * interval))
                guard delivery > now, delivery < limit, seen.insert(delivery).inserted else { continue }
                result.append(PlannedReminder(id: "sl-task-birthday-\(birthday.id)-repeat-\(index)", taskID: "birthday:" + birthday.id, title: "Aniversário · " + birthday.name, body: "Ainda falta dar os parabéns para \(birthday.name). Marque como concluído no SaldoLeve.", date: delivery))
            }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
