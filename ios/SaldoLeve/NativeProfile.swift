import SwiftUI

struct NativeCategoriesView: View {
    @ObservedObject var store: NativeStore
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List {
                ForEach([false, true], id: \.self) { archived in
                    Section(archived ? "Arquivadas" : "Suas categorias") {
                        ForEach(store.snapshot.lists.filter { $0.archived == archived }) { category in
                            NavigationLink { NativeTaskList(store: store, title: category.name, categoryID: category.id) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: archived ? "archivebox.fill" : "folder.fill").font(.title2).foregroundStyle(nativeBlue)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(category.name).font(.headline)
                                        Text("\(store.snapshot.items.filter { $0.categoryID == category.id && $0.isActive }.count) pendentes" + (category.canEdit ? "" : " · Somente leitura")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
                if store.snapshot.lists.isEmpty { Text("Crie uma categoria para organizar suas primeiras tarefas.").foregroundStyle(.secondary) }
            }.navigationTitle("Categorias")
                .toolbar { Button { creating = true } label: { Image(systemName: "folder.badge.plus") }.disabled(!store.canWrite) }
                .sheet(isPresented: $creating) { NativeCategoryEditor(store: store) }
                .refreshable { await store.refresh() }
        }
    }
}
struct NativeCategoryEditor: View {
    @ObservedObject var store: NativeStore
    var original: NativeCategory? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var fields: JSONObject = [:]
    @State private var deleting = false
    private let colors = ["#1f6feb", "#0ea5e9", "#14b8a6", "#159a68", "#84cc16", "#f59e0b", "#f97316", "#e5484d", "#ec4899", "#8b5cf6", "#64748b"]
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Nome da categoria", text: text("name")); TextField("Pasta (opcional)", text: text("folder")) }
                Section("Cor") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(colors, id: \.self) { value in
                            Button { fields["color"] = .string(value) } label: {
                                Circle().fill(Color(nativeHex: value)).frame(width: 30, height: 30)
                                    .overlay { if fields.text("color") == value { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                            }.buttonStyle(.plain).accessibilityLabel("Cor " + value)
                        }
                    }.padding(.vertical, 8)
                }
                Section("Compartilhar categoria") {
                    ForEach(store.snapshot.users.filter { $0.text("id") != store.user?.id }.map(NativeRecord.init)) { user in
                        Toggle(user.fields.text("name"), isOn: Binding(get: { fields.objects("members").contains { $0.text("id") == user.id } }, set: { enabled in
                            var members = fields.objects("members").filter { $0.text("id") != user.id }
                            if enabled { members.append(["id": .string(user.id), "role": .string("editor")]) }; fields["members"] = .array(members.map(JSONValue.object))
                        }))
                        if fields.objects("members").contains(where: { $0.text("id") == user.id }) {
                            Picker("Permissão", selection: Binding(get: { fields.objects("members").first { $0.text("id") == user.id }?.text("role") ?? "editor" }, set: { role in fields["members"] = .array(fields.objects("members").map { member in var value = member; if member.text("id") == user.id { value["role"] = .string(role) }; return .object(value) }) })) { Text("Pode editar").tag("editor"); Text("Somente leitura").tag("viewer") }.font(.caption)
                        }
                    }
                }
                if original != nil {
                    Section { Toggle("Arquivar categoria", isOn: Binding(get: { fields.flag("archived") }, set: { fields["archived"] = .bool($0) })); Button("Excluir categoria", role: .destructive) { deleting = true } }
                }
            }.navigationTitle(original == nil ? "Nova categoria" : "Editar categoria").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(store.working) }
                    ToolbarItem(placement: .confirmationAction) { Button("Salvar") { Task { do { _ = try await store.mutate("org_save_list", fields); dismiss() } catch { store.report(error) } } }.disabled(fields.text("name").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.canWrite) }
                }
                .onAppear { fields = original?.fields ?? ["name": .string(""), "folder": .string(""), "color": .string("#1f6feb"), "members": .array([])] }
                .confirmationDialog("Excluir categoria, tarefas e anexos definitivamente?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Excluir definitivamente", role: .destructive) { Task { do { _ = try await store.mutate("org_delete_list", fields); dismiss() } catch { store.report(error) } } }
                } message: { Text("Para manter os dados, use Arquivar categoria.") }
        }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { fields.text(key) }, set: { fields[key] = .string($0) }) }
}
struct NativeAgendaView: View {
    @ObservedObject var store: NativeStore
    @State private var day = Date()
    var body: some View {
        VStack(spacing: 0) {
            DatePicker("Dia", selection: $day, displayedComponents: .date).datePickerStyle(.graphical).padding(.horizontal)
            NativeTaskList(store: store, title: "Agenda", day: day)
        }
    }
}
struct NativeProfileView: View {
    @ObservedObject var store: NativeStore
    @AppStorage("nativeBiometrics") private var biometrics = false
    @AppStorage("nativeLocalReminders") private var localReminders = false
    @State private var logout = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nativeAppearance") private var appearance = "system"
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(store.user?.name ?? "", systemImage: "person.crop.circle.fill").font(.title3.bold())
                    Text(store.user?.login ?? "").foregroundStyle(.secondary)
                }
                Section("Aparência") {
                    Picker("Modo", selection: $appearance) { Text("Sistema").tag("system"); Text("Claro").tag("light"); Text("Escuro").tag("dark") }
                    Picker("Cor das tarefas", selection: Binding(get: { store.snapshot.preferences.text("theme").isEmpty ? "blue" : store.snapshot.preferences.text("theme") }, set: { theme in
                        var preferences = store.snapshot.preferences; preferences["theme"] = .string(theme)
                        Task { do { _ = try await store.mutate("org_preferences", preferences) } catch { store.report(error) } }
                    })) { Text("Azul").tag("blue"); Text("Verde").tag("green"); Text("Roxo").tag("purple"); Text("Rosa").tag("rose"); Text("Âmbar").tag("amber"); Text("Escuro").tag("dark") }
                }
                Section("Neste iPhone") {
                    Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.openedFinance = .init(kind: "layout") } } label: { Label("Layout e personalização", systemImage: "slider.horizontal.3") }
                    Toggle("Proteger com Face ID ou código", isOn: $biometrics)
                    NavigationLink { NativeDeviceSettings(store: store) } label: { Label("Aparelhos conectados e login salvo", systemImage: "iphone.gen3") }
                    NavigationLink { NativeNotificationSettings(store: store) } label: { Label("Notificações e silêncio", systemImage: "bell.badge") }
                    NavigationLink { NativeWidgetSettings(store: store) } label: { Label("Widgets", systemImage: "square.grid.2x2") }
                    if let date = store.syncedAt { LabeledContent("Sincronizado", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Button("Sincronizar agora") { Task { await store.refresh() } }.disabled(store.refreshing || store.working)
                }
                Section("Sistema") {
                    Button("Abrir versão web") { openURL(store.api.address.home) }
                    Button("Abrir ajustes do SaldoLeve no iPhone") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    LabeledContent("Versão", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
                Section { Button("Sair da conta", role: .destructive) { logout = true }.disabled(store.working) }
            }.navigationTitle("Minha conta").navigationBarTitleDisplayMode(.inline).toolbar { Button("Fechar") { dismiss() } }
                .confirmationDialog("Sair da conta?", isPresented: $logout, titleVisibility: .visible) {
                    Button("Sair e limpar dados deste iPhone", role: .destructive) { Task { await store.logout() } }
                } message: { Text("A cópia de consulta e os lembretes deste aplicativo serão removidos. Os dados confirmados continuam no servidor.") }
        }
    }
}

struct NativeHabitsView: View {
    @ObservedObject var store: NativeStore
    @State private var editing: NativeRecord?
    var body: some View {
        List {
            Section {
                HStack { Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "pt_BR"))).capitalized).font(.system(size: 14, weight: .semibold)); Spacer(); Button { editing = NativeRecord(fields: ["id": .string(""), "name": .string(""), "goal": .number(1), "unit": .string("vezes"), "weekdays": .array((1...7).map { .number(Double($0)) }), "timezone": .string(TimeZone.current.identifier)]) } label: { Image(systemName: "plus").frame(width: 36, height: 36) }.disabled(!store.canWrite).accessibilityLabel("Criar hábito") }
            }.listRowBackground(Color.clear)
            ForEach(store.snapshot.habits.filter { !$0.flag("archived") }.map(NativeRecord.init)) { record in
                let goal = max(1, record.fields.integer("goal"))
                let day = NativeMonth.day(Date(), zone: record.fields.text("timezone"))
                let progress = record.fields["logs"]?.object.integer(day) ?? 0
                HStack(spacing: 14) {
                    Button { log(record, day: day, value: progress >= goal ? 0 : progress + 1) } label: { ZStack { Circle().stroke(nativeBlue.opacity(0.13), lineWidth: 3); Circle().trim(from: 0, to: min(1, Double(progress) / Double(goal))).stroke(nativeBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)); Image(systemName: progress >= goal ? "checkmark" : "plus").font(.system(size: 16, weight: .medium)) }.frame(width: 36, height: 36).padding(4) }.disabled(!store.canWrite)
                    VStack(alignment: .leading, spacing: 5) { Text(record.fields.text("name")).font(.system(size: 16, weight: .medium)); Text("\(progress)/\(goal) \(record.fields.text("unit"))").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    Button { editing = record } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 32, height: 44) }.disabled(!store.canWrite).accessibilityLabel("Editar hábito")
                }.buttonStyle(.borderless).padding(.vertical, 5)
                    .contextMenu { Button("Editar hábito") { editing = record }; Button(progress >= goal ? "Reabrir hoje" : "Concluir hoje") { log(record, day: day, value: progress >= goal ? 0 : goal) }.disabled(!store.canWrite) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("Editar") { editing = record }.tint(nativeBlue) }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) { Button(progress >= goal ? "Reabrir" : "Concluir") { log(record, day: day, value: progress >= goal ? 0 : goal) }.tint(.green).disabled(!store.canWrite) }
            }
            if store.snapshot.habits.filter({ !$0.flag("archived") }).isEmpty { Text("Crie um hábito e acompanhe seu progresso aqui, com os mesmos registros do site.").foregroundStyle(.secondary).padding(.vertical, 30).listRowBackground(Color.clear) }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(nativeCanvas).refreshable { await store.refresh() }
            .sheet(item: $editing) { NativeHabitEditor(store: store, record: $0) }
    }
    private func log(_ record: NativeRecord, day: String, value: Int) { Task { do { _ = try await store.mutate("org_log_habit", ["id": .string(record.id), "day": .string(day), "value": .number(Double(value))]) } catch { store.report(error) } } }
}
struct NativeHabitEditor: View {
    @ObservedObject var store: NativeStore
    let record: NativeRecord
    @Environment(\.dismiss) private var dismiss
    @State private var fields: JSONObject = [:]
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome do hábito", text: text("name"))
                TextField("Unidade", text: text("unit"))
                Stepper("Meta: \(max(1, fields.integer("goal")))", value: Binding(get: { max(1, fields.integer("goal")) }, set: { fields["goal"] = .number(Double($0)) }), in: 1...1000)
                Section("Dias da semana") {
                    ForEach(Array(["Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado", "Domingo"].enumerated()), id: \.offset) { index, name in Toggle(name, isOn: Binding(get: { fields["weekdays"]?.array.contains(.number(Double(index + 1))) == true }, set: { enabled in var days = fields["weekdays"]?.array ?? []; days.removeAll { $0 == .number(Double(index + 1)) }; if enabled { days.append(.number(Double(index + 1))) }; fields["weekdays"] = .array(days) })) }
                }
                if !record.id.isEmpty { Toggle("Arquivar hábito", isOn: Binding(get: { fields.flag("archived") }, set: { fields["archived"] = .bool($0) })) }
                Text("Os lembretes deste hábito continuam usando as configurações do site. Os lembretes locais do aplicativo são para Tarefas.").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle(record.id.isEmpty ? "Novo hábito" : "Editar hábito").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { Task { do { _ = try await store.mutate("org_save_habit", fields); dismiss() } catch { store.report(error) } } }.disabled(!store.canWrite || fields.text("name").isEmpty || fields["weekdays"]?.array.isEmpty != false) }
            }.onAppear { fields = record.fields }
        }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { fields.text(key) }, set: { fields[key] = .string($0) }) }
}
