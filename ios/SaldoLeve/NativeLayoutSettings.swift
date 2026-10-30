import SwiftUI

struct NativeLayoutSettings: View {
    @ObservedObject var store: NativeStore
    @ObservedObject private var platform: NativePlatformStore
    @State private var layout = NativeLayoutPreferences()
    @State private var revision = 0
    @State private var working = false
    @State private var issue: String?
    @State private var reset = false
    init(store: NativeStore) { self.store = store; self.platform = store.platform }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { NativeLayoutPreview(layout: layout) } footer: { Text("Confira a prévia e toque em Salvar. O layout confirmado fica na sua conta e chega aos outros dispositivos.") }
                Section("Personalizar") {
                    destination("Navegação e tela inicial", icon: "sidebar.left", page: "navigation")
                    destination("Visão geral", icon: "rectangle.grid.2x2", page: "dashboard")
                    destination("Cards e organização de despesas", icon: "wallet.pass", page: "expenses")
                    destination("Tarefas e captura rápida", icon: "checklist", page: "tasks")
                    destination("Texto, espaço e aparência", icon: "textformat.size", page: "appearance")
                }
                Section {
                    NavigationLink { NativeWidgetSettings(store: store) } label: { Label("Configurações dos widgets", systemImage: "square.grid.2x2") }
                    NavigationLink { NativeNotificationSettings(store: store) } label: { Label("Notificações e contador", systemImage: "bell.badge") }
                }
                Section { Button("Restaurar layout padrão", role: .destructive) { reset = true } }
            if let issue { Section { Text(issue).font(.footnote) } }
            }.disabled(!platform.canWrite || working).navigationTitle("Layout e personalização").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) { Button("Salvar") { Task { working = true; defer { working = false }; do { try await platform.saveLayout(layout, revision: revision); dismiss() } catch { issue = error.localizedDescription } } }.disabled(!platform.canWrite || working) }
                }
                .task { await platform.refresh(); layout = store.layout; revision = platform.snapshot.revision }
                .onChange(of: store.offline) { offline in guard offline, !working else { return }; layout = store.layout; revision = platform.snapshot.revision; issue = "Sem conexão. Alterações de layout não confirmadas foram descartadas." }
                .onChange(of: platform.snapshot.revision) { next in guard !working else { return }; layout = store.layout; revision = next; issue = "Layout atualizado com a versão do servidor." }
                .confirmationDialog("Restaurar o layout padrão?", isPresented: $reset, titleVisibility: .visible) { Button("Restaurar layout") { layout = NativeLayoutPreferences() } } message: { Text("Seus dados, pagamentos, tarefas e notificações permanecem salvos.") }
        }
    }
    private func destination(_ title: String, icon: String, page: String) -> some View { NavigationLink { NativeLayoutDetail(layout: $layout, page: page, title: title) } label: { Label(title, systemImage: icon) } }
}
struct NativeLayoutPreview: View {
    let layout: NativeLayoutPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            HStack { if layout.cardShowIcon { Image(systemName: "creditcard.fill").foregroundStyle(nativeBlue) }; Text("Prévia do seu card").font(.system(size: 16 * layout.textScale, weight: .semibold)); Spacer(); Image(systemName: "ellipsis") }
            Text("R$ 1.234,56").font(.system(size: 27 * layout.textScale, weight: .bold, design: layout.roundedValues ? .rounded : .default))
            if layout.cardShowType { Text("Cartão de crédito · mês atual").font(.system(size: 12 * layout.textScale)).foregroundStyle(.secondary) }
            if layout.cardShowActions { Label("Novo gasto", systemImage: "plus").font(.system(size: 13 * layout.textScale, weight: .semibold)).foregroundStyle(nativeBlue) }
        }.padding(layout.spacing).frame(maxWidth: .infinity, alignment: .leading).background(nativeBlue.opacity(0.06), in: RoundedRectangle(cornerRadius: layout.cardRadius))
    }
}
struct NativeLayoutDetail: View {
    @Binding var layout: NativeLayoutPreferences
    let page: String
    let title: String
    @AppStorage("nativeAppearance") private var appearance = "system"
    var body: some View {
        Form {
            switch page {
            case "navigation": navigation
            case "dashboard": dashboard
            case "expenses": expenses
            case "tasks": tasks
            default: appearanceSettings
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private var navigation: some View {
        Section {
            Picker("Abrir o app em", selection: $layout.startPage) { Text("Visão geral").tag("dashboard"); Text("Despesas").tag("expenses"); Text("Tarefas").tag("tasks") }
            Toggle("Mostrar barra inferior", isOn: $layout.showBottomBar)
            Toggle("Cabeçalhos compactos", isOn: $layout.compactHeader)
            Toggle("Busca nas telas financeiras", isOn: $layout.showSearch)
            Toggle("Mostrar mês em aberto", isOn: $layout.showMonth)
            NavigationLink("Ordem das três abas principais") { NativeLayoutOrder(layout: $layout, dashboard: false) }
            Text("Lançamentos e Compartilhados ficam no menu lateral. Com a barra inferior oculta, use esse menu para navegar.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var dashboard: some View {
        Section {
            NavigationLink("Mostrar, ocultar e ordenar seções") { NativeLayoutOrder(layout: $layout, dashboard: true) }
            Toggle("Incluir despesas já pagas", isOn: $layout.dashboardShowPaid)
            Picker("Quantidade de cards", selection: $layout.dashboardExpenseLimit) { Text("Todos").tag(0); Text("3 despesas").tag(3); Text("5 despesas").tag(5); Text("10 despesas").tag(10) }
            Text("Os cards usam o mesmo layout escolhido em Despesas.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var expenses: some View {
        Group {
            Section("Formato dos cards") {
                Picker("Estilo", selection: $layout.cardStyle) { Text("Cards completos").tag("cards"); Text("Cards compactos").tag("compact") }
                Picker("Colunas", selection: $layout.cardColumns) { ForEach(1...4, id: \.self) { Text("\($0) \($0 == 1 ? "coluna" : "colunas")").tag($0) } }
                Text("Em 3 ou 4 colunas, toque para abrir os detalhes, segure para ver ações ou arraste um card sobre outro para reorganizar.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Mostrar ícone", isOn: $layout.cardShowIcon)
                Toggle("Mostrar tipo de despesa", isOn: $layout.cardShowType)
                Toggle("Mostrar divisão e pagamentos", isOn: $layout.cardShowShare)
                Toggle("Mostrar composição da fatura", isOn: $layout.cardShowBreakdown)
                Toggle("Mostrar ações rápidas", isOn: $layout.cardShowActions)
                Slider(value: $layout.cardRadius, in: 8...30, step: 2) { Text("Arredondamento") } minimumValueLabel: { Text("Reto").font(.caption) } maximumValueLabel: { Text("Redondo").font(.caption) }
            }
            Section("Organização") {
                Picker("Ordenar despesas", selection: $layout.expenseOrder) { Text("Ordem do sistema").tag("manual"); Text("Nome").tag("name"); Text("Maior valor").tag("amount"); Text("Pendentes primeiro").tag("pending") }
                Picker("Agrupar", selection: $layout.expenseGrouping) { Text("Sem grupos").tag("none"); Text("Tipo").tag("type"); Text("Situação").tag("status") }
                Picker("Filtro inicial", selection: $layout.expenseDefaultFilter) { Text("Ativas").tag("active"); Text("Todas").tag("all"); Text("Pendentes").tag("pending"); Text("Pagas").tag("paid"); Text("Desativadas").tag("inactive") }
                Text("No menu ⋯ de cada card, fixe as despesas que quer manter no início.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private var tasks: some View {
        Section {
            Picker("Filtro ao abrir", selection: $layout.taskDefaultScope) { Text("Hoje").tag("today"); Text("Atrasadas").tag("overdue"); Text("Próximos 7 dias").tag("next"); Text("Tudo").tag("all") }
            Picker("Visualização inicial", selection: $layout.taskDefaultView) { Text("Lista").tag("list"); Text("Calendário").tag("calendar"); Text("Hábitos").tag("habits") }
            Toggle("Atalhos Hoje, Atrasadas e Próximas", isOn: $layout.taskShowSummaries)
            Toggle("Agrupar tarefas por prazo", isOn: $layout.taskGroupByDate)
            Toggle("Mostrar categoria nas tarefas", isOn: $layout.taskShowCategory)
            Toggle("Mostrar valores", isOn: $layout.taskShowAmounts)
            Toggle("Mostrar etiquetas", isOn: $layout.taskShowTags)
            Toggle("Campo de captura rápida", isOn: $layout.taskQuickCapture)
            Toggle("Mostrar concluídas abaixo das pendentes", isOn: $layout.taskShowCompleted)
        }
    }
    private var appearanceSettings: some View {
        Group {
            Section { NativeLayoutPreview(layout: layout) }
            Section {
                Picker("Aparência", selection: $appearance) { Text("Sistema").tag("system"); Text("Clara").tag("light"); Text("Escura").tag("dark") }
                Picker("Espaçamento", selection: $layout.density) { Text("Compacto").tag("compact"); Text("Confortável").tag("comfortable"); Text("Amplo").tag("spacious") }
                LabeledContent("Tamanho do texto", value: "\(Int(layout.textScale * 100))%")
                Slider(value: $layout.textScale, in: 0.85...1.3, step: 0.05)
                Toggle("Números com fonte arredondada", isOn: $layout.roundedValues)
                Text("Os ajustes são aplicados às listas e cards deste iPhone.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
struct NativeLayoutOrder: View {
    @Binding var layout: NativeLayoutPreferences
    let dashboard: Bool
    private let names = ["dashboard": "Visão geral", "expenses": "Despesas", "tasks": "Tarefas", "balance": "Renda e saldo", "totals": "Resumos do mês", "pending": "Pendências", "shortcuts": "Atalhos e fechamento"]
    var body: some View {
        List {
            ForEach(dashboard ? layout.dashboardOrder : layout.tabOrder, id: \.self) { key in
                if dashboard { Toggle(names[key] ?? key, isOn: Binding(get: { !layout.dashboardHidden.contains(key) }, set: { visible in layout.dashboardHidden.removeAll { $0 == key }; if !visible { layout.dashboardHidden.append(key) } })) }
                else { Text(names[key] ?? key) }
            }.onMove { offsets, target in if dashboard { layout.dashboardOrder.move(fromOffsets: offsets, toOffset: target) } else { layout.tabOrder.move(fromOffsets: offsets, toOffset: target) } }
        }.environment(\.editMode, .constant(.active)).navigationTitle(dashboard ? "Seções da visão geral" : "Ordem das abas").navigationBarTitleDisplayMode(.inline)
    }
}
