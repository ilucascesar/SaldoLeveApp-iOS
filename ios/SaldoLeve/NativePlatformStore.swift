import SwiftUI
import CryptoKit

@MainActor final class NativePlatformStore: ObservableObject {
    unowned let parent: NativeStore
    @Published var snapshot = NativePlatformSnapshot()
    @Published var loading = false
    @Published var saving = false
    @Published var loaded = false
    @Published var issue: String?
    init(parent: NativeStore) { self.parent = parent }
    static let menu = ["dashboard", "expenses", "tasks", "birthdays", "search", "transactions", "shared", "focus", "layout", "remote", "widgets", "notifications", "profile"]
    static let settingsMenuKeys: Set<String> = ["layout", "remote", "widgets", "notifications", "profile"]
    static var navigationMenu: [String] { menu.filter { !settingsMenuKeys.contains($0) } }
    static let labels = ["dashboard":"Visão geral", "expenses":"Despesas", "tasks":"Tarefas", "birthdays":"Aniversariantes", "search":"Busca geral", "transactions":"Lançamentos", "shared":"Compartilhados", "focus":"Meu dia", "layout":"Layout e personalização", "remote":"Configurar aplicativo", "widgets":"Widgets", "notifications":"Notificações e contador", "profile":"Minha conta"]
    var canWrite: Bool { loaded && parent.canWrite && !loading && !saving }
    func label(_ key: String) -> String {
        let label = snapshot.config.record("labels").text(key)
        if key == "dashboard", label.isEmpty || label == "Visão geral" { return "Despesas" }
        if key == "tasks", label.isEmpty || label == "Tarefas" { return "Agenda" }
        return label.isEmpty ? Self.labels[key] ?? key : label
    }
    func text(_ key: String, fallback: String) -> String { let value = snapshot.config.record("texts").text(key); return value.isEmpty ? fallback : value }
    func enabled(_ key: String) -> Bool { snapshot.config.record("features")[key] != .bool(false) }
    var visibleMenu: [String] {
        let supplied = snapshot.config["menuOrder"]?.array.map(\.string) ?? []
        let hidden = Set(snapshot.config["hiddenMenu"]?.array.map(\.string) ?? [])
        var seen = Set<String>()
        return (supplied + Self.menu).filter { $0 != "expenses" && Self.menu.contains($0) && seen.insert($0).inserted && (!hidden.contains($0) || ["dashboard", "tasks", "remote", "profile"].contains($0)) && (!["birthdays", "search"].contains($0) || enabled($0)) }
    }
    func reset() { snapshot = NativePlatformSnapshot(); loaded = false; issue = nil }
    func refresh() async {
        guard parent.user != nil, parent.networkAvailable, !parent.offline, !loading else { return }
        #if DEBUG
        if parent.isPreview { if !loaded { preview() }; return }
        #endif
        loading = true; defer { loading = false }
        let userID = parent.user?.id
        do {
            let next = try await parent.api.get(NativePlatformSnapshot.self, action: "platform_bootstrap")
            guard parent.user?.id == userID else { return }
            snapshot = next; loaded = true; issue = nil; applyRemoteLayout()
            parent.reminders.update(parent.snapshot, birthdays: enabled("birthdays") ? next.birthdays : [], places: NativePlace.list(next.config))
            parent.objectWillChange.send()
            if !contactsSyncing { Task { await syncContactsIfNeeded() } }
        } catch { guard !NativeRequestError.isCancellation(error) else { return }; parent.noteConnectionFailure(error); issue = "Não foi possível atualizar os novos recursos. Confira a atualização da HostGator. " + error.localizedDescription }
    }
    private func applyRemoteLayout() {
        let changes = snapshot.config.record("layout")
        guard !changes.isEmpty, let encoded = try? JSONEncoder().encode(parent.layout), var base = try? JSONDecoder().decode(JSONObject.self, from: encoded) else { return }
        for (key, value) in changes { base[key] = value }
        guard let bytes = try? JSONEncoder().encode(base), var layout = try? JSONDecoder().decode(NativeLayoutPreferences.self, from: bytes) else { return }
        layout.normalize(); if layout != parent.layout { parent.layout = layout }
    }
    private func write(action: String, body: JSONObject) async throws -> JSONObject {
        do { return try await parent.api.post(action: action, body: body) }
        catch { if NativeRequestError.isCancellation(error) { parent.needsSync = true }; parent.noteConnectionFailure(error); throw error }
    }
    func saveConfig(_ config: JSONObject, revision: Int, applyBirthdayDefaults: Bool = false) async throws {
        guard canWrite else { throw NativeFailure("Conecte-se e atualize antes de alterar as configurações.") }
        guard revision == snapshot.revision else { throw NativeFailure("A configuração mudou no servidor. Atualize antes de salvar.", status: 409) }
        guard !applyBirthdayDefaults || snapshot.apiVersion >= 4 else { throw NativeFailure("Envie primeiro a atualização da HostGator para aplicar os avisos a todos os aniversariantes.") }
        #if DEBUG
        if parent.isPreview {
            guard let encoded = try? JSONEncoder().encode(config), let canonical = try? JSONDecoder().decode(JSONObject.self, from: encoded) else { throw NativeFailure("Invalid preview config") }
            snapshot.config = canonical; snapshot.revision += 1; applyRemoteLayout(); return
        }
        #endif
        saving = true; defer { saving = false }
        do {
            let result = try await write(action: "platform_save_config", body: ["revision": .number(Double(revision)), "config": .object(config), "applyBirthdayDefaults": .bool(applyBirthdayDefaults)])
            await refresh()
            guard loaded, issue == nil, snapshot.revision == result.integer("revision") else { throw NativeFailure("A gravação foi enviada. Atualize para conferir a configuração no servidor.") }
        } catch { parent.noteConnectionFailure(error); if (error as? NativeFailure)?.status != 499 { await refresh() }; throw error }
    }
    func saveLayout(_ layout: NativeLayoutPreferences, revision: Int) async throws {
        guard snapshot.apiVersion >= 7 else { throw NativeFailure("Envie primeiro o pacote HostGator 2.7.0 para salvar os novos layouts.", status: 422) }
        var config = snapshot.config
        let bytes = try JSONEncoder().encode(layout)
        config["layout"] = .object(try JSONDecoder().decode(JSONObject.self, from: bytes))
        try await saveConfig(config, revision: revision)
    }
    func saveBirthday(_ value: NativeBirthday) async throws {
        guard canWrite else { throw NativeFailure("Sem conexão com o servidor. O aniversário não foi salvo.") }
        saving = true; defer { saving = false }
        _ = try await write(action: "birthday_save", body: value.fields)
        await refresh()
        if issue != nil { throw NativeFailure("Atualize para confirmar os aniversários no servidor.") }
    }
    func deleteBirthday(_ value: NativeBirthday) async throws {
        guard canWrite else { throw NativeFailure("Conecte-se antes de excluir.") }
        saving = true; defer { saving = false }
        _ = try await write(action: "birthday_delete", body: ["id": .string(value.id), "revision": value.fields["revision"] ?? .number(0)])
        await refresh()
        if issue != nil { throw NativeFailure("Atualize para confirmar os aniversários no servidor.") }
    }
    func importBirthdays(_ values: [NativeBirthday]) async throws -> (Int, Int) {
        guard canWrite else { throw NativeFailure("Conecte-se antes de importar os aniversários.") }
        saving = true; defer { saving = false }
        var imported = 0, skipped = 0
        for offset in stride(from: 0, to: values.count, by: 200) {
            guard parent.networkAvailable && !parent.offline else { throw NativeFailure("A conexão caiu. Atualize para conferir os lotes já confirmados antes de continuar.") }
            let batch = values[offset..<min(values.count, offset + 200)]
            let response = try await write(action: "birthdays_import", body: ["items": .array(batch.map { .object($0.fields) })])
            imported += response.integer("imported"); skipped += response.integer("skipped")
        }
        await refresh(); return (imported, skipped)
    }
    // Marks this year's birthday as done (message sent). The person keeps its
    // place in the list; the server confirms before the checkbox changes.
    func setCompleted(_ value: NativeBirthday, _ done: Bool) async throws {
        guard snapshot.apiVersion >= 7 else { throw NativeFailure("Envie primeiro o pacote HostGator 2.7.0 para concluir aniversários.", status: 422) }
        #if DEBUG
        if parent.isPreview {
            var next = value.settingCompleted(done); next.fields["revision"] = .number(Double(value.fields.integer("revision") + 1))
            snapshot.birthdays = snapshot.birthdays.map { $0.id == value.id ? next : $0 }; return
        }
        #endif
        try await saveBirthday(value.settingCompleted(done))
    }
    func savePlaces(_ places: [JSONValue]) async throws {
        guard snapshot.apiVersion >= 7 else { throw NativeFailure("Envie primeiro o pacote HostGator 2.7.0 para salvar locais.", status: 422) }
        var config = snapshot.config; config["places"] = .array(places)
        try await saveConfig(config, revision: snapshot.revision)
    }
    // Adds, replaces or removes one place; the refresh after saving updates the alerts.
    func savePlace(_ place: NativePlace, remove: Bool = false) async throws {
        var list = NativePlace.list(snapshot.config).filter { $0.id != place.id }.map { JSONValue.object($0.fields) }
        if !remove { list.append(.object(place.fields)) }
        try await savePlaces(list)
    }
    // Automatic contacts sync: reads the iPhone contacts at most every 15
    // minutes and sends them when something changed (or once a day). Only
    // name and date are sent; the server keeps everything else.
    private var contactsSyncing = false
    func syncContactsIfNeeded(force: Bool = false) async {
        guard !contactsSyncing, loaded, snapshot.apiVersion >= 7, enabled("birthdays"), enabled("contactsSync"), canWrite, !parent.isPreview, NativeBirthdayContacts.authorized, let user = parent.user else { return }
        contactsSyncing = true; defer { contactsSyncing = false }
        let key = "nativeContactsSync." + user.id, now = Date().timeIntervalSince1970
        var state = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        guard force || now - (state["checked"] as? Double ?? 0) > 900 else { return }
        state["checked"] = now; UserDefaults.standard.set(state, forKey: key)
        guard let contacts = try? await NativeBirthdayContacts.load(prompt: false) else { return }
        var items: [JSONValue] = [], lines: [String] = []
        for item in contacts.items {
            let year: String = item.year.map(String.init) ?? ""
            items.append(.object(["sourceKey": .string(item.fields.text("sourceKey")), "name": .string(item.name), "month": .number(Double(item.month)), "day": .number(Double(item.day)), "year": item.fields["year"] ?? .null]))
            lines.append(item.fields.text("sourceKey") + "|" + item.name + "|" + String(item.month) + "|" + String(item.day) + "|" + year)
        }
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        guard force || digest != state["hash"] as? String || now - (state["sent"] as? Double ?? 0) > 86400 else { return }
        do {
            for offset in stride(from: 0, to: items.count, by: 200) {
                guard parent.user?.id == user.id, parent.networkAvailable, !parent.offline else { return }
                _ = try await write(action: "birthdays_sync", body: ["items": .array(Array(items[offset..<min(items.count, offset + 200)]))])
            }
            state["hash"] = digest; state["sent"] = now; UserDefaults.standard.set(state, forKey: key)
            if !items.isEmpty { await refresh() }
        } catch { issue = "Não foi possível sincronizar os aniversários dos Contatos. " + error.localizedDescription }
    }
    #if DEBUG
    func preview() {
        snapshot.apiVersion = 7
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let now = Date(), tomorrow = c.date(byAdding: .day, value: 1, to: now)!
        var today = NativeBirthday.fresh(), next = NativeBirthday.fresh()
        today.fields.merge(["id": .string("b1"), "name": .string("Ana · Família"), "month": .number(Double(c.component(.month, from: now))), "day": .number(Double(c.component(.day, from: now))), "revision": .number(1)]) { _, new in new }
        next.fields.merge(["id": .string("b2"), "name": .string("Bruno · Amigos"), "month": .number(Double(c.component(.month, from: tomorrow))), "day": .number(Double(c.component(.day, from: tomorrow))), "revision": .number(1)]) { _, new in new }
        snapshot.birthdays = [today, next]; loaded = true
    }
    #endif
}
