import Foundation

struct NativeNotificationPreferences: Codable, Equatable {
    var tasks = true
    var expenses = true
    var subtasks = true
    var twoDaysBefore = true
    var oneDayBefore = true
    var atDueTime = true
    var repeatOverdue = true
    var sound = true
    var badge = true
    var showDetails = true
    var showWhileOpen = true
    var quietEnabled = true
    var quietStart = 23 * 60
    var quietEnd = 6 * 60
    var timezone = "America/Sao_Paulo"

    static let storageKey = "nativeNotificationPreferencesV1"
    static func read(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
    func deliveryDate(_ candidate: Date) -> Date {
        guard quietEnabled else { return candidate }
        let start = min(1439, max(0, quietStart)), end = min(1439, max(0, quietEnd))
        guard start != end else { return candidate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(identifier: "America/Sao_Paulo")!
        let minute = calendar.component(.hour, from: candidate) * 60 + calendar.component(.minute, from: candidate)
        let inside = start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
        guard inside else { return candidate }
        var day = calendar.startOfDay(for: candidate)
        if start > end && minute >= start { day = calendar.date(byAdding: .day, value: 1, to: day)! }
        return calendar.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: day) ?? candidate
    }
}

// A temporary pause chosen from the app icon or from Notificações. It only
// holds back this iPhone's local alerts; no task data is changed.
enum NativeAlertPause {
    static let storageKey = "nativeAlertsPausedUntil"
    static func until(_ defaults: UserDefaults = .standard, now: Date = Date()) -> Date? {
        let value = defaults.double(forKey: storageKey)
        guard value > 0 else { return nil }
        let date = Date(timeIntervalSince1970: value)
        return date > now ? date : nil
    }
    static func set(_ date: Date?, _ defaults: UserDefaults = .standard) {
        if let date { defaults.set(date.timeIntervalSince1970, forKey: storageKey) } else { defaults.removeObject(forKey: storageKey) }
    }
    static func forHours(_ hours: Double, now: Date = Date()) -> Date { now.addingTimeInterval(hours * 3600) }
    // Tomorrow at the end of the quiet period (or 07:00 without one).
    static func untilTomorrow(_ preferences: NativeNotificationPreferences, now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: preferences.timezone) ?? TimeZone(identifier: "America/Sao_Paulo")!
        let minute = preferences.quietEnabled && preferences.quietStart != preferences.quietEnd ? min(1439, max(0, preferences.quietEnd)) : 7 * 60
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: tomorrow) ?? tomorrow
    }
    // Alerts inside the pause are held back. An item whose only alerts fell
    // inside the pause gets one alert when it ends, so nothing is forgotten.
    static func filter(_ reminders: [PlannedReminder], until: Date?) -> [PlannedReminder] {
        guard let until else { return reminders }
        var result = reminders.filter { $0.date >= until }
        let later = Set(result.map(\.taskID))
        var moved = Set<String>()
        for reminder in reminders.sorted(by: { $0.date < $1.date }) where reminder.date < until && !later.contains(reminder.taskID) && moved.insert(reminder.taskID).inserted {
            result.append(PlannedReminder(id: reminder.id, taskID: reminder.taskID, title: reminder.title, body: reminder.body, date: until))
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
