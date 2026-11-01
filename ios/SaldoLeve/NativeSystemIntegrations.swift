import SwiftUI
import UIKit
import AppIntents
import CoreLocation
import EventKit
import UserNotifications

// MARK: App icon quick actions (press and hold the SaldoLeve icon)

@MainActor final class NativeQuickActions: ObservableObject {
    static let shared = NativeQuickActions()
    // The action waits here until the app is loaded and unlocked.
    @Published var pending: String?
    static let newTask = "br.com.ilucascesar.saldoleve.new-task"
    static let pauseTwoHours = "br.com.ilucascesar.saldoleve.pause-2h"
    static let pauseTomorrow = "br.com.ilucascesar.saldoleve.pause-tomorrow"
    static let resume = "br.com.ilucascesar.saldoleve.resume"
    // The static items live in Info.plist; while alerts are paused, a dynamic
    // item offers to resume them.
    static func refresh() {
        guard let until = NativeAlertPause.until() else { UIApplication.shared.shortcutItems = []; return }
        let time = until.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "pt_BR")))
        UIApplication.shared.shortcutItems = [UIApplicationShortcutItem(type: resume, localizedTitle: "Retomar avisos", localizedSubtitle: "Suspensos até " + time, icon: UIApplicationShortcutIcon(systemImageName: "bell.and.waves.left.and.right"))]
    }
}

final class NativeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // iOS relaunches the app in the background when a saved place is crossed.
        NativeGeofence.shared.start()
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { Task { @MainActor in NativeQuickActions.shared.pending = item.type } }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = NativeSceneDelegate.self
        return configuration
    }
}

final class NativeSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in NativeQuickActions.shared.pending = shortcutItem.type; completionHandler(true) }
    }
}

// MARK: Siri ("E aí Siri, me lembre no SaldoLeve")

struct NativeCreateTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Criar tarefa no SaldoLeve"
    static var description = IntentDescription("Cria uma tarefa na sua conta com aviso no horário dito, por exemplo: tirar o lixo daqui a 2 horas.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun = false
    @Parameter(title: "Tarefa") var text: String?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        // Configurações → Siri e Atalhos: answer by voice (default) or type the
        // task in the app, which opens a new draft.
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            if NativeSiriPreferences.typing {
                if #available(iOS 17.0, *) {
                    throw needsToContinueInForegroundError(IntentDialog("Abra o SaldoLeve para escrever a tarefa.")) {
                        NativeQuickActions.shared.pending = NativeQuickActions.newTask
                    }
                }
            }
            throw $text.needsValueError(IntentDialog("O que devo lembrar, e quando?"))
        }
        let parsed = NativeSpokenReminder.parse(text)
        guard !parsed.title.isEmpty else { return .result(dialog: "Não entendi a tarefa. Tente de novo dizendo o que lembrar.") }
        let store = NativeStore.shared
        await store.ensureStarted()
        guard store.user != nil else { return .result(dialog: "Entre na sua conta no SaldoLeve para criar tarefas pela Siri.") }
        if !store.canWrite { await store.refresh() }
        guard store.canWrite else { return .result(dialog: "Sem conexão com o servidor. A tarefa não foi criada.") }
        guard let category = store.editableCategories.first?.id else { return .result(dialog: "Nenhuma categoria permite criar tarefas na sua conta.") }
        var task = NativeTask.draft(categoryID: category)
        task.fields["title"] = .string(parsed.title)
        if let due = parsed.due { task.fields["dueAt"] = .string(NativeDate.iso(due)) }
        do { _ = try await store.save(task) }
        catch { return .result(dialog: IntentDialog(stringLiteral: "A tarefa não foi salva. " + error.localizedDescription)) }
        // Only reached after the server confirmed the new task.
        guard let due = parsed.due else { return .result(dialog: IntentDialog(stringLiteral: "Pronto. Criei a tarefa “\(parsed.title)” sem horário.")) }
        let when = Calendar.current.isDateInToday(due) ? "hoje às " + due.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR")))
            : due.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(Locale(identifier: "pt_BR")))
        return .result(dialog: IntentDialog(stringLiteral: "Pronto. Vou avisar sobre “\(parsed.title)” \(when)."))
    }
}

@available(iOS 17.0, *)
extension NativeCreateTaskIntent: ForegroundContinuableIntent {}

// Answering Siri: by voice (default) or typing in the app.
enum NativeSiriPreferences {
    static let storageKey = "nativeSiriInput"
    static var typing: Bool { UserDefaults.standard.string(forKey: storageKey) == "type" }
}

// iOS requires the app name in App Shortcut phrases. To say only
// "criar tarefa", the user names a personal shortcut that runs this action
// (Configurações → Siri e Atalhos explains how).
@available(iOS 17.0, *)
struct NativeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NativeCreateTaskIntent(), phrases: [
            "Criar tarefa no \(.applicationName)",
            "Adicionar lembrete no \(.applicationName)",
            "Me lembre no \(.applicationName)",
            "Me lembre pelo \(.applicationName)",
            "Me avise pelo \(.applicationName)",
            "Adicionar tarefa no \(.applicationName)",
            "Nova tarefa no \(.applicationName)",
            "\(.applicationName) criar tarefa",
            "\(.applicationName) adicionar lembrete",
            "\(.applicationName) me lembre"
        ], shortTitle: "Criar tarefa", systemImageName: "checklist")
    }
}

// MARK: App Lembretes ("E aí Siri, me lembra de…")

// iOS sends "me lembra" to Apple's Reminders (SiriKit task apps need a paid
// developer account). Pending reminders of the chosen list become SaldoLeve
// tasks; each reminder is completed only after the server confirmed its task,
// so Lembretes stops alerting about it.
@MainActor final class NativeRemindersImport: ObservableObject {
    static let shared = NativeRemindersImport()
    static let enabledKey = "nativeRemindersImport"
    static let listKey = "nativeRemindersList"
    private static let importedKey = "nativeRemindersImported"
    let events = EKEventStore()
    @Published var status = EKEventStore.authorizationStatus(for: .reminder)
    @Published var lists: [EKCalendar] = []
    @Published var running = false
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var allowed: Bool {
        if #available(iOS 17.0, *) { return status == .fullAccess }
        return status == .authorized
    }
    func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) { _ = try? await events.requestFullAccessToReminders() }
        else { _ = try? await events.requestAccess(to: .reminder) }
        reload()
        return allowed
    }
    func reload() {
        status = EKEventStore.authorizationStatus(for: .reminder)
        lists = allowed ? events.calendars(for: .reminder).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : []
    }
    // The chosen list, or a "SaldoLeve" list created on first use.
    func list() throws -> EKCalendar {
        if let id = UserDefaults.standard.string(forKey: Self.listKey), let calendar = events.calendar(withIdentifier: id) { return calendar }
        let calendar: EKCalendar
        if let existing = events.calendars(for: .reminder).first(where: { $0.title == "SaldoLeve" }) { calendar = existing }
        else {
            guard let source = events.defaultCalendarForNewReminders()?.source ?? events.sources.first(where: { $0.sourceType == .local }) else {
                throw NativeFailure("Nenhuma conta disponível no app Lembretes.")
            }
            calendar = EKCalendar(for: .reminder, eventStore: events)
            calendar.title = "SaldoLeve"; calendar.source = source
            try events.saveCalendar(calendar, commit: true)
        }
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.listKey); reload()
        return calendar
    }
    static func due(_ reminder: EKReminder) -> Date? {
        if var parts = reminder.dueDateComponents {
            // A reminder for a day without a time is due at 9:00.
            if parts.hour == nil { parts.hour = 9; parts.minute = 0 }
            if let date = Calendar.current.date(from: parts) { return date }
        }
        return reminder.alarms?.compactMap(\.absoluteDate).min()
    }
    @discardableResult
    func run(_ store: NativeStore, manual: Bool = false) async -> Int {
        guard enabled, !running, !store.isPreview, store.user != nil, !store.locked else { return 0 }
        reload()
        guard allowed else { if manual { store.message = "Permita o acesso aos Lembretes nos Ajustes do iPhone." }; return 0 }
        guard store.canWrite else { if manual { store.message = "Sem conexão com o servidor. Nenhum lembrete foi importado." }; return 0 }
        guard let category = store.editableCategories.first?.id else { return 0 }
        let calendar: EKCalendar
        do { calendar = try list() } catch { if manual { store.report(error) }; return 0 }
        running = true; defer { running = false }
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        let pending: [EKReminder] = await withCheckedContinuation { continuation in
            _ = events.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        var imported = UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? []
        var count = 0
        for reminder in pending.sorted(by: { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }) {
            let id = reminder.calendarItemIdentifier
            let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !imported.contains(id) else { continue }
            var task = NativeTask.draft(categoryID: category)
            task.fields["title"] = .string(String(title.prefix(1)).uppercased() + String(title.dropFirst()))
            if let due = Self.due(reminder) { task.fields["dueAt"] = .string(NativeDate.iso(due)) }
            if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { task.fields["body"] = .string(notes) }
            do { _ = try await store.save(task) } catch { store.report(error); break }
            // Remembered before completing it, so a failure below never duplicates the task.
            imported.append(id); UserDefaults.standard.set(Array(imported.suffix(300)), forKey: Self.importedKey)
            reminder.isCompleted = true
            try? events.save(reminder, commit: true)
            count += 1
        }
        if count > 0 { store.message = count == 1 ? "1 lembrete do app Lembretes virou tarefa no SaldoLeve." : "\(count) lembretes do app Lembretes viraram tarefas no SaldoLeve." }
        else if manual && store.message == nil { store.message = "Nenhum lembrete pendente na lista “\(calendar.title)”." }
        return count
    }
}

// MARK: Location ("ao chegar" / "ao sair", with or without a date)

enum NativeLocationAccess {
    static var status: CLAuthorizationStatus { CLLocationManager().authorizationStatus }
    static var allowed: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(status) }
    static var always: Bool { status == .authorizedAlways }
    // With "Localização exata" off, iOS does not report arrivals or departures.
    static var precise: Bool { CLLocationManager().accuracyAuthorization == .fullAccuracy }
}

// The alert prepared for a place and direction, kept on the iPhone so it can
// be shown even when iOS wakes the app in the background without a network.
struct NativeGeofenceAlert: Codable, Equatable {
    var place: String
    var title: String
    var body: String
    var taskID: String
    var sound: Bool
    var content: UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = sound ? .default : nil
        content.threadIdentifier = "sl-task-location"; content.userInfo = ["taskID": taskID]
        return content
    }
    static func make(_ group: NativeLocationReminder.Group, preferences: NativeNotificationPreferences) -> NativeGeofenceAlert {
        let verb = group.trigger == "leave" ? "Ao sair de " : "Ao chegar em "
        let body = group.summary
        return NativeGeofenceAlert(place: group.place.name, title: preferences.showDetails ? verb + group.place.name : "SaldoLeve",
                                   body: preferences.showDetails ? body : "Você tem um lembrete por local. Abra o app para consultar.",
                                   taskID: group.taskIDs.count == 1 ? group.taskIDs[0] : "", sound: preferences.sound)
    }
}

// Arrive/leave alerts. With "Sempre", iOS wakes the app at each crossing
// (region monitoring, even with the app closed) and the alert is posted on
// the spot. With only "Durante o uso", the notification location triggers are
// the fallback. Regions are compared and only changed ones are registered
// again: re-registering on every sync reset their state and lost crossings.
@MainActor final class NativeGeofence: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = NativeGeofence()
    @Published private(set) var log: [String]
    @Published private(set) var monitored = 0
    private let manager = CLLocationManager()
    private static let alertsKey = "nativeGeofenceAlerts", logKey = "nativeGeofenceLog", lastKey = "nativeGeofenceLast"
    override init() {
        log = UserDefaults.standard.stringArray(forKey: Self.logKey) ?? []
        super.init()
        manager.delegate = self
        monitored = manager.monitoredRegions.filter { $0.identifier.hasPrefix("sl-place-") }.count
    }
    // Called at launch so a background relaunch for a crossing reaches the delegate.
    func start() {}
    private var alerts: [String: NativeGeofenceAlert] {
        UserDefaults.standard.data(forKey: Self.alertsKey).flatMap { try? JSONDecoder().decode([String: NativeGeofenceAlert].self, from: $0) } ?? [:]
    }
    func apply(_ groups: [NativeLocationReminder.Group], preferences: NativeNotificationPreferences) async {
        var prepared: [String: NativeGeofenceAlert] = [:]
        for group in groups { prepared[group.place.id + "-" + group.trigger] = NativeGeofenceAlert.make(group, preferences: preferences) }
        if let data = try? JSONEncoder().encode(prepared) { UserDefaults.standard.set(data, forKey: Self.alertsKey) }
        let monitoring = NativeLocationAccess.always && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        syncRegions(monitoring ? groups : [])
        await syncSystemTriggers(monitoring || !NativeLocationAccess.allowed ? [] : groups, alerts: prepared)
    }
    private func circle(_ place: NativePlace, id: String) -> CLCircularRegion {
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), radius: min(place.radius, manager.maximumRegionMonitoringDistance), identifier: id)
        region.notifyOnEntry = false; region.notifyOnExit = false
        return region
    }
    private static func same(_ a: CLCircularRegion, _ b: CLCircularRegion) -> Bool {
        abs(a.center.latitude - b.center.latitude) < 0.000001 && abs(a.center.longitude - b.center.longitude) < 0.000001
            && abs(a.radius - b.radius) < 0.5 && a.notifyOnEntry == b.notifyOnEntry && a.notifyOnExit == b.notifyOnExit
    }
    private func syncRegions(_ groups: [NativeLocationReminder.Group]) {
        var wanted: [String: CLCircularRegion] = [:]
        for group in groups {
            let id = "sl-place-" + group.place.id
            let region = wanted[id] ?? circle(group.place, id: id)
            if group.trigger == "leave" { region.notifyOnExit = true } else { region.notifyOnEntry = true }
            wanted[id] = region
        }
        for case let current as CLCircularRegion in manager.monitoredRegions where current.identifier.hasPrefix("sl-place-") {
            if let next = wanted[current.identifier], Self.same(current, next) { wanted[current.identifier] = nil }
            else { manager.stopMonitoring(for: current) }
        }
        for region in wanted.values { manager.startMonitoring(for: region) }
        monitored = Set(groups.map(\.place.id)).count
    }
    private func syncSystemTriggers(_ groups: [NativeLocationReminder.Group], alerts: [String: NativeGeofenceAlert]) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("sl-task-location-") }
        var keep = Set<String>()
        for group in groups {
            let key = group.place.id + "-" + group.trigger, id = "sl-task-location-" + key
            guard let alert = alerts[key] else { continue }
            keep.insert(id)
            let region = circle(group.place, id: "sl-place-" + key)
            region.notifyOnEntry = group.trigger == "arrive"; region.notifyOnExit = group.trigger == "leave"
            if let old = existing.first(where: { $0.identifier == id }), let oldRegion = (old.trigger as? UNLocationNotificationTrigger)?.region as? CLCircularRegion,
               Self.same(oldRegion, region), old.content.title == alert.title, old.content.body == alert.body, (old.content.sound != nil) == alert.sound { continue }
            // Repeats while the tasks stay pending: every arrival (or departure) warns.
            try? await center.add(UNNotificationRequest(identifier: id, content: alert.content, trigger: UNLocationNotificationTrigger(region: region, repeats: true)))
        }
        let stale = existing.map(\.identifier).filter { !keep.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
    }
    // A crossing reported by iOS, or a test from Configurações → Locais. The
    // test goes through the same path and arrives 5 seconds later, so the
    // iPhone can be locked to see it as a real alert.
    @discardableResult
    func fire(placeID: String, trigger: String, placeName: String? = nil, simulated: Bool = false) async -> String {
        let key = placeID + "-" + trigger
        let alert = alerts[key]
        let name = placeName ?? alert?.place ?? "local salvo"
        let event = (trigger == "leave" ? "Saiu de " : "Chegou em ") + name + (simulated ? " (teste)" : "")
        var last = UserDefaults.standard.dictionary(forKey: Self.lastKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        // GPS jitter at the edge can report the same crossing twice in a row.
        if !simulated, now - (last[key] ?? 0) < 180 { note(event + " · repetido em menos de 3 min, ignorado"); return event }
        last[key] = now; UserDefaults.standard.set(last, forKey: Self.lastKey)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard UserDefaults.standard.bool(forKey: "nativeLocalReminders"), [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            let result = event + " · notificações do SaldoLeve desativadas"; note(result); return result
        }
        let content: NativeGeofenceAlert
        if let alert { content = alert }
        else if simulated { content = NativeGeofenceAlert(place: name, title: (trigger == "leave" ? "Ao sair de " : "Ao chegar em ") + name, body: "Teste: nenhuma tarefa deste local tem subtarefas pendentes, então um aviso real não seria enviado.", taskID: "", sound: true) }
        else { let result = event + " · nenhuma subtarefa pendente, sem aviso"; note(result); return result }
        do {
            try await center.add(UNNotificationRequest(identifier: "sl-location-event-" + key + (simulated ? "-test" : ""), content: content.content,
                                                       trigger: simulated ? UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false) : nil))
            let result = event + " · aviso: " + content.body; note(result); return result
        } catch { let result = event + " · falha ao avisar: " + error.localizedDescription; note(result); return result }
    }
    private func note(_ text: String) {
        let stamp = Date().formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute().locale(Locale(identifier: "pt_BR")))
        log = Array(([stamp + " · " + text] + log).prefix(30))
        UserDefaults.standard.set(log, forKey: Self.logKey)
    }
    func clearLog() { log = []; UserDefaults.standard.removeObject(forKey: Self.logKey) }
    private func handle(_ identifier: String, trigger: String) {
        guard identifier.hasPrefix("sl-place-") else { return }
        let placeID = String(identifier.dropFirst("sl-place-".count))
        // iOS gives a few seconds in the background; ask for the time to post the alert.
        let background = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task { await fire(placeID: placeID, trigger: trigger); if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.handle(id, trigger: "arrive") }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.handle(id, trigger: "leave") }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let placeID = String((region?.identifier ?? "").dropFirst("sl-place-".count)), reason = error.localizedDescription
        Task { @MainActor in
            let alerts = self.alerts
            self.note("Falha ao monitorar " + (alerts[placeID + "-arrive"]?.place ?? alerts[placeID + "-leave"]?.place ?? "local") + ": " + reason)
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // "Sempre" granted or removed: switch between monitoring and the fallback.
        Task { @MainActor in NotificationCenter.default.post(name: .nativeLocationAuthorizationChanged, object: nil) }
    }
}

extension Notification.Name { static let nativeLocationAuthorizationChanged = Notification.Name("nativeLocationAuthorizationChanged") }

@MainActor final class NativeLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var status: CLAuthorizationStatus
    @Published var precise: Bool
    @Published var location: CLLocation?
    @Published var locating = false
    @Published var issue: String?
    private let manager: CLLocationManager
    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        status = manager.authorizationStatus; precise = manager.accuracyAuthorization == .fullAccuracy
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }
    var allowed: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(status) }
    var always: Bool { status == .authorizedAlways }
    func request() { manager.requestWhenInUseAuthorization() }
    // iOS shows the "Alterar para Sempre" prompt only once; afterwards only Ajustes can change it.
    func requestAlways() {
        let key = "nativeLocationAlwaysAsked"
        if status == .notDetermined || (status == .authorizedWhenInUse && !UserDefaults.standard.bool(forKey: key)) {
            UserDefaults.standard.set(true, forKey: key); manager.requestAlwaysAuthorization()
        } else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    func locate() {
        issue = nil
        if status == .notDetermined { request(); return }
        guard allowed else { issue = "Permita a localização Durante o uso nos Ajustes do iPhone."; return }
        locating = true; manager.requestLocation()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus, precise = manager.accuracyAuthorization == .fullAccuracy
        Task { @MainActor in self.status = status; self.precise = precise }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.location = last; self.locating = false }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locating = false; self.issue = "Não foi possível obter a localização atual. " + error.localizedDescription }
    }
}
