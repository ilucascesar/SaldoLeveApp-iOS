import SwiftUI

enum NativeAppSection: String, CaseIterable, Identifiable {
    case dashboard = "Visão geral", expenses = "Despesas", transactions = "Lançamentos", shared = "Compartilhados", tasks = "Tarefas"
    var id: String { rawValue }
    var key: String { switch self { case .dashboard: return "dashboard"; case .expenses: return "expenses"; case .transactions: return "transactions"; case .shared: return "shared"; case .tasks: return "tasks" } }
    init(key: String) { self = Self.allCases.first { $0.key == key } ?? .tasks }
    var icon: String { switch self { case .dashboard: return "house"; case .expenses: return "wallet.pass"; case .transactions: return "list.bullet.rectangle"; case .shared: return "person.2"; case .tasks: return "checkmark.circle" } }
}
struct NativeAppShell: View {
    @ObservedObject var store: NativeStore
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                TabView(selection: $store.section) {
                    ForEach(store.layout.tabOrder.filter { store.platform.visibleMenu.contains($0) }, id: \.self) { key in
                        let section = NativeAppSection(key: key)
                        Group {
                            if section == .tasks { NativeTaskList(store: store) }
                            else { NativeFinanceScreen(store: store, finance: store.finance, section: section) }
                        }.tabItem { Label(store.platform.label(section.key), systemImage: section.icon) }.tag(section)
                    }
                }.toolbar(store.layout.showBottomBar ? .visible : .hidden, for: .tabBar)
                if !store.menuOpen {
                    NativeEdgeSwipe {
                        if store.section == .tasks { store.taskDrawerRequested = true }
                        else { store.menuOpen = true }
                    }.frame(maxHeight: .infinity)
                }
                if store.menuOpen {
                    Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { closeMenu() }
                    NativeAppDrawer(store: store).frame(width: min(340, geometry.size.width * 0.88))
                        .modifier(NativeDrawerSwipeClose { closeMenu() })
                        .background(nativePaper).transition(.move(edge: .leading)).shadow(radius: 18)
                }
            }.animation(.easeInOut(duration: 0.2), value: store.menuOpen)
        }.onChange(of: store.platform.snapshot.revision) { _ in if !store.platform.visibleMenu.contains(store.section.key) { store.section = .tasks } }
        .onChange(of: store.openedTask?.id) { id in if id != nil { store.section = .tasks } }
            .sheet(item: $store.openedFinance) { NativeFinanceModal(finance: store.finance, route: $0) }
            .onAppear {
                #if DEBUG
                let flags = ProcessInfo.processInfo.arguments
                if flags.contains("--preview-review") { Task { _ = await NativeWarningPresenter.confirm([["field": .string("invoice.totalCents"), "before": .number(100000), "after": .number(10000000), "message": .string("Confira o valor da fatura.")]]) } }
                if flags.contains("--preview-expenses") || flags.contains("--preview-columns4") { store.section = .expenses }
                if flags.contains("--preview-dashboard") || flags.contains("--preview-menu") { store.section = .dashboard }
                if flags.contains("--preview-menu") { store.menuOpen = true }
                if flags.contains("--preview-birthdays") { store.openedFinance = .init(kind: "birthdays") }
                if flags.contains("--preview-remote") { store.openedFinance = .init(kind: "remote") }
                if flags.contains("--preview-search") { store.openedFinance = .init(kind: "search") }
                if flags.contains("--preview-layout") { store.openedFinance = .init(kind: "layout") }
                if flags.contains("--preview-focus") { store.openedFinance = .init(kind: "focus") }
                if flags.contains("--preview-widgets") { store.openedFinance = .init(kind: "widgets") }
                if flags.contains("--preview-notifications") { store.openedFinance = .init(kind: "previewNotifications") }
                #endif
            }
    }
    private func closeMenu() { store.menuOpen = false }
}
struct NativeAppDrawer: View {
    @ObservedObject var store: NativeStore
    @ObservedObject private var platform: NativePlatformStore
    init(store: NativeStore) { self.store = store; self.platform = store.platform }
    private let icons = ["dashboard":"house", "expenses":"wallet.pass", "tasks":"checkmark.circle", "birthdays":"gift", "search":"magnifyingglass", "transactions":"list.bullet.rectangle", "shared":"person.2", "focus":"sun.max", "layout":"slider.horizontal.3", "remote":"gearshape.2", "widgets":"square.grid.2x2", "notifications":"bell.badge", "profile":"person.crop.circle"]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("S").font(.title2.bold()).foregroundStyle(.white).frame(width: 43, height: 43).background(nativeBlue, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) { Text(platform.text("appTitle", fallback: "SaldoLeve")).font(.headline); Text(store.user?.name ?? "Meu espaço").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button { store.menuOpen = false } label: { Image(systemName: "xmark").frame(width: 40, height: 44) }.accessibilityLabel("Fechar menu")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(platform.visibleMenu, id: \.self) { key in
                        line(platform.label(key), icon: icons[key] ?? "circle", active: ["tasks", "expenses", "dashboard"].contains(key) && store.section.key == key) {
                            if ["tasks", "expenses", "dashboard"].contains(key) { store.section = NativeAppSection(key: key); store.menuOpen = false }
                            else { open(["transactions":"moduleTransactions", "shared":"moduleShared", "notifications":"previewNotifications"][key] ?? key) }
                        }
                    }
                    DisclosureGroup("Categorias de tarefas") {
                        ForEach(store.snapshot.lists.filter { !$0.archived }) { category in
                            line(category.name, icon: "circle.fill") { store.section = .tasks; store.taskCategoryRequest = category.id; store.menuOpen = false }
                        }
                    }.font(.subheadline).padding(.horizontal, 14).padding(.vertical, 12)
                }.padding(10)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }
    private func heading(_ title: String) -> some View { Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 6) }
    private func line(_ title: String, icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 15, weight: active ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(minHeight: 46).foregroundStyle(active ? nativeBlue : Color.primary).background(active ? nativeBlue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
    }
    private func open(_ kind: String) { store.menuOpen = false; store.openedFinance = .init(kind: kind) }
}
struct NativeDailyFocus: View {
    @ObservedObject var store: NativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var horizon = 7
    @State private var editing: NativeTask?
    @State private var daily: [String: [NativeTask]] = [:]
    private let scopes: [TaskScope] = [.today, .overdue, .upcoming]
    private func tasks(_ scope: TaskScope) -> [NativeTask] {
        daily[scope == .upcoming ? "upcoming" : scope.key] ?? []
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { ForEach(scopes) { scope in VStack(alignment: .leading, spacing: 4) { Text(scope == .upcoming ? "Próximas" : scope.rawValue).font(.caption).foregroundStyle(.secondary); Text("\(tasks(scope).count) \(tasks(scope).count == 1 ? "tarefa" : "tarefas")").font(.subheadline.weight(.semibold)) }.frame(maxWidth: .infinity, alignment: .leading) } }
                    Stepper("Próximas: \(horizon) dias", value: $horizon, in: 1...30)
                }
                ForEach(scopes) { scope in
                    Section(scope == .upcoming ? "Próximas · \(horizon) dias" : scope.rawValue) {
                        if tasks(scope).isEmpty { Text("Tudo em dia").foregroundStyle(.secondary) }
                        ForEach(tasks(scope)) { task in NativeTaskRow(store: store, task: task, onOpen: { editing = task }) }
                    }
                }
            }.listStyle(.insetGrouped).navigationTitle("Meu dia").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }; ToolbarItem(placement: .primaryAction) { NavigationLink { NativeWidgetSettings(store: store) } label: { Image(systemName: "slider.horizontal.3") } } }
                .sheet(item: $editing) { NativeTaskEditor(store: store, original: $0) }
                .onAppear { let saved = UserDefaults.standard.integer(forKey: "nativeWidgetHorizon"); if (1...30).contains(saved) { horizon = saved } }
                .onChange(of: horizon) { UserDefaults.standard.set($0, forKey: "nativeWidgetHorizon") }
                .task(id: store.taskIndex.revision.uuidString + "|" + String(horizon)) {
                    let snapshot = store.snapshot, days = horizon
                    let result = await Task.detached(priority: .userInitiated) { Dictionary(uniqueKeysWithValues: ["today", "overdue", "upcoming"].map { ($0, NativeDailyQuery.select(snapshot, state: $0, days: days)) }) }.value
                    if !Task.isCancelled { daily = result }
                }
                .refreshable { await store.refresh() }
        }
    }
}
