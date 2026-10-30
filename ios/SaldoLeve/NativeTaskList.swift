import SwiftUI

enum NativeWorkspacePage: String, CaseIterable, Identifiable {
    case list = "Categorias", calendar = "Calendário", habits = "Hábitos"
    var id: String { rawValue }
    var icon: String { self == .list ? "list.bullet" : self == .calendar ? "calendar" : "target" }
}
struct NativeTaskList: View {
    @ObservedObject var store: NativeStore
    var title = "Tarefas"
    var categoryID: String? = nil
    var day: Date? = nil
    @State private var category = ""
    @State private var scope: TaskScope = .all
    @State private var page: NativeWorkspacePage = .list
    @State private var sort: NativeTaskSort = .due
    @State private var tag = ""
    @State private var search = ""
    @State private var searching = false
    @State private var drawer = false
    @State private var profile = false
    @State private var categoryEditor = false
    @State private var editingCategory: NativeCategory?
    @State private var history = false
    @State private var trash: NativeTask?
    @State private var selected = Set<String>()
    @State private var selecting = false
    @State private var bulkTrash = false
    @State private var collapsed = Set<String>(["done"])
    @State private var quick = ""
    @State private var pendingQuick: NativeTask?
    @State private var adding = false
    @State private var calendarDay = Date()
    @State private var savingFilter = false
    @State private var filterName = ""
    @State private var tools = false
    @State private var initialized = false
    @FocusState private var quickFocused: Bool
    @FocusState private var searchFocused: Bool
    private var currentCategory: NativeCategory? { store.snapshot.lists.first { $0.id == category } }
    private var heading: String { page == .habits ? "Meus hábitos" : page == .calendar ? (currentCategory?.name ?? "Calendário") : currentCategory?.name ?? (tag.isEmpty ? (scope == .all ? store.platform.text("tasksHeading", fallback: scope.rawValue) : scope.rawValue) : "#" + tag) }
    private var canAdd: Bool { store.user != nil && store.networkAvailable && !store.offline && !store.needsSync && (scope != .trash && !store.editableCategories.isEmpty && (currentCategory == nil || currentCategory?.canEdit == true)) }
    private func query(includeDone: Bool = false) -> [NativeTask] { NativeTaskQuery.select(store.snapshot, scope: page == .calendar ? .all : scope, categoryID: category, tag: tag, search: search, sort: sort, userID: store.user?.id ?? "", includeDone: includeDone) }
    @State private var projection = NativeTaskProjection()
    @State private var loadedRequest: NativeTaskRequest?
    @State private var projecting = false
    private var items: [NativeTask] { loadedRequest?.revision == store.taskIndex.revision ? projection.items : [] }
    private var groups: [NativeTaskGroup] { loadedRequest?.revision == store.taskIndex.revision ? projection.groups : [] }
    private var request: NativeTaskRequest {
        NativeTaskRequest(revision: store.taskIndex.revision, scope: scope.key, category: category, tag: tag, search: search, sort: sort.rawValue, page: page == .calendar ? "calendar" : page == .habits ? "habits" : "list", day: page == .calendar ? Calendar.current.startOfDay(for: calendarDay) : nil, groupDates: store.layout.taskGroupByDate, showDone: store.layout.taskShowCompleted, userID: store.user?.id ?? "")
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    VStack(spacing: 0) { header; viewTabs; if searching { searchBar }; if page == .habits { NativeHabitsView(store: store) } else if scope == .trash && page == .list { NativeTrashCollection(store: store) } else { taskCollection } }.background(nativeCanvas)
                    if drawer {
                        Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { closeDrawer() }.transition(.opacity)
                        drawerContent.frame(width: min(330, geometry.size.width * 0.86)).frame(maxHeight: .infinity).background(nativePaper).transition(.move(edge: .leading)).shadow(color: .black.opacity(0.12), radius: 20, x: 8)
                            .modifier(NativeDrawerSwipeClose { closeDrawer() })
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) {
                if !drawer && page != .habits && canAdd && !quickFocused && !searchFocused && !selecting {
                    Button { newTask() } label: { Image(systemName: "plus").font(.system(size: 24, weight: .medium)).foregroundStyle(.white).frame(width: 54, height: 54).background(nativeBlue, in: Circle()).shadow(color: nativeBlue.opacity(0.28), radius: 10, y: 5) }.accessibilityLabel("Nova tarefa").padding(.trailing, 20).padding(.bottom, 16).disabled(store.working)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { bulkBar } }
            .sheet(isPresented: $profile) { NativeProfileView(store: store) }
            .sheet(isPresented: $categoryEditor) { NativeCategoryEditor(store: store, original: editingCategory) }
            .sheet(isPresented: $history) { NativeGlobalHistoryView(store: store, categoryID: category) }
            .sheet(isPresented: $tools) { NativeCollectionTools(store: store, categoryID: category, items: query(includeDone: true)) }
            .confirmationDialog("Mover para a lixeira?", isPresented: Binding(get: { trash != nil }, set: { if !$0 { trash = nil } }), titleVisibility: .visible) {
                Button("Mover tarefa para a lixeira", role: .destructive) { if let task = trash { Task { await store.changeStatus(task, to: "trashed") } }; trash = nil }
            } message: { Text(trash?.title ?? "") }
            .confirmationDialog("Mover as selecionadas para a lixeira?", isPresented: $bulkTrash, titleVisibility: .visible) { Button("Mover para a lixeira", role: .destructive) { bulk("trash") } }
            .alert("Salvar filtro", isPresented: $savingFilter) { TextField("Nome do filtro", text: $filterName); Button("Cancelar", role: .cancel) {}; Button("Salvar") { saveFilter() } } message: { Text("Guarda categoria, busca, etiqueta e filtro, também no site.") }
            .onAppear {
                if !initialized { scope = TaskScope(key: store.layout.taskDefaultScope); page = store.layout.taskDefaultView == "calendar" ? .calendar : store.layout.taskDefaultView == "habits" ? .habits : .list; initialized = true }
                if let categoryID { category = categoryID }; if let day { calendarDay = day; page = .calendar }
                consumeNavigation()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-drawer") { drawer = true }
                if ProcessInfo.processInfo.arguments.contains("--preview-calendar") { page = .calendar }; if ProcessInfo.processInfo.arguments.contains("--preview-habits") { page = .habits }
                #endif
            }
            .task(id: request) {
                let key = request
                guard key.page != "habits", key != loadedRequest else { projecting = false; return }
                projecting = true
                let snapshot = store.snapshot
                let next = await Task.detached(priority: .userInitiated) { NativeTaskProjection(snapshot, request: key) }.value
                guard !Task.isCancelled else { return }
                projection = next; loadedRequest = key; projecting = false
            }
            .onChange(of: store.taskCategoryRequest) { _ in consumeNavigation() }
            .onChange(of: store.taskScopeRequest) { _ in consumeNavigation() }
            .onChange(of: store.taskDrawerRequested) { requested in if requested { quickFocused = false; searchFocused = false; withAnimation(.easeOut(duration: 0.18)) { drawer = true }; store.taskDrawerRequested = false } }
        }
    }
    private var header: some View {
        HStack(spacing: 2) {
            Button { quickFocused = false; searchFocused = false; withAnimation(.easeInOut(duration: 0.22)) { drawer = true } } label: { Image(systemName: "line.3.horizontal").font(.system(size: 21)).frame(width: 44, height: 44) }.accessibilityLabel("Categorias e filtros")
            Text(heading).font(.system(size: 21, weight: .bold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let category = currentCategory { Image(systemName: category.fields.objects("members").isEmpty ? "lock" : "person.2").font(.system(size: 12)).foregroundStyle(.secondary) }
            Button { withAnimation { searching.toggle() }; searchFocused = searching; if !searching { search = "" } } label: { Image(systemName: "magnifyingglass").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Buscar")
            Menu {
                Picker("Ordenar por", selection: $sort) { ForEach(NativeTaskSort.allCases) { Text($0.rawValue).tag($0) } }
                Button { selecting.toggle(); selected.removeAll() } label: { Label(selecting ? "Cancelar seleção" : "Selecionar tarefas", systemImage: "checkmark.circle") }
                Button { Task { await store.refresh() } } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                Button { filterName = ""; savingFilter = true } label: { Label("Salvar filtro atual", systemImage: "bookmark") }
                Button { history = true } label: { Label("Histórico de pagamentos", systemImage: "clock.arrow.circlepath") }
                if let currentCategory, currentCategory.fields.text("ownerId") == store.user?.id { Button { editingCategory = currentCategory; categoryEditor = true } label: { Label("Editar categoria", systemImage: "folder.badge.gearshape") } }
                Button { tools = true } label: { Label("Resumo, importar e exportar", systemImage: "square.and.arrow.up") }
                Button { profile = true } label: { Label("Configurações", systemImage: "gearshape") }
                if store.platform.enabled("search") { Button { store.openedFinance = .init(kind: "search") } label: { Label(store.platform.label("search"), systemImage: "magnifyingglass") } }
                if store.platform.enabled("birthdays") { Button { store.openedFinance = .init(kind: "birthdays") } label: { Label(store.platform.label("birthdays"), systemImage: "gift") } }
                Button { store.menuOpen = true } label: { Label("Menu do aplicativo", systemImage: "square.grid.2x2") }
            } label: { Image(systemName: "ellipsis").font(.system(size: 21)).frame(width: 44, height: 44) }.accessibilityLabel("Mais opções")
        }.foregroundStyle(.primary).padding(.horizontal, 7).padding(.top, 4).padding(.bottom, 2).background(nativeCanvas)
    }
    private var viewTabs: some View {
        HStack(spacing: 6) {
            ForEach(NativeWorkspacePage.allCases) { value in Button { page = value; selected.removeAll(); selecting = false; UISelectionFeedbackGenerator().selectionChanged() } label: { Label(value.rawValue, systemImage: value.icon).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9).foregroundStyle(page == value ? nativeBlue : Color.secondary).background(page == value ? nativeBlue.opacity(0.1) : .clear, in: Capsule()) }.buttonStyle(.plain).accessibilityIdentifier("workspace-" + (value == .list ? "list" : value == .calendar ? "calendar" : "habits")).accessibilityAddTraits(page == value ? .isSelected : []) }; Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 5)
    }
    private var searchBar: some View {
        HStack(spacing: 10) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Título, texto, etiqueta ou subtarefa…", text: $search).focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }; if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } } }.padding(12).background(nativePaper, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 14).padding(.bottom, 6)
    }
    private var taskCollection: some View {
        List {
            Section {
                if projecting { ProgressView("Organizando tarefas…").font(.caption) }; if page == .list && store.layout.taskShowSummaries { summaries }
                if page == .calendar { NativeCalendarGrid(store: store, selection: $calendarDay, categoryID: category) }
                if !category.isEmpty && store.layout.taskShowAmounts { NativeMoneySummaryLine(store: store, categoryID: category) }
                if canAdd && store.layout.taskQuickCapture { quickAdd }
                if !tag.isEmpty { Button { tag = "" } label: { Label("#\(tag) · limpar etiqueta", systemImage: "xmark.circle") }.font(.caption) }
                if store.offline || store.needsSync { HStack { Label("Sem conexão com o servidor · somente consulta", systemImage: "wifi.slash"); Spacer(); Button("Atualizar") { Task { await store.refresh() } }.disabled(store.refreshing) }.font(.caption).foregroundStyle(.secondary) }
                if store.snapshot.hasMoreItems { Text("Mostrando o limite de 5.000 tarefas da API.").font(.caption).foregroundStyle(.secondary) }
            }.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            if items.isEmpty && !projecting { emptyState }
            ForEach(groups) { group in
                Section {
                    if !collapsed.contains(group.id) || group.title.isEmpty {
                        ForEach(group.items) { task in
                            NativeTaskRow(store: store, task: task, showCategory: category.isEmpty, selecting: selecting, selected: selected.contains(task.id), select: { toggleSelection(task.id) })
                                .listRowBackground(nativePaper).listRowInsets(EdgeInsets(top: store.layout.rowPadding, leading: 10, bottom: store.layout.rowPadding, trailing: 12))
                                .swipeActions(edge: .leading, allowsFullSwipe: false) { if task.isActive || task.isDone { Button { Task { await store.complete(task) } } label: { Label(task.isDone ? "Reabrir" : task.completionLabel, systemImage: "checkmark") }.tint(.green).disabled(!store.canEdit(task)) } }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if task.status == "trashed" { Button { Task { await store.changeStatus(task, to: "restore") } } label: { Label("Restaurar", systemImage: "arrow.uturn.backward") }.disabled(!store.canEdit(task)) }
                                    else { Button(role: .destructive) { trash = task } label: { Label("Lixeira", systemImage: "trash") }.disabled(!store.canEdit(task)); if task.isActive { Button { store.openedTask = task } label: { Label("Data", systemImage: "calendar") }.tint(.orange).disabled(!store.canEdit(task)) } }
                                }
                                .contextMenu { rowMenu(task) }
                        }.onMove { indices, destination in move(group, indices: indices, destination: destination) }.moveDisabled(sort != .manual || !store.canWrite)
                    }
                } header: {
                    if !group.title.isEmpty { Button { withAnimation { if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) } } } label: { HStack(spacing: 7) { Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)); Text(group.title).font(.system(size: 14, weight: .semibold)); Text("\(group.items.count)").font(.system(size: 12)).foregroundStyle(.secondary); Spacer() }.textCase(nil).foregroundStyle(group.id == "overdue" ? Color.red : Color.primary).padding(.vertical, 3) }.buttonStyle(.plain) }
                }
            }
            Color.clear.frame(height: 64).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }.listStyle(.insetGrouped).contentMarginsCompat().scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).refreshable { await store.refresh() }.environment(\.editMode, .constant(sort == .manual ? .active : .inactive))
    }
    private var emptyState: some View {
        Section { VStack(spacing: 12) { Image(systemName: search.isEmpty ? (scope == .today ? "sun.max" : "checkmark.circle") : "magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(nativeBlue.opacity(0.65)).padding(20).background(nativeBlue.opacity(0.06), in: Circle()); Text(search.isEmpty ? "Tudo em ordem" : "Nada encontrado").font(.system(size: 19, weight: .semibold)); Text(search.isEmpty ? store.platform.text("emptyTasks", fallback: "Adicione no campo acima ou no botão +.\nEnter adiciona e deixa pronto para a próxima.") : "Tente outras palavras ou limpe os filtros.").font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center); if store.editableCategories.isEmpty { Button("Criar categoria") { editingCategory = nil; categoryEditor = true }.buttonStyle(.borderedProminent) } }.frame(maxWidth: .infinity).padding(.vertical, 25) }.listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
    private var summaries: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 7) { summary(.today, label: "hoje"); summary(.overdue, label: "atrasadas"); summary(.upcoming, label: "próximas"); summary(.all, label: "em andamento") }.padding(.vertical, 3) }
    }
    private func summary(_ value: TaskScope, label: String) -> some View { let count = store.taskIndex.scopes[value.key] ?? 0; return Button { choose(value) } label: { summaryPill(count, label, active: category.isEmpty && scope == value, alert: value == .overdue && count > 0) }.buttonStyle(.plain) }
    private func summaryPill(_ count: Int, _ label: String, active: Bool, alert: Bool) -> some View { HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(count)").font(.system(size: 16, weight: .bold)).foregroundStyle(alert ? .red : .primary); Text(label).font(.system(size: 12)).foregroundStyle(.secondary) }.padding(.horizontal, 12).padding(.vertical, 9).background(active ? nativeBlue.opacity(0.08) : nativePaper, in: Capsule()) }
    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 7) { HStack(spacing: 10) { Image(systemName: "plus").foregroundStyle(nativeBlue); TextField("Adicionar tarefa…", text: $quick).font(.system(size: 16)).focused($quickFocused).submitLabel(.done).onSubmit { addQuick() }.disabled(adding); if adding { ProgressView() } else if !quick.isEmpty { Button { addQuick() } label: { Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white).frame(width: 32, height: 32).background(nativeBlue, in: Circle()) }.disabled(store.working) } }.padding(.horizontal, 12).padding(.vertical, 7).frame(minHeight: 48).background(nativePaper, in: RoundedRectangle(cornerRadius: 14)); if quickFocused { Text("Ex.: Revisar orçamento amanhã às 9h #casa · ~categoria").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 3) } }
    }
    private var drawerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { Text(String((store.user?.name ?? "S").prefix(1))).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40).background(nativeBlue, in: RoundedRectangle(cornerRadius: 13)); VStack(alignment: .leading, spacing: 2) { Text(store.user?.name ?? "Meu espaço").font(.system(size: 15, weight: .semibold)).lineLimit(1); Text("Tarefas").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { closeDrawer() } label: { Image(systemName: "xmark").frame(width: 36, height: 44) }.accessibilityLabel("Fechar menu") }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(TaskScope.fixedDrawerScopes) { value in scopeDrawerLine(value) }
                    DisclosureGroup("Mais filtros") { ForEach(TaskScope.additionalDrawerScopes) { value in scopeDrawerLine(value) } }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8).accessibilityIdentifier("task-more-filters")
                    HStack { Text("Categorias").font(.system(size: 13, weight: .semibold)); Spacer(); Button { editingCategory = nil; closeDrawer(); categoryEditor = true } label: { Image(systemName: "plus").frame(width: 36, height: 36) }.accessibilityLabel("Criar categoria") }.foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 9)
                    ForEach(folders, id: \.self) { folder in if !folder.isEmpty { Label(folder, systemImage: "folder").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 14).padding(.top, 10) }; ForEach(store.snapshot.lists.filter { !$0.archived && $0.fields.text("folder") == folder }) { categoryLine($0) } }
                    DisclosureGroup("Categorias arquivadas") { ForEach(store.snapshot.lists.filter(\.archived)) { categoryLine($0) } }.font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                    if !allTags.isEmpty { Text("Etiquetas").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(12); ForEach(allTags, id: \.self) { value in drawerLine(value, icon: "number", count: 0, active: tag == value, color: nativeBlue) { tag = tag == value ? "" : value; page = .list; closeDrawer() } } }
                    if !store.snapshot.preferences.objects("filters").isEmpty { Text("Filtros salvos").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(12); ForEach(Array(store.snapshot.preferences.objects("filters").enumerated()), id: \.offset) { index, filter in drawerLine(filter.text("name"), icon: "bookmark", count: 0, active: false, color: nativeBlue) { category = filter.text("listId") == "0" ? "" : filter.text("listId"); scope = TaskScope(key: filter.text("smart")); tag = filter.text("tag"); search = filter.text("search"); searching = !search.isEmpty; page = .list; closeDrawer() }.contextMenu { Button("Excluir filtro", role: .destructive) { deleteFilter(index) } } } }
                }.padding(.horizontal, 10).padding(.vertical, 10)
            }
            Divider()
            VStack(spacing: 0) { drawerLine("Menu do aplicativo", icon: "square.grid.2x2", count: 0, active: false, color: nativeBlue) { closeDrawer(); store.menuOpen = true }; drawerLine("Configurações", icon: "gearshape", count: 0, active: false, color: .secondary) { closeDrawer(); profile = true } }.padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
    private var folders: [String] { Array(Set(store.snapshot.lists.filter { !$0.archived }.map { $0.fields.text("folder") })).sorted() }
    private var allTags: [String] { store.taskIndex.tags }
    private func scopeDrawerLine(_ value: TaskScope) -> some View {
        drawerLine(value.rawValue, icon: value.icon, count: store.taskIndex.scopes[value.key] ?? 0, active: category.isEmpty && tag.isEmpty && scope == value, color: value == .overdue ? .red : nativeBlue) { choose(value); closeDrawer() }.accessibilityIdentifier("task-scope-" + value.key)
    }
    private func drawerLine(_ title: String, icon: String, count: Int, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color).frame(width: 24); Text(title).font(.system(size: 15)).lineLimit(1); Spacer(minLength: 2); if count > 0 { Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) } }.foregroundStyle(active ? nativeBlue : Color.primary).padding(.horizontal, 12).frame(minHeight: 44).background(active ? nativeBlue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain)
    }
    private func categoryLine(_ entry: NativeCategory) -> some View {
        HStack(spacing: 0) { Button { category = entry.id; scope = entry.archived ? .archived : .all; page = .list; selected.removeAll(); closeDrawer() } label: { HStack(spacing: 12) { Circle().fill(Color(nativeHex: entry.fields.text("color"))).frame(width: 9, height: 9).frame(width: 24); Text(entry.name).font(.system(size: 15)).lineLimit(1); Spacer(minLength: 1); Text("\(store.taskIndex.categoryCounts[entry.id] ?? 0)").font(.system(size: 12)).foregroundStyle(.secondary) }.foregroundStyle(category == entry.id ? nativeBlue : Color.primary).padding(.leading, 12).padding(.trailing, 6).frame(minHeight: 44) }.buttonStyle(.plain); if entry.fields.text("ownerId") == store.user?.id { Button { editingCategory = entry; closeDrawer(); categoryEditor = true } label: { Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 36, height: 44) }.accessibilityLabel("Editar " + entry.name) } }.background(category == entry.id ? nativeBlue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func rowMenu(_ task: NativeTask) -> some View {
        Button { store.openedTask = task } label: { Label("Abrir tarefa", systemImage: "square.and.pencil") }
        if store.canEdit(task) {
            if task.status == "trashed" { Button("Restaurar") { Task { await store.changeStatus(task, to: "restore") } } }
            else { Button(task.isDone ? "Reabrir" : task.completionLabel) { Task { await store.complete(task) } }; Button(task.fields.flag("pinned") ? "Desafixar" : "Fixar no início") { patch(task, key: "pinned", value: .bool(!task.fields.flag("pinned"))) }; Button("Alterar data") { store.openedTask = task }; Button("Adiar 1 dia") { Task { await store.postpone(task) } }; Button(task.status == "archived" ? "Desarquivar" : "Arquivar") { Task { await store.changeStatus(task, to: task.status == "archived" ? "todo" : "archived") } }; Button("Mover para a lixeira", role: .destructive) { trash = task } }
        }
        Button("Selecionar") { selecting = true; toggleSelection(task.id) }
        ShareLink(item: ([task.title, task.fields.text("body")] + task.checks.map { ($0.done ? "☑ " : "☐ ") + $0.title }).joined(separator: "\n")) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
    }
    private var bulkBar: some View {
        HStack(spacing: 12) { Text("\(selected.count)\nselecionadas").font(.system(size: 11)).foregroundStyle(.secondary); Button { bulk("complete") } label: { Label("Concluir", systemImage: "checkmark") }.disabled(selected.isEmpty || !store.canWrite); Button(role: .destructive) { bulkTrash = true } label: { Label("Lixeira", systemImage: "trash") }.disabled(selected.isEmpty || !store.canWrite); Spacer(); Button { selecting = false; selected.removeAll() } label: { Image(systemName: "xmark").frame(width: 32, height: 40) }.accessibilityLabel("Cancelar seleção") }.font(.system(size: 13)).padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
    }
    private var contextDate: Date? { page == .calendar ? Calendar.current.startOfDay(for: calendarDay) : scope == .today ? Calendar.current.startOfDay(for: Date()) : scope == .tomorrow ? Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!) : nil }
    private func choose(_ value: TaskScope) { scope = value; category = ""; tag = ""; selected.removeAll(); selecting = false; page = .list }
    private func consumeNavigation() { if let id = store.taskCategoryRequest { category = id; scope = .all; page = .list; tag = ""; search = ""; store.taskCategoryRequest = nil }; if let key = store.taskScopeRequest { choose(TaskScope(key: key)); store.taskScopeRequest = nil } }
    private func closeDrawer() { withAnimation(.easeInOut(duration: 0.22)) { drawer = false } }
    private func newTask() {
        guard store.canWrite else { store.message = "Sem conexão com o servidor. Atualize antes de criar uma tarefa."; return }
        guard let id = currentCategory?.canEdit == true ? currentCategory?.id : store.editableCategories.first?.id else { return }
        var task = NativeTask.draft(categoryID: id)
        if let date = contextDate { task.fields["dueAt"] = .string(NativeDate.iso(date)) }
        if !tag.isEmpty { task.fields["tags"] = .array([.string(tag)]) }
        quickFocused = false; store.openedTask = task
    }

    private func addQuick() {
        guard !adding, !quick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let id = currentCategory?.canEdit == true ? currentCategory?.id : store.editableCategories.first?.id else { return }
        let draft = pendingQuick ?? NativeQuickCapture.parse(quick, categoryID: id, categories: store.editableCategories, defaultDate: contextDate)
        guard !draft.title.isEmpty else { return }
        if !store.canWrite { store.message = "Sem conexão com o servidor. A tarefa não foi salva."; return }
        adding = true; pendingQuick = draft
        Task { do { _ = try await store.save(draft); quick = ""; pendingQuick = nil; quickFocused = true } catch { pendingQuick = nil; store.report(error) }; adding = false }
    }
    private func toggleSelection(_ id: String) { if selected.contains(id) { selected.remove(id) } else if selected.count < 100 { selected.insert(id) } }
    private func bulk(_ operation: String) {
        let values = store.snapshot.items.filter { selected.contains($0.id) && store.canEdit($0) }
        guard values.count == selected.count else { store.message = "A seleção inclui itens sem permissão de edição."; return }
        Task { do { _ = try await store.mutate("org_bulk", ["operation": .string(operation), "items": .array(values.map { .object(["id": .string($0.id), "revision": .number(Double($0.revision))]) })]); selected.removeAll(); selecting = false } catch { store.report(error) } }
    }
    private func patch(_ task: NativeTask, key: String, value: JSONValue) { var next = task; next.fields[key] = value; Task { do { _ = try await store.save(next) } catch { store.report(error) } } }
    private func move(_ group: NativeTaskGroup, indices: IndexSet, destination: Int) { var ordered = group.items; ordered.move(fromOffsets: indices, toOffset: destination); Task { do { try await store.reorder(ordered) } catch { store.report(error) } } }
    private func saveFilter() { guard !filterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; var preferences = store.snapshot.preferences; var filters = preferences["filters"]?.array ?? []; filters.append(.object(["name": .string(filterName), "smart": .string(scope.key), "listId": .string(category), "tag": .string(tag), "search": .string(search)])); preferences["filters"] = .array(filters); Task { do { _ = try await store.mutate("org_preferences", preferences) } catch { store.report(error) } } }
    private func deleteFilter(_ index: Int) { var preferences = store.snapshot.preferences; var filters = preferences["filters"]?.array ?? []; guard filters.indices.contains(index) else { return }; filters.remove(at: index); preferences["filters"] = .array(filters); Task { do { _ = try await store.mutate("org_preferences", preferences) } catch { store.report(error) } } }
}
struct NativeTaskRow: View {
    @ObservedObject var store: NativeStore
    let task: NativeTask
    var showCategory = true
    var selecting = false
    var selected = false
    var select: () -> Void = {}
    var onOpen: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { if selecting { select() } else { Task { await store.complete(task) } } } label: { Image(systemName: selecting ? (selected ? "checkmark.circle.fill" : "circle") : task.isDone ? "checkmark.circle.fill" : "circle").font(.system(size: 23, weight: .light)).foregroundStyle(task.isDone ? Color.secondary.opacity(0.6) : nativeBlue).frame(width: 32, height: 44) }.disabled(!selecting && (!store.canEdit(task) || !["todo", "doing", "done"].contains(task.status))).accessibilityLabel(selecting ? "Selecionar " + task.title : task.isDone ? "Reabrir " + task.title : task.completionLabel + " " + task.title)
            Button { if selecting { select() } else if let onOpen { onOpen() } else { store.openedTask = task } } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) { if task.fields.flag("pinned") { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(nativeBlue) }; Text(task.title).font(.system(size: 16 * store.layout.textScale, weight: .medium)).strikethrough(task.isDone).foregroundStyle(task.isDone ? Color(uiColor: .secondaryLabel) : Color(uiColor: .label)).multilineTextAlignment(.leading) }
                    if !task.fields.text("body").isEmpty { Text(task.fields.text("body")).font(.system(size: 12)).foregroundStyle(Color(uiColor: .secondaryLabel)).lineLimit(2).multilineTextAlignment(.leading) }
                    ViewThatFits(in: .horizontal) { HStack(spacing: 9) { dateMeta; otherMeta }; VStack(alignment: .leading, spacing: 4) { dateMeta; otherMeta } }
                    if store.layout.taskShowAmounts && task.isMoney { Text((task.moneyMode == "receive" ? "A receber: " : "A pagar: ") + NativeDate.money(task.pendingAmount)).font(.system(size: 12)).foregroundStyle(Color(uiColor: .secondaryLabel)) }
                    if store.layout.taskShowTags && !task.tags.isEmpty { Text(task.tags.map { "#" + $0 }.joined(separator: "  ")).font(.system(size: 11)).foregroundStyle(nativeBlue.opacity(0.85)) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
            }
        }.buttonStyle(.borderless).padding(.vertical, 1)
    }
    @ViewBuilder private var dateMeta: some View { if let date = task.listDate, !task.checks.contains(where: { $0.date != nil }) { Label(NativeDateLabel.text(date), systemImage: "calendar").font(.system(size: 12)).foregroundStyle(task.isOverdue() ? Color.red : Calendar.current.isDateInToday(date) ? nativeBlue : Color(uiColor: .secondaryLabel)) } }
    private var otherMeta: some View { HStack(spacing: 9) { if showCategory && store.layout.taskShowCategory { HStack(spacing: 4) { Circle().fill(Color(nativeHex: store.taskIndex.categories[task.categoryID]?.fields.text("color") ?? "#1f6feb")).frame(width: 5, height: 5); Text(store.category(task)).lineLimit(1) } }; if !task.checks.isEmpty { Label("\(task.checks.filter(\.done).count)/\(task.checks.count)", systemImage: "checklist") }; if task.fields["repeat"]?.object.text("frequency") != "none", task.fields["repeat"] != nil { Image(systemName: "repeat") }; if task.paused { Text("Pausada") } }.font(.system(size: 12)).foregroundStyle(Color(uiColor: .secondaryLabel)) }
}
struct NativeCalendarGrid: View {
    @ObservedObject var store: NativeStore
    @Binding var selection: Date
    var categoryID = ""
    @State private var month = Date()
    @State private var week = false
    private let calendar = Calendar.current
    static func dates(_ task: NativeTask) -> [Date] { NativeTaskIndex.dates(task) }
    private var days: [Date] { let base = week ? calendar.startOfDay(for: selection) : calendar.date(from: calendar.dateComponents([.year, .month], from: month))!; let start = calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: base) - 1), to: base)!; return (0..<(week ? 7 : 42)).map { calendar.date(byAdding: .day, value: $0, to: start)! } }
    var body: some View {
        VStack(spacing: 14) {
            HStack { Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "pt_BR"))).capitalized).font(.system(size: 19, weight: .bold)); Spacer(); Menu { Button("Mês") { week = false }; Button("Semana") { week = true } } label: { Label(week ? "Semana" : "Mês", systemImage: "chevron.down").font(.system(size: 12)) } }
            HStack { Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }; Button("Hoje") { selection = Date(); month = selection }.font(.system(size: 13)); Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }; Spacer() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 7) {
                ForEach(["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"], id: \.self) { Text($0).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                ForEach(days, id: \.self) { day in let selected = calendar.isDate(day, inSameDayAs: selection)
                    Button { selection = day } label: { VStack(spacing: 3) { Text("\(calendar.component(.day, from: day))").font(.system(size: 14, weight: selected || calendar.isDateInToday(day) ? .semibold : .regular)).frame(width: 30, height: 30).background(selected ? nativeBlue : .clear, in: Circle()).foregroundStyle(selected ? Color.white : calendar.isDateInToday(day) ? nativeBlue : Color.primary); HStack(spacing: 2) { ForEach(0..<min(3, count(day)), id: \.self) { _ in Circle().fill(nativeBlue.opacity(0.6)).frame(width: 3, height: 3) } }.frame(height: 3) }.frame(maxWidth: .infinity).opacity(calendar.isDate(day, equalTo: month, toGranularity: .month) || week ? 1 : 0.35) }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", \(count(day)) tarefas")
                        .contextMenu { Button("Nova tarefa neste dia") { selection = day; newTask(day) }.disabled(store.editableCategories.isEmpty) }
                }
            }
            HStack { Text(selection.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "pt_BR"))).capitalized).font(.system(size: 14, weight: .semibold)); Spacer() }.padding(.top, 5)
        }.padding(14).background(nativePaper, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("calendar-grid")
    }
    private func newTask(_ day: Date) {
        guard let id = store.editableCategories.first(where: { $0.id == categoryID })?.id ?? store.editableCategories.first?.id else { return }
        guard store.canWrite else { return }
        var task = NativeTask.draft(categoryID: id); task.fields["dueAt"] = .string(NativeDate.iso(calendar.startOfDay(for: day))); store.openedTask = task
    }
    private func count(_ day: Date) -> Int { store.taskIndex.count(day: day, categoryID: categoryID, calendar: calendar) }
    private func step(_ amount: Int) { if week { selection = calendar.date(byAdding: .day, value: amount * 7, to: selection)!; month = selection } else { month = calendar.date(byAdding: .month, value: amount, to: month)!; selection = calendar.date(from: calendar.dateComponents([.year, .month], from: month))! } }
}
extension View {
    @ViewBuilder func contentMarginsCompat() -> some View { if #available(iOS 17.0, *) { self.contentMargins(.top, 4, for: .scrollContent).listSectionSpacing(12) } else { self } }
}
