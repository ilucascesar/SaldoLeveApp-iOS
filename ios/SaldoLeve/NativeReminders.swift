import Foundation
import UserNotifications
import UIKit

@MainActor
final class NativeReminders: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String, String?) -> Void)?
    private var queued: Task<Void, Never>?
    private let center = UNUserNotificationCenter.current()
    private var expenseRecords: [JSONObject] = []
    private var birthdays: [NativeBirthday]?
    // nil until the account's places arrive: the saved regions stay as they are
    // instead of being dropped and registered again on every launch.
    private var places: [NativePlace]?
    private var lastSnapshot = NativeSnapshot()
    override init() {
        super.init(); center.delegate = self
        NativeReminderActions.register(center)
        NotificationCenter.default.addObserver(forName: .nativeLocationAuthorizationChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, self.places != nil else { return }; self.update(self.lastSnapshot) }
        }
    }
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
    private var generalRecords: [JSONObject] = []
    func update(_ snapshot: NativeSnapshot, expenseRecords: [JSONObject]? = nil, birthdays: [NativeBirthday]? = nil, places: [NativePlace]? = nil, generalRecords: [JSONObject]? = nil) {
        if let generalRecords { self.generalRecords = generalRecords }
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
            // Location alerts are compared and kept (NativeGeofence), not rebuilt here.
            center.removePendingNotificationRequests(withIdentifiers: existing.filter { $0.identifier.hasPrefix("sl-task-") && !$0.identifier.hasPrefix("sl-task-location-") && !(preserveBirthdays && $0.identifier.hasPrefix("sl-task-birthday-")) }.map(\.identifier))
            let preferences = NativeNotificationPreferences.read()
            if !preferences.badge || !UserDefaults.standard.bool(forKey: "nativeLocalReminders") { UIApplication.shared.applicationIconBadgeNumber = 0 }
            let settings = await center.notificationSettings()
            let authorized = UserDefaults.standard.bool(forKey: "nativeLocalReminders") && [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            // Arrive/leave alerts do not depend on a date: any pending task with a place counts.
            let locations = authorized && preferences.tasks ? NativeLocationReminder.groups(snapshot, places: self.places ?? []) : []
            if self.places != nil, !Task.isCancelled { await NativeGeofence.shared.apply(locations, preferences: preferences) }
            guard authorized, !Task.isCancelled else { return }
            let now = Date()
            let expenses = self.expenseRecords, birthdayRecords = self.birthdays ?? [], general = self.generalRecords
            // With only "Durante o uso", location alerts share the iOS limit of 64 pending requests.
            let pause = NativeAlertPause.until(now: now)
            let computation = await Task.detached(priority: .utility) {
                let dueDates = snapshot.items.filter { $0.isActive && !$0.paused }.compactMap(\.nextDate).sorted()
                let all = NativeAlertPause.filter(NativeReminderPlan.build(snapshot, now: now, preferences: preferences) + NativeExpenseReminderPlan.build(expenses, now: now, preferences: preferences) + NativeStandaloneReminderPlan.build(general, now: now, preferences: preferences), until: pause)
                let birthdayAlarms = Array(NativeAlertPause.filter(NativeBirthdayPlan.build(birthdayRecords, now: now, preferences: preferences), until: pause).prefix(20))
                let otherAlarms = NativeReminderPlan.select(all, limit: max(0, 60 - locations.count - birthdayAlarms.count - preservedBirthdayCount))
                let alarms = (birthdayAlarms + otherAlarms).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
                return (dueDates, alarms)
            }.value
            guard !Task.isCancelled else { return }
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
                content.categoryIdentifier = NativeReminderActions.category(for: reminder.taskID)
                if let checkID = reminder.checkID { content.userInfo["checkID"] = checkID }
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
        update(NativeSnapshot(), expenseRecords: [], birthdays: [], places: [], generalRecords: [])
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
        let checkID = response.notification.request.content.userInfo["checkID"] as? String
        let action = response.actionIdentifier
        if let delay = NativeReminderActions.snoozeDate(for: action) {
            // Adiar: o mesmo aviso volta no horário escolhido. O prefixo é outro
            // (sl-snooze-) para a reconstrução dos avisos não apagá-lo.
            let content = (response.notification.request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
            content.badge = nil
            let request = UNNotificationRequest(identifier: "sl-snooze-" + UUID().uuidString, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(60, delay.timeIntervalSinceNow), repeats: false))
            center.add(request) { _ in completionHandler() }
            return
        }
        if action == NativeReminderActions.done, let id {
            Task { @MainActor in await NativeReminderActions.markDone(taskID: id, checkID: checkID); completionHandler() }
            return
        }
        guard action == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        Task { @MainActor [weak self] in if let id { self?.onOpen?(id,checkID) }; completionHandler() }
    }
}

// Ações ao segurar ou arrastar um aviso para baixo: adiar ou marcar como feito.
enum NativeReminderActions {
    static let taskCategory = "sl.reminder.task", snoozeCategory = "sl.reminder.snooze"
    static let done = "sl.action.done"
    static func category(for taskID: String) -> String {
        taskID.isEmpty || taskID.contains(":") ? snoozeCategory : taskCategory
    }
    // As opções vêm de Opções de adiar do aviso (até 5, escolhidas pelo usuário).
    static func register(_ center: UNUserNotificationCenter) {
        let snooze = NativeSnoozeStore.read().map { UNNotificationAction(identifier: $0.actionID, title: $0.title, options: []) }
        let finished = UNNotificationAction(identifier: done, title: "Marcar como feito", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: taskCategory, actions: [finished] + snooze, intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: snoozeCategory, actions: snooze, intentIdentifiers: [], options: [])
        ])
    }
    static func snoozeDate(for action: String, now: Date = Date()) -> Date? {
        if let option = NativeSnoozeOption.parse(action: action) { return option.fireDate(from: now) }
        // Botões de avisos já entregues pela 1.0.6.
        let legacy: [String: NativeSnoozeOption] = ["sl.action.snooze2": .init(amount: 2, unit: .hours), "sl.action.snooze4": .init(amount: 4, unit: .hours),
                                                    "sl.action.snooze6": .init(amount: 6, unit: .hours), "sl.action.snooze8": .init(amount: 8, unit: .hours),
                                                    "sl.action.tomorrow": .init(amount: 1, unit: .days)]
        return legacy[action]?.fireDate(from: now)
    }
    @MainActor static func markDone(taskID: String, checkID: String?) async {
        let store = NativeStore.shared
        await store.ensureStarted()
        guard store.user != nil else { return await warn("Entre na sua conta no SaldoLeve para concluir pelo aviso.") }
        if !store.canWrite { await store.refresh() }
        guard store.canWrite, let task = store.taskByID(taskID) else { return await warn("Sem conexão com o servidor. Abra o app para concluir.") }
        if let checkID, let check = task.checks.first(where: { $0.id == checkID }) {
            if !check.done { await store.toggle(check, task: task) }
            if store.taskByID(taskID)?.checks.first(where: { $0.id == checkID })?.done != true { await warn("Não deu para concluir daqui. Abra o app para concluir.") }
        } else if !task.isDone {
            await store.complete(task)
            if store.taskByID(taskID)?.isDone != true { await warn("Não deu para concluir daqui (talvez peça um valor ou senha). Abra o app.") }
        }
    }
    private static func warn(_ text: String) async {
        let content = UNMutableNotificationContent()
        content.title = "SaldoLeve"; content.body = text; content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sl-action-warning", content: content,
                                                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }
}
