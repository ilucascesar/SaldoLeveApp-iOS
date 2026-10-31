import Foundation
import UserNotifications
import UIKit

@MainActor
final class NativeReminders: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private var queued: Task<Void, Never>?
    private let center = UNUserNotificationCenter.current()
    private var expenseRecords: [JSONObject] = []
    private var birthdays: [NativeBirthday]?
    private var places: [NativePlace] = []
    private var lastSnapshot = NativeSnapshot()
    override init() { super.init(); center.delegate = self }
    func enable(_ snapshot: NativeSnapshot) async throws -> Bool {
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        UserDefaults.standard.set(granted, forKey: "nativeLocalReminders")
        if granted { update(snapshot) }
        return granted
    }
    // Pausing comes from the app icon quick actions or from Notificações. The
    // alerts already scheduled are held back directly, so this works even
    // before the app reaches the server; the next rebuild applies the pause too.
    func pause(until date: Date?) {
        NativeAlertPause.set(date)
        NativeQuickActions.refresh()
        if let date { Task { await hold(until: date) } }
        else if !lastSnapshot.items.isEmpty { update(lastSnapshot) }
    }
    private func hold(until: Date) async {
        await queued?.value
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("sl-task-") }
        var later = Set<String>(), early: [(UNNotificationRequest, Date)] = []
        for request in pending {
            guard let trigger = request.trigger as? UNTimeIntervalNotificationTrigger, let next = trigger.nextTriggerDate() else { continue }
            if next >= until { later.insert(request.content.threadIdentifier) } else { early.append((request, next)) }
        }
        center.removePendingNotificationRequests(withIdentifiers: early.map(\.0.identifier))
        var moved = Set<String>()
        for (request, _) in early.sorted(by: { $0.1 < $1.1 }) where !later.contains(request.content.threadIdentifier) && moved.insert(request.content.threadIdentifier).inserted {
            try? await center.add(UNNotificationRequest(identifier: request.identifier, content: request.content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, until.timeIntervalSinceNow), repeats: false)))
        }
    }
    func update(_ snapshot: NativeSnapshot, expenseRecords: [JSONObject]? = nil, birthdays: [NativeBirthday]? = nil, places: [NativePlace]? = nil) {
        if let expenseRecords { self.expenseRecords = expenseRecords }
        if let birthdays { self.birthdays = birthdays }
        if let places { self.places = places }
        lastSnapshot = snapshot
        queued?.cancel()
        let preceding = queued
        queued = Task { [weak self] in
            await preceding?.value
            guard let self, !Task.isCancelled else { return }
            let existing = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            let preserveBirthdays = self.birthdays == nil && UserDefaults.standard.bool(forKey: "nativeLocalReminders")
            let preservedBirthdayCount = preserveBirthdays ? existing.filter { $0.identifier.hasPrefix("sl-task-birthday-") }.count : 0
            center.removePendingNotificationRequests(withIdentifiers: existing.filter { $0.identifier.hasPrefix("sl-task-") && !(preserveBirthdays && $0.identifier.hasPrefix("sl-task-birthday-")) }.map(\.identifier))
            let preferences = NativeNotificationPreferences.read()
            if !preferences.badge || !UserDefaults.standard.bool(forKey: "nativeLocalReminders") { UIApplication.shared.applicationIconBadgeNumber = 0 }
            guard UserDefaults.standard.bool(forKey: "nativeLocalReminders") else { return }
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus), !Task.isCancelled else { return }
            let now = Date()
            let expenses = self.expenseRecords, birthdayRecords = self.birthdays ?? []
            // Location alerts share the iOS limit of 64 pending requests.
            let locations = NativeLocationAccess.allowed && preferences.tasks ? NativeLocationReminder.groups(snapshot, places: self.places) : []
            let pause = NativeAlertPause.until(now: now)
            let computation = await Task.detached(priority: .utility) {
                let dueDates = snapshot.items.filter { $0.isActive && !$0.paused }.compactMap(\.nextDate).sorted()
                let all = NativeAlertPause.filter(NativeReminderPlan.build(snapshot, now: now, preferences: preferences) + NativeExpenseReminderPlan.build(expenses, now: now, preferences: preferences), until: pause)
                let birthdayAlarms = Array(NativeAlertPause.filter(NativeBirthdayPlan.build(birthdayRecords, now: now, preferences: preferences), until: pause).prefix(20))
                let otherAlarms = Array(all.sorted(by: { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }).prefix(max(0, 60 - locations.count - birthdayAlarms.count - preservedBirthdayCount)))
                let alarms = (birthdayAlarms + otherAlarms).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
                return (dueDates, alarms)
            }.value
            guard !Task.isCancelled else { return }
            for group in locations {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                let verb = group.trigger == "leave" ? "Ao sair de " : "Ao chegar em "
                content.title = preferences.showDetails ? verb + group.place.name : "SaldoLeve"
                content.body = preferences.showDetails ? (group.titles.count == 1 ? group.titles[0] : "\(group.titles.count) tarefas: " + group.titles.prefix(4).joined(separator: ", ") + (group.titles.count > 4 ? "…" : "")) : "Você tem um lembrete por local. Abra o app para consultar."
                content.sound = preferences.sound ? .default : nil
                content.threadIdentifier = "sl-task-location"
                content.userInfo = ["taskID": group.taskIDs.count == 1 ? group.taskIDs[0] : ""]
                try? await center.add(UNNotificationRequest(identifier: "sl-task-location-\(group.place.id)-\(group.trigger)", content: content, trigger: NativeLocationAccess.trigger(group)))
            }
            if preferences.badge { UIApplication.shared.applicationIconBadgeNumber = computation.0.prefix { $0 <= now }.count }
            for reminder in computation.1 {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = preferences.showDetails ? reminder.title : "SaldoLeve"
                content.body = preferences.showDetails ? reminder.body : "Você tem um lembrete. Abra o app para consultar."
                content.sound = preferences.sound ? .default : nil
                content.threadIdentifier = "sl-task-" + reminder.taskID
                if preferences.badge { content.badge = NSNumber(value: computation.0.prefix { $0 <= reminder.date }.count) }
                content.userInfo = ["taskID": reminder.taskID]
                let interval = max(1, reminder.date.timeIntervalSinceNow)
                try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content,
                                                           trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
            }
        }
    }
    func permission() async -> UNNotificationSettings { await center.notificationSettings() }
    func pendingCount() async -> Int { await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("sl-task-") }.count }
    func birthdayPendingCount() async -> Int { await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("sl-task-birthday-") }.count }
    func test() async throws {
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { throw NativeFailure("Permita notificações nos Ajustes do iPhone antes de testar.") }
        let preferences = NativeNotificationPreferences.read()
        let content = UNMutableNotificationContent()
        content.title = "SaldoLeve"; content.body = "Suas notificações estão autorizadas neste iPhone."
        content.sound = preferences.sound ? .default : nil
        try await center.add(UNNotificationRequest(identifier: "sl-notification-test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }
    func clear(disable: Bool = true) {
        if disable { UserDefaults.standard.set(false, forKey: "nativeLocalReminders") }
        update(NativeSnapshot(), expenseRecords: [], birthdays: [])
        center.removeAllDeliveredNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let preferences = NativeNotificationPreferences.read()
        var options: UNNotificationPresentationOptions = []
        if preferences.showWhileOpen { options.insert(.banner); options.insert(.list); if preferences.sound { options.insert(.sound) } }
        completionHandler(options)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["taskID"] as? String
        Task { @MainActor [weak self] in if let id { self?.onOpen?(id) }; completionHandler() }
    }
}
