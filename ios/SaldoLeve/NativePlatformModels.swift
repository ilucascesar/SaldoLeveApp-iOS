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
}

struct NativePlatformSnapshot: Codable {
    var revision = 0
    var config: JSONObject = [:]
    var birthdays: [NativeBirthday] = []
    var serverNow: String?
    init() {}
    enum CodingKeys: String, CodingKey { case revision, config, birthdays, serverNow }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
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
                for year in y...(y + 8) {
                    guard let occasion = birthday.occurrence(year: year), let candidate = c.date(byAdding: .day, value: -offset, to: occasion) else { continue }
                    let delivery = preferences.deliveryDate(candidate)
                    guard delivery > now else { continue }
                    let body = offset == 0 ? "Hoje é aniversário de \(birthday.name)." : "Aniversário de \(birthday.name) em \(offset) dia(s), dia \(String(format: "%02d/%02d", birthday.day, birthday.month))."
                    result.append(PlannedReminder(id: "sl-task-birthday-\(birthday.id)-\(offset)", taskID: "birthday:" + birthday.id, title: "Aniversário · " + birthday.name, body: body, date: delivery))
                    break
                }
            }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
