import SwiftUI
import UserNotifications

@MainActor struct NativeBirthdaysView: View {
    @ObservedObject var store: NativeStore
    @ObservedObject var platform: NativePlatformStore
    var initialID = ""
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "all"
    @State private var search = ""
    @State private var group = ""
    @State private var editing: NativeBirthday?
    @State private var importing = false
    @State private var issue: String?
    @State private var prepared = 0
    private var filtered: [NativeBirthday] {
        platform.snapshot.birthdays.filter { value in
            guard group.isEmpty || value.group == group, search.isEmpty || value.name.localizedStandardContains(search), let date = value.nextDate() else { return false }
            let c = value.calendar
            switch scope {
            case "today": return c.isDateInToday(date)
            case "next": return date < c.date(byAdding: .day, value: 31, to: c.startOfDay(for: Date()))!
            case "month": return c.component(.month, from: date) == c.component(.month, from: Date())
            default: return true
            }
        }.sorted { ($0.nextDate() ?? .distantFuture) == ($1.nextDate() ?? .distantFuture) ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : ($0.nextDate() ?? .distantFuture) < ($1.nextDate() ?? .distantFuture) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Ver aniversários", selection: $scope) { Text("Todos").tag("all"); Text("Hoje").tag("today"); Text("Próximos").tag("next"); Text("Neste mês").tag("month") }.pickerStyle(.segmented)
                    TextField("Buscar pessoa", text: $search).accessibilityIdentifier("birthday-search")
                    if !platform.snapshot.birthdays.isEmpty {
                        Picker("Grupo", selection: $group) { Text("Todos os grupos").tag(""); ForEach(Array(Set(platform.snapshot.birthdays.map(\.group))).sorted(), id: \.self) { Text($0).tag($0) } }
                    }
                }
                Section {
                    Button { editing = .fresh(config: platform.snapshot.config) } label: { Label("Cadastrar aniversário", systemImage: "plus.circle") }.disabled(!platform.canWrite).accessibilityIdentifier("birthday-add")
                    Button { importing = true } label: { Label("Importar aniversários dos Contatos", systemImage: "person.crop.rectangle.stack") }.disabled(!platform.canWrite).accessibilityIdentifier("birthday-import")
                }
                Section("Avisos no iPhone") {
                    Button("Permitir e preparar notificações") { Task {
                        do {
                            let granted = try await store.reminders.enable(store.snapshot)
                            if granted { store.reminders.update(store.snapshot, birthdays: platform.enabled("birthdays") ? platform.snapshot.birthdays : []); issue = "Notificações autorizadas. Os próximos avisos estão sendo preparados." }
                            else { issue = "As notificações não foram permitidas. Libere o SaldoLeve nos Ajustes do iPhone." }
                        } catch { issue = error.localizedDescription }
                    } }.disabled(!store.networkAvailable || store.offline)
                    LabeledContent("Avisos preparados", value: String(prepared))
                    Text("Os avisos são locais e respeitam as configurações de silêncio. Sincronize o iPhone após alterações no computador. O app prepara os próximos avisos dentro do limite do iOS e atualiza a programação durante o uso.").font(.caption).foregroundStyle(.secondary)
                    Button("Abrir ajustes de notificações") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.footnote)
                }
                if !store.networkAvailable || store.offline { Section { Label("Sem conexão · somente consulta", systemImage: "wifi.slash").foregroundStyle(.orange) } }
                if let message = issue ?? platform.issue { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                Section("\(filtered.count) aniversariante(s)") {
                    if filtered.isEmpty { Text(platform.text("birthdayEmpty", fallback: "Nenhum aniversário neste filtro.")).foregroundStyle(.secondary) }
                    ForEach(filtered) { value in
                        Button { editing = value } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "gift.fill").foregroundStyle(nativeBlue).font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(value.name).font(.headline).foregroundStyle(.primary)
                                    Text(value.dateLabel + " · " + value.group).font(.caption).foregroundStyle(.secondary)
                                    if let date = value.nextDate() { Text((value.calendar.isDateInToday(date) ? "Hoje" : date.formatted(.dateTime.day().month(.wide))) + (value.age(at: date).map { " · \($0) anos" } ?? "")).font(.subheadline).foregroundStyle(nativeBlue) }
                                }
                                Spacer()
                                Image(systemName: value.enabled ? "bell" : "bell.slash").foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain).accessibilityIdentifier("birthday-row-" + value.id)
                    }
                }
            }.navigationTitle(platform.label("birthdays")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }; ToolbarItem(placement: .primaryAction) { if platform.loading { ProgressView() } else { Button { Task { await platform.refresh(); prepared = await store.reminders.birthdayPendingCount() } } label: { Image(systemName: "arrow.clockwise") } } } }
                .sheet(item: $editing) { NativeBirthdayEditor(platform: platform, original: $0) }
                .sheet(isPresented: $importing) { NativeBirthdayImportView(platform: platform) }
                .task { await platform.refresh(); prepared = await store.reminders.birthdayPendingCount(); if !initialID.isEmpty { editing = platform.snapshot.birthdays.first { $0.id == initialID } } }
                .refreshable { await platform.refresh(); prepared = await store.reminders.birthdayPendingCount() }
        }
    }
}

@MainActor struct NativeBirthdayEditor: View {
    @ObservedObject private var store: NativeStore
    @ObservedObject var platform: NativePlatformStore
    let original: NativeBirthday
    @Environment(\.dismiss) private var dismiss
    @State private var value: NativeBirthday
    @State private var yearText: String
    @State private var issue: String?
    @State private var working = false
    @State private var removing = false
    init(platform: NativePlatformStore, original: NativeBirthday) { self.store = platform.parent; self.platform = platform; self.original = original; _value = State(initialValue: original); _yearText = State(initialValue: original.year.map(String.init) ?? "") }
    private func text(_ key: String) -> Binding<String> { Binding(get: { value.fields.text(key) }, set: { value.fields[key] = .string($0) }) }
    private func number(_ key: String) -> Binding<Int> { Binding(get: { value.fields.integer(key) }, set: { value.fields[key] = .number(Double($0)) }) }
    private var valid: Bool {
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.group.isEmpty, (1...12).contains(value.month), (1...31).contains(value.day) else { return false }
        let year = yearText.isEmpty ? 2000 : Int(yearText) ?? 0
        guard year > 0, yearText.isEmpty || year <= value.calendar.component(.year, from: Date()), let date = value.calendar.date(from: DateComponents(year: year, month: value.month, day: value.day)) else { return false }
        return value.calendar.component(.month, from: date) == value.month && value.calendar.component(.day, from: date) == value.day
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Pessoa") {
                    TextField("Nome", text: text("name")).accessibilityIdentifier("birthday-name")
                    TextField("Grupo: família, amigos, trabalho…", text: text("group"))
                    TextField("Observações", text: text("note"), axis: .vertical)
                }
                Section("Data de aniversário") {
                    Picker("Dia", selection: number("day")) { ForEach(1...31, id: \.self) { Text(String($0)).tag($0) } }
                    Picker("Mês", selection: number("month")) { ForEach(1...12, id: \.self) { Text(String($0)).tag($0) } }
                    TextField("Ano de nascimento (opcional)", text: $yearText).keyboardType(.numberPad).accessibilityIdentifier("birthday-year")
                    if !valid && !value.name.isEmpty { Text("Confira a data. Você pode deixar o ano em branco.").font(.caption).foregroundStyle(.orange) }
                    if value.month == 2 && value.day == 29 { Picker("Em anos sem 29 de fevereiro", selection: text("leapPolicy")) { Text("Avisar em 28/02").tag("feb28"); Text("Avisar em 01/03").tag("mar01"); Text("Só em anos bissextos").tag("leapOnly") } }
                }
                Section("Notificações") {
                    Toggle("Avisar neste aniversário", isOn: Binding(get: { value.enabled }, set: { value.fields["enabled"] = .bool($0) }))
                    DatePicker("Horário", selection: Binding(get: { value.occurrence(year: 2000) ?? Date() }, set: { value.fields["time"] = .string(NativeDate.formatter("HH:mm", zone: value.calendar.timeZone.identifier).string(from: $0)) }), displayedComponents: .hourAndMinute).environment(\.timeZone, value.calendar.timeZone)
                    ForEach([0, 1, 2, 3, 7, 14, 30], id: \.self) { offset in
                        Toggle(offset == 0 ? "No dia" : "\(offset) dia(s) antes", isOn: Binding(get: { value.fields["daysBefore"]?.array.contains(.number(Double(offset))) == true }, set: { enabled in
                            var offsets = Set(value.fields["daysBefore"]?.array.compactMap { $0.number.map(Int.init) } ?? [])
                            if enabled { if offsets.count < 5 { offsets.insert(offset) } } else { offsets.remove(offset) }
                            value.fields["daysBefore"] = .array(offsets.sorted().map { .number(Double($0)) })
                        }))
                    }
                    Text("Escolha até cinco avisos. Eles respeitam o silêncio configurado no aplicativo.").font(.caption).foregroundStyle(.secondary)
                }
                if let issue { Section { Text(issue).foregroundStyle(.red).font(.footnote) } }
                if !original.fields.text("id").isEmpty { Section { Button("Excluir aniversário", role: .destructive) { removing = true } } }
            }.disabled(!platform.canWrite || working).navigationTitle(original.fields.text("id").isEmpty ? "Novo aniversário" : "Aniversário").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.bold().disabled(!platform.canWrite || !valid || working) }
                }
                .confirmationDialog("Excluir o aniversário e seus próximos avisos?", isPresented: $removing, titleVisibility: .visible) { Button("Excluir", role: .destructive) { Task { working = true; defer { working = false }; do { try await platform.deleteBirthday(value); dismiss() } catch { issue = error.localizedDescription } } } }
                .onChange(of: store.offline) { offline in
                    guard offline, !working else { return }
                    value = platform.snapshot.birthdays.first { $0.id == original.id } ?? original
                    yearText = value.year.map(String.init) ?? ""
                    issue = "Sem conexão. Somente consulta aos dados confirmados; alterações não salvas foram descartadas."
                }
                .onChange(of: platform.snapshot.birthdays) { values in
                    guard !working else { return }
                    guard let current = values.first(where: { $0.id == original.id }) else { if !original.fields.text("id").isEmpty { dismiss() }; return }
                    guard current.fields.integer("revision") != value.fields.integer("revision") else { return }
                    value = current; yearText = current.year.map(String.init) ?? ""; issue = "Registro atualizado com a versão do servidor."
                }
        }
    }
    private func save() {
        value.fields["year"] = Int(yearText).map { .number(Double($0)) } ?? .null
        Task { working = true; defer { working = false }; do { try await platform.saveBirthday(value); dismiss() } catch { issue = error.localizedDescription; await platform.refresh() } }
    }
}

@MainActor struct NativeBirthdayImportView: View {
    @ObservedObject private var store: NativeStore
    init(platform: NativePlatformStore) { self.store = platform.parent; self.platform = platform }
    @ObservedObject var platform: NativePlatformStore
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [NativeBirthday] = []
    @State private var selected = Set<String>()
    @State private var group = "Amigos"
    @State private var loading = false
    @State private var issue: String?
    @State private var summary = ""
    private var existing: Set<String> { Set(platform.snapshot.birthdays.map(\.fingerprint)) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("O iPhone pede sua permissão. Somente nome e aniversário dos contatos escolhidos serão enviados à sua conta no servidor; telefones e e-mails não são importados.").font(.footnote).foregroundStyle(.secondary)
                    Button("Escolher aniversários dos Contatos") { load() }.disabled(loading || !platform.canWrite).accessibilityIdentifier("contacts-load")
                    Button("Gerenciar acesso nos Ajustes") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.footnote)
                    if loading { ProgressView("Lendo aniversários…") }
                    if !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    TextField("Grupo para os novos aniversariantes", text: $group).disabled(loading || !platform.canWrite)
                }
                if !contacts.isEmpty {
                    Section {
                        Button("Selecionar novos") { selected = Set(contacts.filter { !existing.contains($0.fingerprint) }.map(\.id)) }.disabled(loading)
                        Button("Limpar seleção") { selected = [] }.disabled(loading)
                    }
                    Section("\(selected.count) selecionado(s)") {
                        ForEach(contacts) { contact in
                            Toggle(isOn: Binding(get: { selected.contains(contact.id) }, set: { if $0 { selected.insert(contact.id) } else { selected.remove(contact.id) } })) {
                                VStack(alignment: .leading, spacing: 3) { Text(contact.name); Text(contact.dateLabel + (existing.contains(contact.fingerprint) ? " · Já cadastrado" : "")).font(.caption).foregroundStyle(.secondary) }
                            }.disabled(existing.contains(contact.fingerprint) || loading)
                        }
                    }
                }
                if let issue { Section { Text(issue).font(.footnote).foregroundStyle(.secondary) } }
            }.navigationTitle("Importar aniversários").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.disabled(loading) }
                    ToolbarItem(placement: .confirmationAction) { Button("Importar \(selected.count)") { save() }.bold().disabled(loading || selected.isEmpty || group.trimmingCharacters(in: .whitespaces).isEmpty || !platform.canWrite) }
                }
        }
    }
    private func load() {
        Task {
            loading = true; defer { loading = false }
            do {
                let result = try await NativeBirthdayContacts.load(); contacts = result.items
                selected = Set(contacts.filter { !existing.contains($0.fingerprint) }.map(\.id))
                summary = "\(contacts.count) contato(s) com aniversário; \(result.skipped) sem data gregoriana utilizável." + (result.limited ? " O iPhone disponibilizou apenas os contatos autorizados." : "")
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }
    private func save() {
        let values = contacts.filter { selected.contains($0.id) }.map { item -> NativeBirthday in
            var value = NativeBirthday.fresh(config: platform.snapshot.config)
            for key in ["name", "month", "day", "year", "sourceKey"] { value.fields[key] = item.fields[key] }
            value.fields["group"] = .string(group.trimmingCharacters(in: .whitespacesAndNewlines)); return value
        }
        Task {
            loading = true; defer { loading = false }
            do { let result = try await platform.importBirthdays(values); selected = []; issue = "\(result.0) importado(s); \(result.1) já existente(s), sem substituir os dados do servidor." }
            catch { issue = error.localizedDescription; await platform.refresh() }
        }
    }
}
