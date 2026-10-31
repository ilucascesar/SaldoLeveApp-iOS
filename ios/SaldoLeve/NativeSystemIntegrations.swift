import SwiftUI
import UIKit
import AppIntents
import CoreLocation
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
    @Parameter(title: "Tarefa", requestValueDialog: IntentDialog("O que devo lembrar, e quando?")) var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
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
struct NativeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NativeCreateTaskIntent(), phrases: [
            "Me lembre no \(.applicationName)",
            "Me avise pelo \(.applicationName)",
            "Criar tarefa no \(.applicationName)",
            "Nova tarefa no \(.applicationName)",
            "Lembrete no \(.applicationName)"
        ], shortTitle: "Nova tarefa", systemImageName: "checklist")
    }
}

// MARK: Location ("Durante o uso" is enough for arrive/leave notifications)

enum NativeLocationAccess {
    static var allowed: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(CLLocationManager().authorizationStatus) }
    static func trigger(_ group: NativeLocationReminder.Group) -> UNLocationNotificationTrigger {
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: group.place.latitude, longitude: group.place.longitude), radius: group.place.radius, identifier: "sl-place-" + group.place.id + "-" + group.trigger)
        region.notifyOnEntry = group.trigger == "arrive"; region.notifyOnExit = group.trigger == "leave"
        // Repeats while the tasks stay pending: every arrival (or departure) warns.
        return UNLocationNotificationTrigger(region: region, repeats: true)
    }
}

@MainActor final class NativeLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var status: CLAuthorizationStatus
    @Published var location: CLLocation?
    @Published var locating = false
    @Published var issue: String?
    private let manager: CLLocationManager
    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        status = manager.authorizationStatus
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }
    var allowed: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(status) }
    func request() { manager.requestWhenInUseAuthorization() }
    func locate() {
        issue = nil
        if status == .notDetermined { request(); return }
        guard allowed else { issue = "Permita a localização Durante o uso nos Ajustes do iPhone."; return }
        locating = true; manager.requestLocation()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.location = last; self.locating = false }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locating = false; self.issue = "Não foi possível obter a localização atual. " + error.localizedDescription }
    }
}
