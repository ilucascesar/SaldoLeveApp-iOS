import SwiftUI
import AppIntents
import EventKit

enum NativeSettingsPage: String, CaseIterable, Identifiable, Hashable {
    case appearance, layout, notifications, birthdays, places, widgets, siri, menus, features, account, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: return "Aparência e cores"
        case .layout: return "Layout e organização"
        case .notifications: return "Notificações, silêncio e contador"
        case .birthdays: return "Padrões de aniversariantes"
        case .places: return "Locais"
        case .widgets: return "Widgets"
        case .siri: return "Siri e Atalhos"
        case .menus: return "Menus e textos"
        case .features: return "Recursos e sugestões"
        case .account: return "Conta e segurança"
        case .about: return "Sistema e permissões"
        }
    }
    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .layout: return "slider.horizontal.3"
        case .notifications: return "bell.badge"
        case .birthdays: return "gift"
        case .places: return "mappin.and.ellipse"
        case .widgets: return "square.grid.2x2"
        case .siri: return "mic"
        case .menus: return "sidebar.left"
        case .features: return "sparkles"
        case .account: return "person.crop.circle"
        case .about: return "info.circle"
        }
    }
    var keywords: String {
        switch self {
        case .appearance: return "tema claro escuro modo cor ícone logo logotipo"
        case .layout: return "cards colunas despesas visão geral tarefas fonte texto tamanho abas filtros"
        case .notifications: return "avisos lembretes som horário badge ícone vencimentos suspender pausar"
        case .birthdays: return "aniversário antecipação dias horário grupo contatos persistentes sincronizar"
        case .places: return "local localização mercado casa chegar sair geofence lembrete por local"
        case .widgets: return "tamanhos vertical maior lista conteúdo conexão código"
        case .siri: return "siri voz falar escrever ditar atalhos criar tarefa adicionar lembrete me lembre me lembra app lembretes importar"
        case .menus: return "ordem títulos navegação personalizar"
        case .features: return "busca erros valores organização recursos"
        case .account: return "face id código biometria aparelhos acesso login sincronizar sair"
        case .about: return "iphone ios versão servidor web permissões"
        }
    }
}

struct NativeSettingsView: View {
    @ObservedObject var store: NativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var path: [NativeSettingsPage]
    init(store: NativeStore, initialPage: NativeSettingsPage? = nil) {
        self.store = store
        _path = State(initialValue: initialPage.map { [$0] } ?? [])
    }
    private let groups: [(String, [NativeSettingsPage])] = [
        ("Personalização", [.appearance, .layout]),
        ("Avisos e widgets", [.notifications, .birthdays, .places, .widgets]),
        ("Preferências do sistema", [.siri, .menus, .features]),
        ("Sua conta", [.account, .about])
    ]
    private func matches(_ page: NativeSettingsPage) -> Bool {
        search.isEmpty || (page.title + " " + page.keywords).localizedStandardContains(search)
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(groups.indices, id: \.self) { index in
                    let pages = groups[index].1.filter(matches)
                    if !pages.isEmpty {
                        Section(groups[index].0) {
                            ForEach(pages) { page in
                                NavigationLink(value: page) { Label(page.title, systemImage: page.icon) }
                                    .accessibilityIdentifier("settings-" + page.rawValue)
                            }
                        }
                    }
                }
                if !NativeSettingsPage.allCases.contains(where: matches) { Text("Nenhuma configuração encontrada.").foregroundStyle(.secondary) }
            }.navigationTitle("Configurações").navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("settings-center")
                .searchable(text: $search, prompt: "Buscar configuração")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
                .navigationDestination(for: NativeSettingsPage.self) { page in
                    switch page {
                    case .appearance: NativeAppearanceSettings(store: store)
                    case .layout: NativeLayoutSettings(store: store, embedded: true)
                    case .notifications: NativeNotificationSettings(store: store)
                    case .birthdays: NativeRemoteSettings(platform: store.platform, page: .birthdays, embedded: true)
                    case .places: NativePlacesSettings(store: store)
                    case .widgets: NativeWidgetSettings(store: store)
                    case .siri: NativeSiriSettings(store: store)
                    case .menus: NativeRemoteSettings(platform: store.platform, page: .menus, embedded: true)
                    case .features: NativeRemoteSettings(platform: store.platform, page: .features, embedded: true)
                    case .account: NativeAccountSettings(store: store)
                    case .about: NativeSystemSettings(store: store)
                    }
                }
        }
    }
}

private struct NativeAppearanceSettings: View {
    @ObservedObject var store: NativeStore
    @AppStorage("nativeAppearance") private var appearance = "system"
    var body: some View {
        Form {
            Section("Neste iPhone") { Picker("Modo", selection: $appearance) { Text("Sistema").tag("system"); Text("Claro").tag("light"); Text("Escuro").tag("dark") } }
            Section("Na sua conta") {
                Picker("Cor das tarefas", selection: Binding(get: { store.snapshot.preferences.text("theme").isEmpty ? "blue" : store.snapshot.preferences.text("theme") }, set: { theme in
                    var preferences = store.snapshot.preferences; preferences["theme"] = .string(theme)
                    Task { do { _ = try await store.mutate("org_preferences", preferences) } catch { store.report(error) } }
                })) { Text("Azul").tag("blue"); Text("Verde").tag("green"); Text("Roxo").tag("purple"); Text("Rosa").tag("rose"); Text("Âmbar").tag("amber"); Text("Escuro").tag("dark") }.disabled(!store.canWrite)
            }
            NativeAppIconPicker()
        }.navigationTitle("Aparência e cores").navigationBarTitleDisplayMode(.inline)
    }
}

// The Home Screen icon (logo) of this iPhone. iOS only switches between icons
// shipped in the app (Assets: AppIcon-<name>) and confirms with its own alert.
private struct NativeAppIconPicker: View {
    struct Option: Identifiable { var name: String?; var title: String; var index: Int; var id: String { title } }
    // Same order as the strip in Assets (IconPreviews), one square per icon.
    static let options = ["Original", "Azul", "Verde", "Roxo", "Rosa", "Preto", "Claro"].enumerated().map { Option(name: $0.offset == 0 ? nil : "AppIcon-" + $0.element, title: $0.element, index: $0.offset) }
    @State private var current = UIApplication.shared.alternateIconName
    @State private var issue: String?
    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 12)], spacing: 14) {
                ForEach(Self.options) { option in
                    let selected = current == option.name
                    Button { choose(option.name) } label: {
                        VStack(spacing: 6) {
                            Image("IconPreviews").resizable().frame(width: 58 * CGFloat(Self.options.count), height: 58).offset(x: -58 * CGFloat(option.index))
                                .frame(width: 58, height: 58, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(selected ? nativeBlue : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1))
                            Text(option.title).font(.caption).foregroundStyle(selected ? nativeBlue : Color.primary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Ícone " + option.title).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.vertical, 6)
            if let issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
        } header: { Text("Ícone do app") } footer: { Text("Muda o ícone do SaldoLeve na Tela de Início deste iPhone. O iOS confirma a troca com um aviso.") }
    }
    private func choose(_ name: String?) {
        guard name != current else { return }
        guard UIApplication.shared.supportsAlternateIcons else { issue = "Este iPhone não permite trocar o ícone."; return }
        UIApplication.shared.setAlternateIconName(name) { error in
            DispatchQueue.main.async {
                if let error { issue = "Não foi possível trocar o ícone: " + error.localizedDescription } else { current = name; issue = nil }
            }
        }
    }
}

private struct NativeAccountSettings: View {
    @ObservedObject var store: NativeStore
    @AppStorage("nativeBiometrics") private var biometrics = false
    @State private var logout = false
    var body: some View {
        Form {
            Section { Label(store.user?.name ?? "", systemImage: "person.crop.circle.fill").font(.headline); Text(store.user?.login ?? "").foregroundStyle(.secondary) }
            Section("Acesso neste iPhone") {
                Toggle("Proteger com Face ID ou código", isOn: $biometrics)
                NavigationLink { NativeDeviceSettings(store: store) } label: { Label("Aparelhos conectados e login salvo", systemImage: "iphone.gen3") }
            }
            Section("Sincronização") {
                if let date = store.syncedAt { LabeledContent("Última confirmação", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Button("Sincronizar agora") { Task { await store.refresh() } }.disabled(store.refreshing || store.working)
                Text("Os dados confirmados no servidor prevalecem. Sem conexão, o aplicativo permite somente consulta.").font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("Sair da conta", role: .destructive) { logout = true }.disabled(store.working) }
        }.navigationTitle("Conta e segurança").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Sair da conta?", isPresented: $logout, titleVisibility: .visible) {
                Button("Sair e limpar dados deste iPhone", role: .destructive) { Task { await store.logout() } }
            } message: { Text("A cópia de consulta e os lembretes deste aplicativo serão removidos. Os dados confirmados continuam no servidor.") }
    }
}

private struct NativeSiriSettings: View {
    @ObservedObject var store: NativeStore
    @ObservedObject private var reminders = NativeRemindersImport.shared
    @AppStorage(NativeSiriPreferences.storageKey) private var input = "speak"
    @AppStorage(NativeRemindersImport.enabledKey) private var importReminders = false
    @AppStorage(NativeRemindersImport.listKey) private var listID = ""
    @Environment(\.openURL) private var openURL
    private let phrases = ["criar tarefa no SaldoLeve", "adicionar lembrete no SaldoLeve", "me lembre no SaldoLeve"]
    private var listName: String { reminders.lists.first(where: { $0.calendarIdentifier == listID })?.title ?? "SaldoLeve" }
    private var importToggle: Binding<Bool> {
        Binding(get: { importReminders }, set: { on in
            guard on else { importReminders = false; return }
            Task {
                guard await reminders.requestAccess() else { store.message = "Permita o acesso aos Lembretes nos Ajustes do iPhone."; return }
                do { listID = try reminders.list().calendarIdentifier; importReminders = true; await reminders.run(store, manual: true) }
                catch { store.report(error) }
            }
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("Importar do app Lembretes", isOn: importToggle).accessibilityIdentifier("reminders-import")
                if importReminders && reminders.allowed {
                    Picker("Lista", selection: $listID) { ForEach(reminders.lists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) } }
                    Button(reminders.running ? "Importando…" : "Importar agora") { Task { await reminders.run(store, manual: true) } }
                        .disabled(reminders.running || !store.canWrite)
                } else if importReminders {
                    Button("Permitir acesso nos Ajustes") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                }
            } header: { Text("“E aí Siri, me lembra de…”") } footer: {
                Text("O iOS envia “me lembra” ao app Lembretes. Quando a Siri perguntar o app, escolha Lembretes e, em Ajustes → Apps → Lembretes → Lista padrão, escolha \(listName). Ao abrir o SaldoLeve, cada lembrete pendente dessa lista vira uma tarefa com o mesmo horário e, só depois que o servidor confirmar, é marcado como concluído no Lembretes.")
            }
            Section {
                Picker("Responder à Siri", selection: $input) { Text("Falando").tag("speak"); Text("Escrevendo no app").tag("type") }
                    .accessibilityIdentifier("siri-input")
            } footer: {
                Text(input == "type" ? "A Siri abre uma nova tarefa no SaldoLeve para você escrever e salvar." : "A Siri pergunta “O que devo lembrar, e quando?” e você responde falando, por exemplo: “pagar o boleto daqui 2 horas” ou “ligar para o João amanhã às 9”. A tarefa só é confirmada depois que o servidor salvar.")
            }
            Section {
                ForEach(phrases, id: \.self) { phrase in Label("E aí Siri, " + phrase, systemImage: "waveform") }
                if #available(iOS 17.0, *) { ShortcutsLink() }
            } header: { Text("Diga à Siri") } footer: { Text("O iOS exige o nome do app nessas frases. Também funcionam pelo app Atalhos e digitando para a Siri.") }
            Section {
                Text("1. Toque em Criar atalho pessoal.\n2. Adicione a ação “Criar tarefa no SaldoLeve”.\n3. Dê ao atalho o nome “Criar tarefa” (repita com “Adicionar lembrete” ou “Me lembre”, se quiser).\n4. Diga “E aí Siri, criar tarefa” e responda o que lembrar.").font(.subheadline)
                Link(destination: URL(string: "shortcuts://create-shortcut")!) { Label("Criar atalho pessoal", systemImage: "plus.square.on.square") }
            } header: { Text("Sem dizer “SaldoLeve”") } footer: { Text("“Me lembra” sozinho vai para o app Lembretes da Apple; ative “Importar do app Lembretes” acima para trazê-lo ao SaldoLeve.") }
        }.navigationTitle("Siri e Atalhos").navigationBarTitleDisplayMode(.inline)
            .onAppear { reminders.reload() }
    }
}

private struct NativeSystemSettings: View {
    @ObservedObject var store: NativeStore
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            Section {
                Button("Abrir versão web") { openURL(store.api.address.home) }
                Button("Abrir ajustes do SaldoLeve no iPhone") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                Text("As permissões de contatos, banners, tela bloqueada e Foco são controladas pelo iOS.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Versão", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Compilação", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            }
        }.navigationTitle("Sistema e permissões").navigationBarTitleDisplayMode(.inline)
    }
}
