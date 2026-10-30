import SwiftUI

enum NativeSettingsPage: String, CaseIterable, Identifiable, Hashable {
    case appearance, layout, notifications, birthdays, widgets, menus, features, account, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: return "Aparência e cores"
        case .layout: return "Layout e organização"
        case .notifications: return "Notificações, silêncio e contador"
        case .birthdays: return "Padrões de aniversariantes"
        case .widgets: return "Widgets"
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
        case .widgets: return "square.grid.2x2"
        case .menus: return "sidebar.left"
        case .features: return "sparkles"
        case .account: return "person.crop.circle"
        case .about: return "info.circle"
        }
    }
    var keywords: String {
        switch self {
        case .appearance: return "tema claro escuro modo cor"
        case .layout: return "cards colunas despesas visão geral tarefas fonte texto tamanho abas filtros"
        case .notifications: return "avisos lembretes som horário badge ícone vencimentos"
        case .birthdays: return "aniversário antecipação dias horário grupo contatos"
        case .widgets: return "tamanhos vertical maior lista conteúdo conexão código"
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
        ("Avisos e widgets", [.notifications, .birthdays, .widgets]),
        ("Preferências do sistema", [.menus, .features]),
        ("Sua conta", [.account, .about])
    ]
    private func matches(_ page: NativeSettingsPage) -> Bool {
        search.isEmpty || (page.title + " " + page.keywords).localizedStandardContains(search)
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if search.isEmpty {
                    Section { Label("Todas as preferências do SaldoLeve em um só lugar.", systemImage: "gearshape").foregroundStyle(.secondary).font(.subheadline) }
                }
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
                    case .widgets: NativeWidgetSettings(store: store)
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
        }.navigationTitle("Aparência e cores").navigationBarTitleDisplayMode(.inline)
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
