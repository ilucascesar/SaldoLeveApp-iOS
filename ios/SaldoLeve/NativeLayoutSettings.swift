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
    init(store: NativeStore, embedded: Bool = false, initialScreen: NativeSimulatorScreen? = nil) { self.store = store; self.platform = store.platform; self.embedded = embedded; _screen = State(initialValue:initialScreen ?? .expenses) }
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
    private var content: some View {
            Form {
                Section {
                    switch screen {
                    case .expenses:
                        destination("Resumo e seções de Despesas",icon:"rectangle.grid.2x2",page:"dashboard")
                        destination("Cards e organização de Despesas",icon:"wallet.pass",page:"expenses")
                    case .agenda:
                        destination("Lista, filtros e calendário",icon:"checklist",page:"tasks")
                    case .task:
                        destination("Personalizar modelo compacto",icon:"list.bullet.rectangle",page:"taskDetail")
                    case .general:
                        destination("Navegação do aplicativo",icon:"sidebar.left",page:"navigation")
                        destination("Texto e espaço do aplicativo",icon:"textformat.size",page:"appearance")
                    }
                } header: { Text(screen.rawValue) } footer: { Text(screen == .task ? "Configure o modelo aqui e aplique dentro de cada tarefa, no menu de copiar e compartilhar a lista. Nome, data e anexo continuam visíveis." : "Somente os ajustes desta área aparecem aqui. O simulador acompanha a área escolhida. Salve para confirmar na conta.") }
                Section { Button("Restaurar ajustes desta área",role:.destructive) { reset = true } }
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
                .confirmationDialog("Restaurar os ajustes desta área?", isPresented: $reset, titleVisibility: .visible) { Button("Restaurar layout") { layout.resetArea(screen.key) } } message: { Text("O simulador mostra o resultado. As outras áreas e as escolhas individuais das tarefas serão preservadas. Toque em Salvar para aplicar.") }
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
        case "navigation", "appearance": return .general
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
            .safeAreaInset(edge: .top, spacing: 0) { NativeSimulatorPanel(store: store, layout: layout, screen: $screen, allowedScreens:[naturalScreen ?? screen]) { fullSimulator = true } }
            .sheet(isPresented: $fullSimulator) { NativeSimulatorFullScreen(store: store, draft: layout, screen: $screen, allowedScreens:[naturalScreen ?? screen]) }
            .onAppear { if let naturalScreen { screen = naturalScreen } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Salvar", action: save).disabled(!canSave).accessibilityIdentifier("layout-save") } }
    }
    private var navigation: some View {
        Section {
            Picker("Abrir o app em", selection: $layout.startPage) { Text(store.platform.label("dashboard")).tag("dashboard"); Text(store.platform.label("tasks")).tag("tasks") }
            Toggle("Mostrar barra inferior", isOn: $layout.showBottomBar)
            Toggle("Cabeçalhos compactos", isOn: $layout.compactHeader)
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
            Section("Cabeçalho de Despesas") {
                Toggle("Busca em Despesas",isOn:$layout.showSearch)
                Toggle("Mostrar mês em aberto",isOn:$layout.showMonth)
            }
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
            Section("Formato por tipo de despesa") {
                ForEach(["home", "card", "other"], id: \.self) { type in
                    Picker(NativeFinanceFormat.expenseType(type), selection: styleBinding(type, expense: true)) {
                        Text("Usar padrão").tag("")
                        Text("Completo").tag("cards")
                        Text("Compacto").tag("compact")
                    }
                }
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
                Text("Nome, data e indicador de anexo ficam sempre visíveis no compacto.").font(.footnote).foregroundStyle(.secondary)
                Picker("Espaçamento",selection:$layout.taskCompactSpacing) { Text("Enxuto").tag("tight");Text("Confortável").tag("comfortable") }
                LabeledContent("Tamanho do nome",value:"\(Int(layout.taskCompactTextScale * 100))%")
                Slider(value:$layout.taskCompactTextScale,in:0.85...1.3,step:0.05).accessibilityLabel("Tamanho do nome no compacto")
                Toggle("Numerar subtarefas",isOn:$layout.taskCompactNumbers)
                Toggle("Mostrar valor separado",isOn:$layout.taskCompactAmounts)
                Toggle("Progresso no título do grupo",isOn:$layout.taskCompactProgress)
            } header: { Text("Modelo compacto reutilizável") } footer: { Text("Configurar o modelo não muda todas as tarefas. Para aplicá-lo, abra uma tarefa e use Layout das subtarefas no menu de copiar e compartilhar. O menu de cada subtarefa permite uma escolha individual.") }
        }
    }
    private func styleBinding(_ key: String, expense: Bool) -> Binding<String> {
        Binding(get: { (expense ? layout.expenseCategoryStyles : layout.taskCategoryLayouts)[key] ?? "" }, set: { style in
            if expense { layout.expenseCategoryStyles[key] = style.isEmpty ? nil : style }
            else { layout.taskCategoryLayouts[key] = style.isEmpty ? nil : style }
        })
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
