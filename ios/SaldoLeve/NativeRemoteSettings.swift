import SwiftUI

enum NativeRemoteSettingsPage: Equatable { case menus, features, birthdays }

@MainActor struct NativeRemoteSettings: View {
    @ObservedObject var platform: NativePlatformStore
    @ObservedObject private var store: NativeStore
    private let page: NativeRemoteSettingsPage
    private let embedded: Bool
    init(platform: NativePlatformStore, page: NativeRemoteSettingsPage = .menus, embedded: Bool = false) { self.platform = platform; self.store = platform.parent; self.page = page; self.embedded = embedded }
    @Environment(\.dismiss) private var dismiss
    @State private var config: JSONObject = [:]
    @State private var revision = 0
    @State private var working = false
    @State private var issue: String?
    private func string(_ section: String, _ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { config.record(section)[key]?.string ?? fallback }, set: { var values = config.record(section); values[key] = .string($0); config[section] = .object(values) })
    }
    private func flag(_ section: String, _ key: String, fallback: Bool = true) -> Binding<Bool> {
        Binding(get: { config.record(section)[key]?.bool ?? fallback }, set: { var values = config.record(section); values[key] = .bool($0); config[section] = .object(values) })
    }
    private var order: [String] {
        var seen = Set<String>()
        return ((config["menuOrder"]?.array.map(\.string) ?? []) + NativePlatformStore.navigationMenu).filter { NativePlatformStore.navigationMenu.contains($0) && seen.insert($0).inserted }
    }
    private var title: String { switch page { case .menus: return "Menus e textos"; case .features: return "Recursos e sugestões"; case .birthdays: return "Padrões de aniversariantes" } }
    @ViewBuilder var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
    private var content: some View {
            Form {
                Section {
                    Text("As opções são guardadas na sua conta e aplicadas no site e no iPhone após sincronizar. Novas funções que esta versão ainda não conhece continuam exigindo uma atualização do aplicativo.").font(.footnote).foregroundStyle(.secondary)
                    Text("Configuração \(revision)").font(.caption).foregroundStyle(.secondary)
                }
                if page == .menus {
                Section("Menus") {
                    NavigationLink("Ordenar o menu") { List {
                        ForEach(order, id: \.self) { Text(config.record("labels").text($0).isEmpty ? NativePlatformStore.labels[$0] ?? $0 : config.record("labels").text($0)) }
                            .onMove { source, destination in var next = order; next.move(fromOffsets: source, toOffset: destination); config["menuOrder"] = .array(next.map(JSONValue.string)) }
                    }.environment(\.editMode, .constant(.active)).navigationTitle("Ordem do menu") }
                    ForEach(NativePlatformStore.navigationMenu, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(NativePlatformStore.labels[key] ?? key, text: string("labels", key, fallback: NativePlatformStore.labels[key] ?? key))
                            if !["tasks", "remote", "profile"].contains(key) {
                                Toggle("Mostrar no menu", isOn: Binding(get: { config["hiddenMenu"]?.array.contains(.string(key)) != true }, set: { shown in
                                    var hidden = Set(config["hiddenMenu"]?.array.map(\.string) ?? []); if shown { hidden.remove(key) } else { hidden.insert(key) }; config["hiddenMenu"] = .array(hidden.sorted().map(JSONValue.string))
                                })).font(.caption)
                            }
                        }.padding(.vertical, 3)
                    }
                }
                Section("Textos") {
                    TextField("Nome apresentado no aplicativo", text: string("texts", "appTitle", fallback: "SaldoLeve"))
                    TextField("Título das tarefas", text: string("texts", "tasksHeading", fallback: "Tarefas"))
                    TextField("Mensagem de tarefas vazias", text: string("texts", "emptyTasks", fallback: "Nenhuma tarefa neste filtro."))
                    TextField("Mensagem de aniversários vazios", text: string("texts", "birthdayEmpty", fallback: "Nenhum aniversário neste filtro."))
                    TextField("Texto da busca geral", text: string("texts", "searchPlaceholder", fallback: "Buscar no SaldoLeve"))
                }
                }
                if page == .features {
                Section("Recursos") {
                    Toggle("Aniversariantes", isOn: flag("features", "birthdays"))
                    Toggle("Busca geral", isOn: flag("features", "search"))
                    Toggle("Sugestões de organização", isOn: flag("features", "suggestions"))
                    Toggle("Conferir valores e datas fora do padrão", isOn: flag("features", "warnings"))
                }
                }
                if page == .birthdays {
                Section("Padrões de novos aniversários") {
                    TextField("Grupo padrão", text: string("birthdayDefaults", "group", fallback: "Amigos"))
                    TextField("Horário (HH:mm)", text: string("birthdayDefaults", "time", fallback: "09:00")).keyboardType(.numbersAndPunctuation)
                    Toggle("Preparar avisos por padrão", isOn: flag("birthdayDefaults", "enabled"))
                    ForEach([0, 1, 2, 3, 7, 14, 30], id: \.self) { offset in
                        Toggle(offset == 0 ? "Avisar no dia" : "Avisar \(offset) dia(s) antes", isOn: Binding(get: { config.record("birthdayDefaults")["daysBefore"]?.array.contains(.number(Double(offset))) ?? (offset == 0) }, set: { enabled in
                            var values = config.record("birthdayDefaults"), offsets = Set(values["daysBefore"]?.array.compactMap { $0.number.map(Int.init) } ?? [0])
                            if enabled { if offsets.count < 5 { offsets.insert(offset) } } else { offsets.remove(offset) }; values["daysBefore"] = .array(offsets.sorted().map { .number(Double($0)) }); config["birthdayDefaults"] = .object(values)
                        }))
                    }
                }
                }
                if let issue = issue ?? platform.issue { Section { Text(issue).font(.footnote).foregroundStyle(.secondary) } }
            }.disabled(!platform.canWrite || working).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.disabled(working) } }
                    ToolbarItem(placement: .confirmationAction) { Button("Salvar") { Task { working = true; defer { working = false }; do { try await platform.saveConfig(config, revision: revision); dismiss() } catch { issue = error.localizedDescription } } }.bold().disabled(!platform.canWrite || working) }
                }
                .task { await platform.refresh(); config = platform.snapshot.config; revision = platform.snapshot.revision }
                .onChange(of: store.offline) { offline in guard offline, !working else { return }; config = platform.snapshot.config; revision = platform.snapshot.revision; issue = "Sem conexão. Alterações não confirmadas foram descartadas." }
                .onChange(of: platform.snapshot.revision) { next in guard !working else { return }; config = platform.snapshot.config; revision = next; issue = "As opções foram atualizadas com os dados do servidor." }
    }
}
