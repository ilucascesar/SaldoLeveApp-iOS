import SwiftUI
import LocalAuthentication
import UIKit
import Network

@MainActor
final class NativeStore: ObservableObject {
    @Published var user: NativeIdentity?
    @Published var snapshot = NativeSnapshot()
    private var confirmedSnapshot = NativeSnapshot()
    private var unlockedCategories: [String: String] = [:]
    private var categoryAccessGeneration = UUID()
    private var protectionUpdate = UUID()
    @Published private(set) var taskIndex = NativeTaskIndex()
    @Published private(set) var networkAvailable = true
    private let pathMonitor = NWPathMonitor()
    // "loading" covers the screen only when there is no saved copy to show;
    // "starting" stays true until the first answer of the server.
    @Published var loading = true
    @Published private(set) var starting = true
    @Published var refreshing = false
    @Published var working = false
    @Published var offline = false
    @Published var needsSync = true
    // True only after a request to the server actually failed. While the first
    // refresh is still running the app shows "Atualizando", not "Sem conexão".
    @Published var connectionProblem = false
    @Published var requiresPasswordChange = false
    @Published var message: String?
    @Published var syncedAt: Date?
    @Published var openedTask: NativeTask?
    var paymentTaskID: String?
    @Published var locked = false
    let api: NativeAPI
    let reminders = NativeReminders()
    lazy var finance = NativeFinanceStore(parent: self)
    lazy var platform = NativePlatformStore(parent: self)
    @Published var section = NativeAppSection.tasks
    @Published var openedFinance: NativeFinanceRoute?
    @Published var expenseReminderIssue: String?
    @Published var layout = NativeLayoutPreferences.read() { didSet { layout.save() } }
    @Published var menuOpen = false
    @Published var taskDrawerRequested = false
    @Published var taskCategoryRequest: String?
    @Published var taskScopeRequest: String?
    private var previousUserID: String?
    var isPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-preview")
        #else
        return false
        #endif
    }
    #if DEBUG
    private var syncFixture: NativeTask?
    private var syncFixtureRejected = false
    @Published var syncFixtureWrites = 0
    #endif
    #if DEBUG
    func simulateServerUpdate() async {
        guard var remote = syncFixture else { return }
        remote.fields["title"] = .string("Atualização do computador")
        remote.fields["revision"] = .number(Double(remote.revision + 1))
        syncFixture = remote; await refresh()
    }
    #endif
    var editorSyncEnabled: Bool {
        #if DEBUG
        return !isPreview || syncFixture != nil
        #else
        return true
        #endif
    }
    func taskDetails(_ id: String) async throws -> JSONObject {
        #if DEBUG
        if let syncFixture { return ["item": .object(syncFixture.fields)] }
        if isPreview, let task = snapshot.items.first(where: { $0.id == id }) { return ["item": .object(task.fields)] }
        #endif
        let details = try await api.get(JSONObject.self, action: "org_item", query: ["id": id])
        guard !categoryLocked(details.record("item").text("listId")) else { throw NativeFailure("Desbloqueie a categoria para abrir a tarefa.") }
        return details
    }

    func categoryProtection(_ id: String) -> JSONObject { snapshot.preferences.record("categoryProtection").record(id) }
    var reminderSnapshot: NativeSnapshot {
        var source = confirmedSnapshot
        let protected = source.preferences.record("categoryProtection")
        guard !protected.isEmpty else { return snapshot }
        source.items = source.items.map { task in
            guard protected[task.categoryID] != nil else { return task }
            var generic = task
            generic.fields["title"] = .string("Tarefa protegida")
            generic.fields["checklist"] = .array(task.checks.map { check in
                var fields = check.fields
                fields["text"] = .string("Subtarefa protegida")
                return .object(fields)
            })
            return generic
        }
        return source
    }
    func categoryLocked(_ id: String) -> Bool {
        let revision = categoryProtection(id).text("revision")
        return !revision.isEmpty && unlockedCategories[id] != revision
    }
    func taskByID(_ id: String) -> NativeTask? { confirmedSnapshot.items.first { $0.id == id } ?? snapshot.items.first { $0.id == id } }
    func publishTasks(_ source: NativeSnapshot) {
        confirmedSnapshot = source
        let protections = source.preferences.record("categoryProtection")
        unlockedCategories = unlockedCategories.filter { protections.record($0.key).text("revision") == $0.value }
        let hidden = Set(protections.keys.filter { unlockedCategories[$0] != protections.record($0).text("revision") })
        var visible = source
        if !hidden.isEmpty {
            visible.items.removeAll { hidden.contains($0.categoryID) }
            visible.activity.removeAll { hidden.contains($0.text("listId")) }
        }
        taskIndex = NativeTaskIndex(visible, userID: user?.id ?? "")
        snapshot = visible
    }
    func unlockCategory(_ id: String, password: String = "") async throws {
        guard let userID = user?.id else { return }
        let protection = categoryProtection(id)
        let revision = protection.text("revision")
        guard !revision.isEmpty else { return }
        let generation = categoryAccessGeneration
        if protection.text("mode") == "password" {
            guard networkAvailable else { throw NativeFailure("Conecte-se para conferir a senha da categoria.") }
            _ = try await api.post(action: "org_category_protection", body: [
                "operation": .string("unlock"), "listId": .string(id), "revision": .string(revision), "currentPassword": .string(password)
            ])
        } else {
            try await Self.authenticateCategoryWithFaceID()
        }
        guard !Task.isCancelled, generation == categoryAccessGeneration, user?.id == userID,
              categoryProtection(id).text("revision") == revision, UIApplication.shared.applicationState != .background else { return }
        unlockedCategories[id] = revision
        publishTasks(confirmedSnapshot)
    }
    static func authenticateCategoryWithFaceID() async throws {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil), context.biometryType == .faceID else {
            throw NativeFailure("Ative o Face ID nos Ajustes do iPhone para usar esta opção.")
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Acessar a categoria protegida") else {
            throw NativeFailure("Não foi possível confirmar o Face ID.")
        }
    }
    func saveCategoryProtection(_ id: String, mode: String, revision: String, password: String, currentPassword: String) async throws {
        guard canWrite, let userID = user?.id else { throw NativeFailure("Atualize a conexão antes de alterar a proteção.") }
        working = true
        defer { working = false }
        let result = try await api.post(action: "org_category_protection", body: [
            "operation": .string("save"), "listId": .string(id), "mode": .string(mode), "revision": .string(revision),
            "password": .string(password), "currentPassword": .string(currentPassword)
        ])
        guard userID == user?.id else { throw NativeFailure("A conta mudou durante o salvamento.") }
        protectionUpdate = UUID()
        categoryAccessGeneration = UUID()
        var source = confirmedSnapshot
        var protections = source.preferences.record("categoryProtection")
        protections[id] = mode == "none" ? nil : .object(result)
        source.preferences["categoryProtection"] = .object(protections)
        unlockedCategories.removeValue(forKey: id)
        publishTasks(source)
        persist()
        await refreshExpenseReminders()
    }
    func relockCategories(_ id: String? = nil) {
        categoryAccessGeneration = UUID()
        if let id {
            guard unlockedCategories.removeValue(forKey: id) != nil else { return }
        } else {
            guard !unlockedCategories.isEmpty else { return }
            unlockedCategories.removeAll()
        }
        publishTasks(confirmedSnapshot)
    }

    init() {
        let configURL = Bundle.main.url(forResource: "config", withExtension: "json")!
        let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        let address = SiteAddress(config?["serverURL"] ?? "") ?? SiteAddress("https://tools.ilucas.com.br/SaldoLeveApp/sistema.php")!
        api = NativeAPI(address: address)
        api.reviewWarnings = { warnings in await NativeWarningPresenter.confirm(warnings) }
        api.reviewDuplicate = { names in
            await NativeWarningPresenter.decide(title: "Possível cobrança duplicada",
                message: "Já existe algo parecido em nome, valor e vencimento:\n\n" + names + "\n\nConfira antes de continuar.", accept: "Salvar mesmo assim")
        }
        section = NativeAppSection(key: layout.startPage)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reconnecting = !self.networkAvailable && available
                self.networkAvailable = available
                if !available { self.offline = true; self.needsSync = true; self.finance.needsSync = true }
                if reconnecting && self.user != nil && !self.isPreview { await self.refresh() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "SaldoLeve.connection"))
        reminders.onOpen = { [weak self] id in
            guard let self, user != nil else { return }
            if id.hasPrefix("birthday:") { openedFinance = .init(kind: "birthdays", fields: ["id": .string(String(id.dropFirst(9)))]); return }
            if id.hasPrefix("reminder:") { openedFinance = .init(kind: "generalReminders"); return }
            if id.hasPrefix("expense:") {
                section = .dashboard
                Task { await self.finance.refresh(); self.openedFinance = .init(kind: "detail", fields: ["id": .string(String(id.dropFirst(8)))]) }
                return
            }
            if let task = taskByID(id) { openedTask = task }
        }
    }
    // One store for the app and for Siri, so both share the session and the
    // data confirmed by the server.
    static let shared = NativeStore()
    private var startTask: Task<Void, Never>?
    func ensureStarted() async {
        if startTask == nil { startTask = Task { await start() } }
        await startTask?.value
    }
    var canWrite: Bool { user != nil && networkAvailable && !offline && !needsSync && !working }
    var editableCategories: [NativeCategory] { snapshot.lists.filter { $0.canEdit && !categoryLocked($0.id) } }
    func canEdit(_ task: NativeTask) -> Bool { canWrite && !categoryLocked(task.categoryID) && taskIndex.categories[task.categoryID]?.canEdit == true }
    func category(_ task: NativeTask) -> String { taskIndex.categories[task.categoryID]?.name ?? "Categoria" }
    func start() async {
        let id = api.storageID
        if let saved = await Task.detached(priority: .userInitiated, operation: { NativeCache.read(id) }).value {
            user = saved.user; previousUserID = saved.user.id; publishTasks(saved.snapshot)
            syncedAt = saved.syncedAt; offline = true
            // Rewrite the legacy cache immediately, without local drafts.
            persist()
            locked = UserDefaults.standard.bool(forKey: "nativeBiometrics")
            // The last confirmed data appears at once (read-only) while the
            // server answers, instead of the "Preparando" screen.
            loading = false
        }
        defer { loading = false; starting = false }
        do {
            let session = try await api.restore()
            apply(session)
            if session.authenticated { await refresh() }
        } catch {
            offline = true; needsSync = true; connectionProblem = !NativeRequestError.isCancellation(error)
            if let e = error as? NativeFailure, [401, 428].contains(e.status) {
                user = nil; api.clearSession(); reminders.clear(disable: false)
                _ = try? await api.restore()
            }
            if user == nil { report(error) }
        }
    }
    private func apply(_ session: NativeSession) {
        requiresPasswordChange = session.requiresPasswordChange
        if let next = session.user, next.id != previousUserID {
            unlockedCategories.removeAll(); publishTasks(NativeSnapshot()); syncedAt = nil
            finance.reset(); platform.reset()
            NativeCache.remove(api.storageID); reminders.clear()
        }
        user = session.authenticated ? session.user : nil
        if !session.authenticated { reminders.clear(disable: false) }
        if let user { previousUserID = user.id }
    }
    func login(name: String, password: String) async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let session = try await api.login(user: name, password: password, changingPassword: requiresPasswordChange)
            apply(session)
            if session.authenticated { await refresh() }
        } catch {
            if let failure = error as? NativeFailure, failure.status == 419 { _ = try? await api.restore() }
            report(error)
        }
    }
    func changePassword(current: String, new: String, confirm: String) async throws {
        guard canWrite, let identity = user else { throw NativeFailure("Conecte-se ao servidor antes de trocar a senha.") }
        working = true; defer { working = false }
        _ = try await api.post(action: "change_password", body: ["current": .string(current), "new": .string(new), "confirm": .string(confirm)])
        do { let session = try await api.login(user: identity.login, password: new, changingPassword: false); apply(session); await refresh() }
        catch { api.clearSession(forgetDevice: true); user = nil; message = "Senha alterada. Entre novamente com a nova senha." }
    }
    func duplicate(_ source: NativeTask) async {
        guard canEdit(source) else { return }
        do { openedTask = try await save(NativeTaskCopy.make(source)) }
        catch { if (error as? NativeFailure)?.status != 499 { report(error) } }
    }
    func refresh() async {
        #if DEBUG
        if let syncFixture {
            snapshot.items = snapshot.items.map { $0.id == syncFixture.id ? syncFixture : $0 }
            taskIndex = NativeTaskIndex(snapshot, userID: user?.id ?? "")
            offline = false; needsSync = false; syncedAt = Date(); return
        }
        #endif
        guard let id = user?.id, !refreshing else { return }
        guard networkAvailable else { offline = true; needsSync = true; return }
        refreshing = true; defer { refreshing = false }
        let protectionAtStart = protectionUpdate
        do {
            let next = try await load(NativeSnapshot.self, action: "org_bootstrap")
            guard next.configured else { throw NativeFailure(next.message ?? "Atualize as tabelas de Tarefas na hospedagem.") }
            guard user?.id == id, protectionAtStart == protectionUpdate else { return }
            UserDefaults.standard.set(next.preferences.text("theme"), forKey: "nativeTheme")
            publishTasks(next); offline = false; needsSync = false; connectionProblem = false; syncedAt = Date()
            persist()
            await refreshExpenseReminders(); await refreshGeneralReminders(); await platform.refresh()
        } catch {
            if NativeRequestError.isCancellation(error) { return }
            offline = true; needsSync = true; connectionProblem = true
            if let e = error as? NativeFailure, [401, 428].contains(e.status) {
                user = nil; api.clearSession(); reminders.clear(disable: false)
            }
            // A dropped connection is already shown by the top banner; an alert
            // on every automatic refresh only interrupts. Server messages still show.
            if !Self.isConnectionError(error) { report(error) }
        }
    }
    // Right after the app returns from the background the first request often
    // fails with "connection lost"; one quick retry avoids a false offline state.
    private func load<T: Decodable>(_ type: T.Type, action: String) async throws -> T {
        do { return try await api.get(type, action: action) }
        catch {
            guard Self.isConnectionError(error), !NativeRequestError.isCancellation(error), networkAvailable else { throw error }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await api.get(type, action: action)
        }
    }
    static func isConnectionError(_ error: Error) -> Bool {
        error is URLError || (error as? NativeFailure).map { $0.status == 0 || $0.status >= 500 } == true
    }
    func refreshExpenseReminders() async {
        guard user != nil, !isPreview else { return }
        let userID = user?.id
        do {
            let response = try await api.get(JSONObject.self, action: "native_expense_reminders")
            guard user?.id == userID else { return }
            reminders.update(reminderSnapshot, expenseRecords: response.objects("items")); expenseReminderIssue = nil
        } catch {
            // Missing push tables or an older backend must not take Tarefas
            // offline. Explicitly clear stale expense alarms after this failure.
            reminders.update(reminderSnapshot, expenseRecords: [])
            expenseReminderIssue = "Lembretes de despesas indisponíveis: " + error.localizedDescription
        }
    }
    func refreshGeneralReminders() async {
        guard user != nil, !isPreview else { return }
        let userID = user?.id
        do {
            let response = try await api.get(JSONObject.self, action: "native_general_reminders")
            guard userID == user?.id else { return }
            reminders.update(reminderSnapshot, generalRecords: response.objects("items"))
        } catch { if userID == user?.id { reminders.update(reminderSnapshot, generalRecords: []) } }
    }
    @discardableResult
    func mutate(_ action: String, _ body: JSONObject) async throws -> JSONObject {
        guard canWrite else { throw NativeFailure("Sem conexão com o servidor. Conecte-se e atualize antes de salvar.") }
        working = true; defer { working = false }
        do {
            let response = try await api.post(action: action, body: body)
            needsSync = true
            await refresh()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return response
        } catch {
            if NativeRequestError.isCancellation(error) { needsSync = true }
            if let e = error as? NativeFailure, [401, 419, 428].contains(e.status) {
                user = nil; api.clearSession(); reminders.clear(disable: false)
            }
            noteConnectionFailure(error)
            throw error
        }
    }
    func noteConnectionFailure(_ error: Error) {
        guard !NativeRequestError.isCancellation(error) else { return }
        if !networkAvailable || Self.isConnectionError(error) {
            offline = true; needsSync = true; finance.needsSync = true; connectionProblem = true
        }
    }
    @discardableResult
    func save(_ task: NativeTask) async throws -> NativeTask {
        #if DEBUG
        if var latest = syncFixture {
            syncFixtureWrites += 1
            try await Task.sleep(nanoseconds: 150_000_000)
            if !syncFixtureRejected {
                syncFixtureRejected = true; latest.fields["revision"] = .number(Double(latest.revision + 1))
                latest.fields["body"] = .string("Atualização durante o salvamento")
                syncFixture = latest; throw NativeFailure("Conflict fixture", status: 409)
            }
            guard task.revision == latest.revision else { throw NativeFailure("Conflict fixture", status: 409) }
            var canonical = task; canonical.fields["revision"] = .number(Double(latest.revision + 1))
            syncFixture = canonical
            snapshot.items = snapshot.items.map { $0.id == task.id ? canonical : $0 }
            return canonical
        }
        #endif
        let result = try await mutate("org_save_item", task.fields)
        let id = result.text("id").isEmpty ? task.id : result.text("id")
        let canonical: NativeTask
        if let latest = snapshot.items.first(where: { $0.id == id }), !needsSync { canonical = latest }
        else {
            let details = try await api.get(JSONObject.self, action: "org_item", query: ["id": id])
            canonical = NativeTask(details["item"]?.object ?? task.fields)
        }
        persist()
        return canonical
    }
    func complete(_ task: NativeTask) async {
        if !task.isDone, let next = task.nextPendingCheck, task.usesManualPayment(next) {
            paymentTaskID = task.id; openedTask = task; return
        }
        if task.isMoney && !task.isDone && task.checks.isEmpty && task.fields["amountCents"]?.number == nil {
            message = "Informe o valor da pendência antes de registrar o pagamento."; return
        }
        do { _ = try await mutate("org_complete_item", ["id": .string(task.id), "revision": .number(Double(task.revision))]) }
        catch { report(error) }
    }
    func toggle(_ check: NativeCheck, task: NativeTask) async {
        var fields = task.fields
        fields["checklist"] = .array(task.checks.map { value in
            var copy = value.fields
            if value.id == check.id { copy["done"] = .bool(!value.done) }
            return .object(copy)
        })
        do { _ = try await mutate("org_save_item", fields) }
        catch { report(error) }
    }
    func changeStatus(_ task: NativeTask, to status: String) async {
        do {
            if status == "restore" {
                _ = try await mutate("org_restore_item", ["id": .string(task.id), "revision": .number(Double(task.revision))])
            } else {
                var fields = task.fields; fields["status"] = .string(status)
                _ = try await mutate("org_save_item", fields)
            }
        } catch { report(error) }
    }
    func postpone(_ task: NativeTask) async {
        var fields = task.fields
        if let pending = task.checks.filter({ !$0.done && !$0.paused }).min(by: { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }) {
            fields["checklist"] = .array(task.checks.map { check in
                var value = check.fields
                if check.id == pending.id {
                    value["remindAt"] = .string(NativeDate.iso(NativeDate.quarter(Calendar.current.date(byAdding: .day, value: 1, to: max(check.date ?? Date(), Date()))!)))
                }
                return .object(value)
            })
        } else {
            let date = NativeDate.parse(fields.text("dueAt")) ?? Date()
            fields["dueAt"] = .string(NativeDate.iso(NativeDate.quarter(Calendar.current.date(byAdding: .day, value: 1, to: max(date, Date()))!)))
        }
        do { _ = try await mutate("org_save_item", fields) }
        catch { report(error) }
    }
    func logout() async {
        guard !working else { return }
        working = true; defer { working = false }
        do { try await api.logout() }
        catch { report(error); return }
        NativeCache.remove(api.storageID)
        reminders.clear(); user = nil; previousUserID = nil; unlockedCategories.removeAll(); publishTasks(NativeSnapshot())
        finance.reset(); platform.reset(); openedFinance = nil; expenseReminderIssue = nil
        syncedAt = nil; offline = false; needsSync = true; connectionProblem = false; locked = false
    }
    func persist() {
        guard let user else { return }
        NativeCache.enqueue(NativeLocalData(user: user, snapshot: confirmedSnapshot, syncedAt: syncedAt), id: api.storageID) { [weak self] success in
            if !success && self?.user?.id == user.id { self?.message = "Não foi possível atualizar a cópia de consulta neste iPhone. Os dados confirmados permanecem no servidor." }
        }
    }
    func unlock() async {
        let context = LAContext()
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Acessar suas tarefas e comprovantes") { locked = false }
        } catch { message = "Não foi possível desbloquear o aplicativo." }
    }
    func report(_ error: Error) { message = error.localizedDescription }
    func reorder(_ ordered: [NativeTask]) async throws {
        // Revision checks still run for every item. Stop on a conflict so later
        // tasks are never silently reordered against stale data.
        for (index, task) in ordered.enumerated() {
            guard canEdit(task) else { throw NativeFailure("Sem permissão para reordenar esta tarefa.") }
            var copy = snapshot.items.first(where: { $0.id == task.id }) ?? task
            copy.fields["sortOrder"] = .number(Double(index * 10))
            _ = try await save(copy)
        }
    }
}

extension NativeStore {
    func loadPreview() {
        #if DEBUG
        layout = NativeLayoutPreferences(); section = .tasks
        let first = NativeCategory(["id": .string("1"), "name": .string("Pessoal"), "color": .string("#1f6feb"), "folder": .string(""), "ownerId": .string("preview"), "archived": .bool(false), "canEdit": .bool(true), "members": .array([])])
        let second = NativeCategory(["id": .string("2"), "name": .string("Trabalho"), "color": .string("#159a68"), "folder": .string("Projetos"), "ownerId": .string("preview"), "archived": .bool(false), "canEdit": .bool(true), "members": .array([])])
        var data = NativeSnapshot(); data.configured = true; data.lists = [first, second]
        let today = Calendar.current.startOfDay(for: Date())
        func date(_ days: Int, hour: Int = 0) -> String { NativeDate.iso(Calendar.current.date(byAdding: .hour, value: hour, to: Calendar.current.date(byAdding: .day, value: days, to: today)!)!) }
        func task(_ id: String, _ title: String, _ days: Int?, category: String = "1", body: String = "", pinned: Bool = false) -> NativeTask {
            var task = NativeTask.draft(categoryID: category)
            task.fields.merge(["id": .string(id), "title": .string(title), "body": .string(body), "revision": .number(1), "sortOrder": .number(Double(Int(id) ?? 0)), "pinned": .bool(pinned), "tags": .array([]), "createdAt": .string(date(0))]) { _, new in new }
            if let days { task.fields["dueAt"] = .string(date(days)) }; return task
        }
        var project = task("1", "Organizar a semana", 0, body: "Separar o que importa e deixar espaço para os imprevistos.", pinned: true)
        project.fields["tags"] = .array([.string("planejamento")])
        project.fields["checklist"] = .array([
            .object(["id": .string("c1"), "text": .string("Revisar os compromissos"), "done": .bool(true), "repeatMonthly": .bool(true)]),
            .object(["id": .string("c2"), "text": .string("Confirmar a consulta e separar os documentos"), "done": .bool(false), "remindAt": .string(date(0, hour: 14)), "repeatMonthly": .bool(true)]),
            .object(["id": .string("c3"), "text": .string("Planejar as próximas entregas"), "done": .bool(false), "remindAt": .string(date(1, hour: 9)), "repeatMonthly": .bool(true)])
        ])
        var bill = task("3", "Mensalidades da casa", 0)
        bill.fields["moneyMode"] = .string("pay"); bill.fields["amountCents"] = .number(34990); bill.fields["repeat"] = .object(["frequency": .string("monthly"), "interval": .number(1)])
        var done = task("9", "Enviar os documentos", 0, category: "2"); done.fields["status"] = .string("done")
        data.items = [project, task("2", "Renovar o seguro", -1), bill, task("4", "Revisar proposta do projeto", 0, category: "2", body: "Conferir os últimos ajustes antes da reunião."), task("5", "Buscar encomenda", 1), task("6", "Preparar apresentação", 3, category: "2"), task("7", "Ideias para a próxima viagem", nil), done]
        if ProcessInfo.processInfo.arguments.contains("--preview-payments") {
            var loan = task("8", "Financiamento do carro", nil)
            loan.fields["moneyMode"] = .string("pay")
            loan.fields["checklist"] = .array([1, 59, 60].map { number in .object(["id": .string("parcela" + String(number)), "text": .string("Parcela \(number)/60"), "done": .bool(false), "amountCents": .number(100000), "repeatMonthly": .bool(false), "remindAt": .string(date(number))]) })
            data.items.append(loan)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openedTask = loan }
        }
        data.preferences = ["theme": .string("blue"), "filters": .array([])]
        if ProcessInfo.processInfo.arguments.contains("--preview-sync") || ProcessInfo.processInfo.arguments.contains("--preview-sync-overlap") || ProcessInfo.processInfo.arguments.contains("--preview-server-save") || ProcessInfo.processInfo.arguments.contains("--preview-sync-live") {
            // Old local content is intentionally ignored; the server is authoritative.
            var latest = project; latest.fields["revision"] = .number(2); latest.fields["body"] = .string("Nota editada na web")
            if ProcessInfo.processInfo.arguments.contains("--preview-sync-overlap") { latest.fields["title"] = .string("Título editado na web") }
            syncFixtureRejected = ProcessInfo.processInfo.arguments.contains("--preview-server-save") || ProcessInfo.processInfo.arguments.contains("--preview-sync-live")
            syncFixture = latest; data.items = data.items.map { $0.id == project.id ? latest : $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openedTask = latest }
        }
        data.activity = [["id": .string("1"), "action": .string("completed"), "at": .string(date(0))]]
        data.users = [["id": .string("preview"), "name": .string("Lucas")]]
        if ProcessInfo.processInfo.arguments.contains("--ui-stress") {
            for number in 10...5000 {
                let category = number % 2 == 0 ? "1" : "2"
                let extra = task(String(number), "Tarefa de teste \(number)", number % 42, category: category)
                data.items.append(extra)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-columns4") { layout.cardColumns = 4 }
        user = NativeIdentity(id: "preview", name: "Lucas", login: "preview")
        taskIndex = NativeTaskIndex(data, userID: "preview"); snapshot = data; loading = false; starting = false; offline = false; needsSync = false; locked = false; syncedAt = Date()
        if ProcessInfo.processInfo.arguments.contains("--preview-current-offline") {
            var current = project; current.fields["title"] = .string("Versão atual no iPhone"); current.fields["revision"] = .number(2)
            offline = true; needsSync = true; connectionProblem = true
            snapshot.items = snapshot.items.map { $0.id == project.id ? current : $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openedTask = project }
        }
        UserDefaults.standard.set("light", forKey: "nativeAppearance")
        if ProcessInfo.processInfo.arguments.contains("--preview-editor") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openedTask = project } }
        #endif
    }
}
