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
