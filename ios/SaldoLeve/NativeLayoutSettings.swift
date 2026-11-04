import SwiftUI

struct NativeLayoutSettings: View {
    @ObservedObject var store: NativeStore
    @ObservedObject private var platform: NativePlatformStore
    @State private var layout = NativeLayoutPreferences()
    @State private var revision = 0
    @State private var working = false
    @State private var issue: String?
    @State private var reset = false
    @State private var initialized = false
    @State private var screen: NativeSimulatorScreen = .expenses
    @State private var fullSimulator = false
    private let embedded: Bool
    init(store: NativeStore, embedded: Bool = false) { self.store = store; self.platform = store.platform; self.embedded = embedded }
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
    private var content: some View {
            Form {
                Section {
                    destination("Navegação e tela inicial", icon: "sidebar.left", page: "navigation")
                    destination("Despesas: resumo e seções", icon: "rectangle.grid.2x2", page: "dashboard")
                    destination("Cards e organização de despesas", icon: "wallet.pass", page: "expenses")
                    destination("Agenda e captura rápida", icon: "checklist", page: "tasks")
                    destination("Tarefa aberta e subtarefas", icon: "list.bullet.rectangle", page: "taskDetail")
                    destination("Texto, espaço e aparência", icon: "textformat.size", page: "appearance")
                    NavigationLink { NativeWidgetSettings(store: store) } label: { Label("Widgets da Tela de Início", systemImage: "square.grid.2x2") }.accessibilityIdentifier("layout-widgets")
                } header: { Text("Personalizar") } footer: { Text("O simulador acima mostra cada alteração na hora, com seus dados. Toque em Salvar para aplicar na conta e nos outros dispositivos.") }
                Section { Button("Restaurar layout padrão", role: .destructive) { reset = true } }
            if let issue { Section { Text(issue).font(.footnote) } }
            }.disabled(!platform.canWrite || working).navigationTitle("Layout e personalização").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) { NativeSimulatorPanel(store: store, layout: layout, screen: $screen) { fullSimulator = true } }
                .sheet(isPresented: $fullSimulator) { NativeSimulatorFullScreen(store: store, draft: layout, screen: $screen) }
                .toolbar {
                    if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.disabled(working) } }
                    ToolbarItem(placement: .confirmationAction) { Button("Salvar", action: saveChanges).disabled(!platform.canWrite || working) }
                }
                .task { guard !initialized else { return }; await platform.refresh(); guard !Task.isCancelled else { return }; layout = store.layout; revision = platform.snapshot.revision; initialized = true }
                .onChange(of: store.offline) { offline in guard offline, !working else { return }; layout = store.layout; revision = platform.snapshot.revision; issue = "Sem conexão. Alterações de layout não confirmadas foram descartadas." }
                .onChange(of: platform.snapshot.revision) { next in guard !working, next != revision else { return }; layout = store.layout; revision = next; issue = "Layout atualizado com a versão do servidor." }
                .confirmationDialog("Restaurar o layout padrão?", isPresented: $reset, titleVisibility: .visible) { Button("Restaurar layout") { layout = NativeLayoutPreferences() } } message: { Text("O simulador mostra o resultado; toque em Salvar para aplicar. Seus dados, pagamentos, tarefas e notificações permanecem salvos.") }
    }
    private func saveChanges() {
        guard platform.canWrite, !working else { return }
        working = true; issue = nil
        Task { defer { working = false }; do { try await platform.saveLayout(layout, revision: revision); dismiss() } catch { issue = error.localizedDescription } }
    }
    private func destination(_ title: String, icon: String, page: String) -> some View { NavigationLink { NativeLayoutDetail(store: store, layout: $layout, screen: $screen, page: page, title: title, canSave: platform.canWrite && !working, issue: issue, save: saveChanges) } label: { Label(title, systemImage: icon) }.accessibilityIdentifier("layout-" + page) }
}
struct NativeLayoutDetail: View {
    @ObservedObject var store: NativeStore
    @Binding var layout: NativeLayoutPreferences
    @Binding var screen: NativeSimulatorScreen
    let page: String
    let title: String
    let canSave: Bool
    let issue: String?
    let save: () -> Void
    @State private var fullSimulator = false
    private var naturalScreen: NativeSimulatorScreen? {
        switch page {
        case "dashboard", "expenses": return .expenses
        case "tasks": return .agenda
        case "taskDetail": return .task
        case "navigation": return layout.startPage == "tasks" ? .agenda : .expenses
        default: return nil
        }
    }
    var body: some View {
        Form {
            switch page {
            case "navigation": navigation
            case "dashboard": dashboard
            case "expenses": expenses
            case "tasks": tasks
            case "taskDetail": taskDetail
            default: appearanceSettings
            }
            if let issue { Section { Text(issue).foregroundStyle(.red).font(.footnote) } }
        }.disabled(!canSave).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { NativeSimulatorPanel(store: store, layout: layout, screen: $screen) { fullSimulator = true } }
            .sheet(isPresented: $fullSimulator) { NativeSimulatorFullScreen(store: store, draft: layout, screen: $screen) }
            .onAppear { if let naturalScreen { screen = naturalScreen } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Salvar", action: save).disabled(!canSave).accessibilityIdentifier("layout-save") } }
    }
    private var navigation: some View {
        Section {
            Picker("Abrir o app em", selection: $layout.startPage) { Text(store.platform.label("dashboard")).tag("dashboard"); Text(store.platform.label("tasks")).tag("tasks") }
            Toggle("Mostrar barra inferior", isOn: $layout.showBottomBar)
            Toggle("Cabeçalhos compactos", isOn: $layout.compactHeader)
            Toggle("Busca nas telas financeiras", isOn: $layout.showSearch)
            Toggle("Mostrar mês em aberto", isOn: $layout.showMonth)
            NavigationLink("Ordem das abas") { NativeLayoutOrder(store: store, layout: $layout, dashboard: false, canSave: canSave, save: save) }
            Text("As abas principais são \(store.platform.label("dashboard")) e \(store.platform.label("tasks")). Lançamentos e Compartilhados ficam no menu lateral; com a barra inferior oculta, use esse menu para navegar.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var dashboard: some View {
        Section {
            Toggle("Mostrar Pendências do mês", isOn: Binding(get: { !layout.dashboardHidden.contains("pending") }, set: { shown in
                layout.dashboardHidden.removeAll { $0 == "pending" }; if !shown { layout.dashboardHidden.append("pending") }
            })).accessibilityIdentifier("dashboard-pending-visibility")
            NavigationLink("Outras seções e ordem") { NativeLayoutOrder(store: store, layout: $layout, dashboard: true, canSave: canSave, save: save) }.accessibilityIdentifier("layout-dashboard-order")
            Toggle("Incluir despesas já pagas", isOn: $layout.dashboardShowPaid)
            Picker("Quantidade de cards", selection: $layout.dashboardExpenseLimit) { Text("Todos").tag(0); Text("3 despesas").tag(3); Text("5 despesas").tag(5); Text("10 despesas").tag(10) }
            Text("A aba Despesas reúne o mês em aberto, os resumos, os filtros e os cards. Toque em Salvar para confirmar na sua conta.").font(.footnote).foregroundStyle(.secondary)
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
                Picker("Filtro inicial", selection: $layout.expenseDefaultFilter) { Text("Todas").tag("all"); Text("Ativas").tag("active"); Text("Pendentes").tag("pending"); Text("Pagas").tag("paid"); Text("Desativadas").tag("inactive") }
                Text("No menu ⋯ de cada card, fixe as despesas que quer manter no início.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private var tasks: some View {
        Section {
            Text("A aba inicial da Agenda é sempre Tudo.").font(.footnote).foregroundStyle(.secondary)
            NativeTaskFilterControls(sort: $layout.taskDefaultSort, filter: $layout.taskDateFilter)
            Picker("Visualização inicial", selection: $layout.taskDefaultView) { Text("Lista").tag("list"); Text("Calendário").tag("calendar"); Text("Hábitos").tag("habits") }
            Toggle("Atalhos Tudo, Hoje, Atrasadas e Próximas", isOn: $layout.taskShowSummaries)
            Toggle("Agrupar tarefas por prazo", isOn: $layout.taskGroupByDate)
            Toggle("Mostrar categoria nas tarefas", isOn: $layout.taskShowCategory)
            Toggle("Mostrar valores", isOn: $layout.taskShowAmounts)
            Toggle("Mostrar etiquetas", isOn: $layout.taskShowTags)
            Toggle("Campo de captura rápida", isOn: $layout.taskQuickCapture)
            Toggle("Mostrar concluídas abaixo das pendentes", isOn: $layout.taskShowCompleted)
        }
    }
    private var taskDetail: some View {
        Group {
            Section {
                ForEach(NativeLayoutPreferences.taskDetailStyles, id: \.self) { style in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { layout.applyTaskDetailPreset(style) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: NativeTaskDetailLayout.icons[style] ?? "list.bullet").font(.system(size: 18)).foregroundStyle(nativeBlue).frame(width: 32, height: 32).background(nativeBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) { Text(NativeTaskDetailLayout.names[style] ?? style).foregroundStyle(.primary); Text(NativeTaskDetailLayout.summaries[style] ?? "").font(.caption).foregroundStyle(.secondary) }
                            Spacer(minLength: 4)
                            if layout.taskDetailLayout == style { Image(systemName: "checkmark.circle.fill").foregroundStyle(nativeBlue) }
                        }
                    }.accessibilityIdentifier("task-detail-style-" + style).accessibilityAddTraits(layout.taskDetailLayout == style ? .isSelected : [])
                }
            } header: { Text("Estilo") } footer: { Text("Escolher um estilo aplica as opções recomendadas. Depois, personalize cada detalhe abaixo.") }
            Section {
                Picker("Agrupar subtarefas", selection: $layout.taskDetailGrouping) { ForEach(NativeLayoutPreferences.taskDetailGroupings, id: \.self) { Text(NativeTaskDetailLayout.groupingNames[$0] ?? $0).tag($0) } }
                Picker("Densidade", selection: $layout.taskDetailDensity) { Text("Normal").tag("regular"); Text("Compacta").tag("compact") }
                Toggle("Mostrar concluídas abertas", isOn: $layout.taskDetailExpandDone)
            } header: { Text("Organização") } footer: { Text("Grupos podem ser recolhidos tocando no título.") }
            Section {
                Toggle("Destacar a próxima pendência", isOn: $layout.taskDetailHighlightNext)
                Toggle("Situação colorida (Atrasada, Hoje, Em 3 dias)", isOn: $layout.taskDetailPills)
                Toggle("Data em cada subtarefa", isOn: $layout.taskDetailMetadata)
                Toggle("Valor em cada subtarefa", isOn: $layout.taskDetailAmounts)
                Toggle("Numerar subtarefas", isOn: $layout.taskDetailNumbers)
                Toggle("Progresso no título do grupo", isOn: $layout.taskDetailProgress)
            } header: { Text("Detalhes de cada linha") } footer: { Text("O progresso aparece discreto ao lado do título, sem empurrar as subtarefas para baixo. Sem a data na linha, use o menu ⋯ para alterá-la.") }
        }
    }
    private var appearanceSettings: some View {
        Section {
            Picker("Espaçamento", selection: $layout.density) { Text("Compacto").tag("compact"); Text("Confortável").tag("comfortable"); Text("Amplo").tag("spacious") }
            LabeledContent("Tamanho do texto", value: "\(Int(layout.textScale * 100))%")
            Slider(value: $layout.textScale, in: 0.85...1.3, step: 0.05)
            Toggle("Números com fonte arredondada", isOn: $layout.roundedValues)
            Text("Os ajustes valem para listas e cards. Troque a tela no simulador para conferir cada uma.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
struct NativeLayoutOrder: View {
    @ObservedObject var store: NativeStore
    @Binding var layout: NativeLayoutPreferences
    let dashboard: Bool
    let canSave: Bool
    let save: () -> Void
    private let names = ["balance": "Renda e saldo", "totals": "Resumos do mês", "expenses": "Filtros e cards de despesas", "pending": "Pendências do mês", "shortcuts": "Atalhos e fechamento"]
    var body: some View {
        List {
            ForEach(dashboard ? layout.dashboardOrder : layout.tabOrder, id: \.self) { key in
                if dashboard && key != "pending" { Toggle(names[key] ?? key, isOn: Binding(get: { !layout.dashboardHidden.contains(key) }, set: { visible in layout.dashboardHidden.removeAll { $0 == key }; if !visible { layout.dashboardHidden.append(key) } })) }
                else { Text(dashboard ? names[key] ?? key : store.platform.label(key)) }
            }.onMove { offsets, target in if dashboard { layout.dashboardOrder.move(fromOffsets: offsets, toOffset: target) } else { layout.tabOrder.move(fromOffsets: offsets, toOffset: target) } }
        }.environment(\.editMode, .constant(.active)).navigationTitle(dashboard ? "Seções de Despesas" : "Ordem das abas").navigationBarTitleDisplayMode(.inline)
            .disabled(!canSave).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Salvar", action: save).disabled(!canSave) } }
    }
}
