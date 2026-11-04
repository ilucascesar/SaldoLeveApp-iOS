import SwiftUI

// Live preview of the layout being edited. It renders the draft preferences
// with the account's own data (or samples) and never writes anything.
enum NativeSimulatorScreen: String, CaseIterable, Identifiable {
    case expenses = "Despesas", agenda = "Agenda", task = "Tarefa aberta"
    var id: String { rawValue }
    var icon: String { switch self { case .expenses: return "wallet.pass"; case .agenda: return "checkmark.circle"; case .task: return "list.bullet.rectangle" } }
}

struct NativeSimulatorPanel: View {
    @ObservedObject var store: NativeStore
    let layout: NativeLayoutPreferences
    @Binding var screen: NativeSimulatorScreen
    var expand: () -> Void
    @AppStorage("nativeSimulatorVisible") private var visible = true
    var body: some View {
        VStack(spacing: 0) {
            if visible {
                HStack(alignment: .top, spacing: 14) {
                    NativeSimulatorDevice(store: store, layout: layout, screen: screen, scale: 0.38)
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Simulador", systemImage: "iphone").font(.headline)
                        Text(layout == store.layout ? "Igual ao layout salvo." : "Prévia das alterações. Nada muda no app até tocar em Salvar.").font(.caption).foregroundStyle(layout == store.layout ? Color.secondary : nativeBlue).fixedSize(horizontal: false, vertical: true)
                        ForEach(NativeSimulatorScreen.allCases) { value in
                            Button { withAnimation(.easeInOut(duration: 0.2)) { screen = value } } label: {
                                Label(value.rawValue, systemImage: value.icon).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                                    .foregroundStyle(screen == value ? Color.white : Color.primary).background(screen == value ? nativeBlue : nativePaper, in: Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("simulator-" + value.rawValue).accessibilityAddTraits(screen == value ? .isSelected : [])
                        }
                        Button(action: expand) { Label("Tela cheia e comparar", systemImage: "arrow.up.left.and.arrow.down.right") }.font(.caption.weight(.semibold)).padding(.top, 2).accessibilityIdentifier("simulator-expand")
                    }
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
            }
            Button { withAnimation(.easeInOut(duration: 0.2)) { visible.toggle() } } label: {
                Label(visible ? "Ocultar simulador" : "Mostrar simulador", systemImage: visible ? "chevron.up" : "iphone").font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.plain).foregroundStyle(nativeBlue)
            Divider()
        }.background(.bar)
    }
}

struct NativeSimulatorFullScreen: View {
    @ObservedObject var store: NativeStore
    let draft: NativeLayoutPreferences
    @Binding var screen: NativeSimulatorScreen
    @Environment(\.dismiss) private var dismiss
    @State private var showSaved = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Tela", selection: $screen) { ForEach(NativeSimulatorScreen.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("Versão", selection: $showSaved) { Text("Com as alterações").tag(false); Text("Layout salvo").tag(true) }.pickerStyle(.segmented)
                GeometryReader { proxy in
                    let scale = min(proxy.size.width / NativeSimulatorDevice.size.width, proxy.size.height / NativeSimulatorDevice.size.height)
                    NativeSimulatorDevice(store: store, layout: showSaved ? store.layout : draft, screen: screen, scale: scale).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(showSaved ? "Assim está hoje no app." : "Assim ficará depois de tocar em Salvar.").font(.caption).foregroundStyle(.secondary)
            }.padding(16).background(nativeCanvas)
                .navigationTitle("Simulador").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Voltar aos ajustes") { dismiss() } } }
        }
    }
}

struct NativeSimulatorDevice: View {
    static let size = CGSize(width: 390, height: 800)
    @ObservedObject var store: NativeStore
    let layout: NativeLayoutPreferences
    let screen: NativeSimulatorScreen
    var scale: CGFloat = 0.4
    var body: some View {
        content
            .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
            .background(nativeCanvas)
            .clipShape(RoundedRectangle(cornerRadius: 54, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 54, style: .continuous).strokeBorder(Color.black, lineWidth: 10))
            .overlay(alignment: .top) { Capsule().fill(Color.black).frame(width: 118, height: 34).padding(.top, 14) }
            .scaleEffect(scale)
            .frame(width: Self.size.width * scale, height: Self.size.height * scale)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel("Simulador: " + screen.rawValue)
            .accessibilityIdentifier("layout-simulator")
    }
    @ViewBuilder private var content: some View {
        switch screen {
        case .expenses: NativeSimExpenses(store: store, finance: store.finance, layout: layout)
        case .agenda: NativeSimAgenda(store: store, layout: layout)
        case .task: NativeSimTask(store: store, layout: layout)
        }
    }
}

struct NativeSimStatusBar: View {
    var body: some View {
        HStack { Text("9:41").font(.system(size: 16, weight: .semibold)); Spacer(); Image(systemName: "wifi"); Image(systemName: "battery.75") }
            .font(.system(size: 14)).padding(.horizontal, 34).frame(height: 58).padding(.top, 4)
    }
}

struct NativeSimTabBar: View {
    @ObservedObject var store: NativeStore
    let layout: NativeLayoutPreferences
    let selected: String
    var body: some View {
        HStack {
            ForEach(layout.tabOrder, id: \.self) { key in
                VStack(spacing: 3) { Image(systemName: NativeAppSection(key: key).icon).font(.system(size: 21)); Text(store.platform.label(key)).font(.system(size: 10, weight: .medium)) }
                    .foregroundStyle(key == selected ? nativeBlue : Color.secondary).frame(maxWidth: .infinity)
            }
        }.padding(.top, 8).padding(.bottom, 28).background(.bar)
    }
}

private struct NativeSimExpense: Identifiable {
    let id: String
    let name: String
    let value: Double
    let paid: Bool
    let type: String
    let accent: Color
    var inactive = false
}

struct NativeSimExpenses: View {
    @ObservedObject var store: NativeStore
    @ObservedObject var finance: NativeFinanceStore
    let layout: NativeLayoutPreferences
    private var t: Double { layout.textScale }
    private var data: NativeFinanceSnapshot { finance.snapshot }
    private var all: [NativeSimExpense] {
        let real = data.expenses.prefix(24).map { e -> NativeSimExpense in
            let id = e.text("id")
            return NativeSimExpense(id: id, name: e.text("name"), value: data.expenseCalculation(id).decimal("integral"), paid: data.paid(id), type: e.text("type"), accent: Color(nativeHex: e.text("accent")), inactive: e["active"] == .bool(false))
        }
        if !real.isEmpty { return Array(real) }
        let samples: [(String, Double, Bool, String, String)] = [("Fatura do cartão", 1849.90, false, "card", "#1f6feb"), ("Aluguel", 1400, true, "home", "#7650c4"), ("Internet", 99.90, false, "home", "#138568"), ("Academia", 119.90, true, "other", "#c03b6a"), ("Energia", 230.55, false, "home", "#b4640b"), ("Streaming", 55.90, true, "other", "#3b7ef0")]
        return samples.enumerated().map { NativeSimExpense(id: String($0.offset), name: $0.element.0, value: $0.element.1, paid: $0.element.2, type: $0.element.3, accent: Color(nativeHex: $0.element.4)) }
    }
    private var shown: [NativeSimExpense] {
        var list = all.filter { layout.dashboardShowPaid || !$0.paid }
        switch layout.expenseDefaultFilter {
        case "active": list = list.filter { !$0.inactive }
        case "inactive": list = list.filter(\.inactive)
        case "pending": list = list.filter { !$0.paid }
        case "paid": list = list.filter(\.paid)
        default: break
        }
        switch layout.expenseOrder {
        case "name": list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "amount": list.sort { $0.value > $1.value }
        case "pending": list.sort { !$0.paid && $1.paid }
        default: break
        }
        let pinned = Set(layout.pinnedExpenses)
        list = list.filter { pinned.contains($0.id) } + list.filter { !pinned.contains($0.id) }
        return layout.dashboardExpenseLimit == 0 ? list : Array(list.prefix(layout.dashboardExpenseLimit))
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                NativeSimStatusBar()
                navigation
                VStack(alignment: .leading, spacing: layout.spacing) {
                    if layout.showMonth { HStack { Label(NativeFinanceFormat.month(data.month.isEmpty ? String(NativeDate.iso(Date()).prefix(7)) : data.month), systemImage: "calendar").font(.system(size: 13 * t, weight: .semibold)); Spacer(); Text("Mês em aberto").font(.caption2).foregroundStyle(.secondary) } }
                    ForEach(layout.visibleDashboard, id: \.self) { key in block(key) }
                }.padding(.horizontal, 16).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            if layout.showBottomBar { NativeSimTabBar(store: store, layout: layout, selected: "dashboard") }
        }
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "line.3.horizontal"); if layout.compactHeader { Spacer(); Text(store.platform.label("dashboard")).font(.system(size: 17, weight: .semibold)) }; Spacer(); Image(systemName: "ellipsis.circle"); Image(systemName: "plus") }.font(.system(size: 19)).foregroundStyle(nativeBlue)
            if !layout.compactHeader { Text(store.platform.label("dashboard")).font(.system(size: 32, weight: .bold)) }
            if layout.showSearch { HStack { Image(systemName: "magnifyingglass"); Text("Buscar despesa ou lançamento"); Spacer() }.font(.system(size: 15)).foregroundStyle(.secondary).padding(9).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10)) }
        }.padding(.horizontal, 16).padding(.bottom, 4)
    }
    @ViewBuilder private func block(_ key: String) -> some View {
        switch key {
        case "balance":
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Resumo do mês").font(.headline); Spacer(); Image(systemName: "eye.slash").foregroundStyle(nativeBlue) }
                HStack { metric("Renda do mês", "••••••", .primary); metric("Saldo do mês", "••••••", .green) }
            }.padding(16).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
        case "totals":
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: layout.spacing) {
                total("Gastos do mês", NativeFinanceFormat.money(data.active.decimal("spent")), "arrow.up.right", .primary)
                total("Já pago", NativeFinanceFormat.money(data.active.decimal("paid")), "checkmark.circle", .green)
                total("Falta pagar", NativeFinanceFormat.money(data.active.decimal("pending")), "clock", .orange)
                total("Contas pendentes", "\(data.active.integer("pendingCount"))", "wallet.pass", nativeBlue)
            }
        case "expenses":
            VStack(alignment: .leading, spacing: layout.spacing) {
                HStack(spacing: 7) { ForEach(["all", "active", "pending", "paid"], id: \.self) { key in Text(["active": "Ativas", "pending": "Pendentes", "paid": "Pagas", "all": "Todas"][key] ?? key).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 9).foregroundStyle(layout.expenseDefaultFilter == key ? Color.white : Color.primary).background(layout.expenseDefaultFilter == key ? nativeBlue : nativePaper, in: Capsule()) } }
                if layout.expenseGrouping == "none" { grid(shown) }
                else {
                    ForEach(groupNames, id: \.self) { name in
                        let group = shown.filter { groupName($0) == name }
                        HStack { Text(name).font(.system(size: 16 * t, weight: .semibold)); Spacer(); Text("\(group.count) contas").font(.caption).foregroundStyle(.secondary) }
                        grid(group)
                    }
                }
            }
        case "pending":
            VStack(alignment: .leading, spacing: 10) {
                Text("Pendências do mês").font(.headline)
                ForEach(all.filter { !$0.paid }.prefix(3)) { item in HStack { Text(item.name); Spacer(); Text(NativeFinanceFormat.money(item.value)).foregroundStyle(.orange).fontWeight(.semibold) }.font(.system(size: 14 * t)) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
        default:
            HStack { Label("Próximas faturas", systemImage: "calendar.badge.clock"); Spacer(); Text("Fechar mês").foregroundStyle(nativeBlue) }.font(.subheadline).padding(16).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
        }
    }
    private var groupNames: [String] { Array(Set(shown.map(groupName))).sorted() }
    private func groupName(_ e: NativeSimExpense) -> String { layout.expenseGrouping == "type" ? NativeFinanceFormat.expenseType(e.type) : e.paid ? "Pagas" : "Pendentes" }
    private func grid(_ list: [NativeSimExpense]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: layout.cardColumns >= 3 ? 7 : layout.spacing, alignment: .top), count: layout.cardColumns), alignment: .leading, spacing: layout.cardColumns >= 3 ? 8 : layout.spacing) {
            ForEach(list) { item in if layout.cardColumns >= 3 { mini(item) } else { full(item) } }
        }
    }
    private func icon(_ type: String) -> String { type == "card" ? "creditcard.fill" : type == "home" ? "house.fill" : "wallet.pass.fill" }
    private func mini(_ e: NativeSimExpense) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 3) { if layout.cardShowIcon { Image(systemName: icon(e.type)).font(.system(size: 13)).foregroundStyle(e.accent) }; Spacer(minLength: 0); Circle().fill(e.paid ? Color.green : .orange).frame(width: 5, height: 5) }
            Text(e.name).font(.system(size: 11 * t, weight: .semibold)).lineLimit(2).frame(height: 30 * t, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
            Text(NativeFinanceFormat.money(e.value)).font(.system(size: (layout.cardColumns == 4 ? 13 : 16) * t, weight: .bold, design: layout.roundedValues ? .rounded : .default)).lineLimit(1).minimumScaleFactor(0.6)
            if layout.cardShowType { Text(e.type == "card" ? "Cartão" : e.type == "home" ? "Casa" : "Outros").font(.system(size: 9)).foregroundStyle(.secondary) }
            if layout.cardShowActions { HStack { Text(e.paid ? "Paga" : "Pendente").font(.system(size: 9)); Spacer(minLength: 0); Image(systemName: "ellipsis").font(.system(size: 10)) }.foregroundStyle(.secondary) }
        }.padding(layout.cardColumns == 4 ? 8 : 10).frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(nativePaper, in: RoundedRectangle(cornerRadius: min(14, layout.cardRadius)))
            .overlay(alignment: .top) { Capsule().fill(e.accent).frame(height: 3).padding(.horizontal, 12) }
    }
    private func full(_ e: NativeSimExpense) -> some View {
        let compact = layout.cardStyle == "compact" || layout.cardColumns == 2
        return VStack(alignment: .leading, spacing: compact ? 9 : layout.spacing) {
            HStack(alignment: .top, spacing: 9) {
                if layout.cardShowIcon { Image(systemName: icon(e.type)).font(.system(size: 15)).foregroundStyle(e.accent).frame(width: 32, height: 32).background(e.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)) }
                VStack(alignment: .leading, spacing: 3) { Text(e.name).font(.system(size: (compact ? 15 : 17) * t, weight: .semibold)).lineLimit(2); if layout.cardShowType { Text(NativeFinanceFormat.expenseType(e.type)).font(.system(size: 11 * t)).foregroundStyle(.secondary) } }
                Spacer(minLength: 0); Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            Text(NativeFinanceFormat.money(e.value)).font(.system(size: (compact ? 23 : 30) * t, weight: .bold, design: layout.roundedValues ? .rounded : .default)).lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 5) { Circle().fill(e.paid ? Color.green : .orange).frame(width: 6, height: 6); Text(e.paid ? "Paga" : "Pendente").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            if layout.cardShowActions { Label(e.paid ? "Reabrir pagamento" : "Marcar como paga", systemImage: e.paid ? "checkmark.circle.fill" : "circle").font(.system(size: 12 * t, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9).foregroundStyle(e.paid ? Color.green : e.accent).background(e.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)) }
        }.padding(compact ? 13 : 18).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
            .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(e.accent).frame(height: 3).padding(.horizontal, layout.cardRadius) }
    }
    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12 * t)).foregroundStyle(.secondary); Text(value).font(.system(size: 21 * t, weight: .semibold, design: layout.roundedValues ? .rounded : .default)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func total(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(color); metric(title, value, color) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
    }
}

struct NativeSimAgenda: View {
    @ObservedObject var store: NativeStore
    let layout: NativeLayoutPreferences
    private var t: Double { layout.textScale }
    private var tasks: [NativeTask] {
        let real = store.snapshot.items.filter(\.isActive).sorted { ($0.listDate ?? .distantFuture) < ($1.listDate ?? .distantFuture) }
        if !real.isEmpty { return Array(real.prefix(8)) }
        let now = Date(), calendar = Calendar.current
        let samples: [(String, Int?, String, [String])] = [("Pagar internet", -1, "pay", ["casa"]), ("Reunião com o contador", 0, "normal", []), ("Revisar orçamento do mês", 0, "normal", ["finanças"]), ("Comprar presente da Ana", 2, "normal", []), ("Receber aluguel da sala", 5, "receive", []), ("Organizar documentos", nil, "normal", [])]
        return samples.enumerated().map { entry -> NativeTask in
            let offset = entry.offset, sample = entry.element
            var fields: JSONObject = ["id": .string("sim\(offset)"), "title": .string(sample.0), "status": .string("todo"), "listId": .string(""), "moneyMode": .string(sample.2), "tags": .array(sample.3.map { .string($0) })]
            if let days = sample.1, let date = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) { fields["dueAt"] = .string(NativeDate.iso(date)) }
            if sample.2 != "normal" { fields["amountCents"] = .number(18990) }
            return NativeTask(fields)
        }
    }
    private var filtered: Bool { layout.taskDefaultSort != NativeTaskSort.due.rawValue || layout.taskDefaultPeriod != "all" }
    private func bucket(_ task: NativeTask) -> String {
        guard let date = task.listDate else { return "Sem data" }
        if task.isOverdue() { return "Atrasadas" }
        return Calendar.current.isDateInToday(date) ? "Hoje" : "Próximas"
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                NativeSimStatusBar()
                HStack(spacing: 14) {
                    Image(systemName: "line.3.horizontal")
                    Text(store.platform.text("tasksHeading", fallback: "Tudo")).font(.system(size: 21, weight: .bold)).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "magnifyingglass")
                    Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle").foregroundStyle(filtered ? nativeBlue : Color.primary)
                    Image(systemName: "ellipsis")
                }.font(.system(size: 20)).padding(.horizontal, 16).padding(.bottom, 6)
                HStack(spacing: 6) {
                    ForEach(["list", "calendar", "habits"], id: \.self) { key in
                        Label(["list": "Categorias", "calendar": "Calendário", "habits": "Hábitos"][key] ?? key, systemImage: ["list": "list.bullet", "calendar": "calendar", "habits": "target"][key] ?? "circle").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8).foregroundStyle(layout.taskDefaultView == key ? nativeBlue : Color.secondary).background(layout.taskDefaultView == key ? nativeBlue.opacity(0.1) : Color.clear, in: Capsule())
                    }
                }.padding(.horizontal, 14).padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 10) {
                    if layout.taskShowSummaries {
                        HStack(spacing: 7) { pill(store.taskIndex.scopes["all"] ?? tasks.count, "Tudo", active: true); pill(store.taskIndex.scopes["today"] ?? 0, "hoje"); pill(store.taskIndex.scopes["overdue"] ?? 0, "atrasadas", alert: true); pill(store.taskIndex.scopes["next"] ?? 0, "próximas") }
                    }
                    if layout.taskQuickCapture { HStack(spacing: 10) { Image(systemName: "plus").foregroundStyle(nativeBlue); Text("Adicionar tarefa…").foregroundStyle(.secondary); Spacer() }.font(.system(size: 16)).padding(.horizontal, 12).frame(height: 48).background(nativePaper, in: RoundedRectangle(cornerRadius: 14)) }
                    if layout.taskDefaultView == "calendar" { calendarMock }
                    if layout.taskGroupByDate {
                        ForEach(["Atrasadas", "Hoje", "Próximas", "Sem data"], id: \.self) { name in
                            let list = tasks.filter { bucket($0) == name }
                            if !list.isEmpty { section(name, list) }
                        }
                    } else { section("", tasks) }
                    if layout.taskShowCompleted { HStack(spacing: 7) { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)); Text("Concluídas").font(.system(size: 14, weight: .semibold)); Spacer() }.padding(.horizontal, 4) }
                }.padding(.horizontal, 14).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            HStack { Spacer(); Image(systemName: "plus").font(.system(size: 24, weight: .medium)).foregroundStyle(.white).frame(width: 54, height: 54).background(nativeBlue, in: Circle()).shadow(color: nativeBlue.opacity(0.28), radius: 10, y: 5) }.padding(.trailing, 20).padding(.bottom, layout.showBottomBar ? 90 : 30)
            if layout.showBottomBar { NativeSimTabBar(store: store, layout: layout, selected: "tasks") }
        }
    }
    private func pill(_ count: Int, _ label: String, active: Bool = false, alert: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) { Text("\(count)").font(.system(size: 16, weight: .bold)).foregroundStyle(alert && count > 0 ? Color.red : Color.primary); Text(label).font(.system(size: 12)).foregroundStyle(.secondary) }
            .padding(.horizontal, 11).padding(.vertical, 8).background(active ? nativeBlue.opacity(0.08) : nativePaper, in: Capsule())
    }
    private var calendarMock: some View {
        VStack(spacing: 8) {
            HStack { Text(Date().formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "pt_BR"))).capitalized).font(.system(size: 17, weight: .bold)); Spacer() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 6) {
                ForEach(1...28, id: \.self) { day in Text("\(day)").font(.system(size: 12)).frame(width: 24, height: 24).background(day == Calendar.current.component(.day, from: Date()) ? nativeBlue : Color.clear, in: Circle()).foregroundStyle(day == Calendar.current.component(.day, from: Date()) ? Color.white : Color.primary) }
            }
        }.padding(12).background(nativePaper, in: RoundedRectangle(cornerRadius: 14))
    }
    private func section(_ title: String, _ list: [NativeTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { HStack(spacing: 7) { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)); Text(title).font(.system(size: 14, weight: .semibold)); Text("\(list.count)").font(.system(size: 12)).foregroundStyle(.secondary) }.foregroundStyle(title == "Atrasadas" ? Color.red : Color.primary).padding(.horizontal, 4) }
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { offset, task in
                    if offset > 0 { Divider().padding(.leading, 44) }
                    row(task)
                }
            }.background(nativePaper, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func row(_ task: NativeTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle").font(.system(size: 23, weight: .light)).foregroundStyle(nativeBlue).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.system(size: 16 * t, weight: .medium)).lineLimit(2)
                HStack(spacing: 9) {
                    if let date = task.listDate { Label(NativeDateLabel.text(date), systemImage: "calendar").foregroundStyle(task.isOverdue() ? Color.red : Calendar.current.isDateInToday(date) ? nativeBlue : Color.secondary) }
                    if layout.taskShowCategory && !task.categoryID.isEmpty { HStack(spacing: 4) { Circle().fill(Color(nativeHex: store.taskIndex.categories[task.categoryID]?.fields.text("color") ?? "#1f6feb")).frame(width: 5, height: 5); Text(store.category(task)).lineLimit(1) } }
                    if !task.checks.isEmpty { Label("\(task.checks.filter(\.done).count)/\(task.checks.count)", systemImage: "checklist") }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                if layout.taskShowAmounts && task.isMoney { Text((task.moneyMode == "receive" ? "A receber: " : "A pagar: ") + NativeDate.money(task.pendingAmount)).font(.system(size: 12)).foregroundStyle(.secondary) }
                if layout.taskShowTags && !task.tags.isEmpty { Text(task.tags.map { "#" + $0 }.joined(separator: "  ")).font(.system(size: 11)).foregroundStyle(nativeBlue.opacity(0.85)) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 6 + layout.rowPadding)
    }
}

struct NativeSimTask: View {
    @ObservedObject var store: NativeStore
    let layout: NativeLayoutPreferences
    // The account task with the most subtasks shows the real effect of the
    // chosen style; a sample installment plan is used when none exists.
    private var task: NativeTask {
        if let real = store.snapshot.items.filter({ $0.isActive && $0.checks.count >= 3 }).max(by: { $0.checks.count < $1.checks.count }) { return real }
        let calendar = Calendar.current, start = calendar.date(byAdding: .month, value: -3, to: calendar.startOfDay(for: Date())) ?? Date()
        let checks: [JSONValue] = (0..<8).map { index in
            let date = calendar.date(byAdding: .month, value: index, to: start) ?? start
            return .object(["id": .string("s\(index)"), "text": .string("Parcela \(index + 1)/8"), "done": .bool(index < 3), "remindAt": .string(NativeDate.iso(date)), "amountCents": .number(45000)])
        }
        return NativeTask(["id": .string("sim"), "title": .string("Financiamento do carro"), "body": .string("Débito automático no dia 10."), "status": .string("todo"), "listId": .string(""), "moneyMode": .string("pay"), "checklist": .array(checks)])
    }
    var body: some View {
        let current = task, checks = current.checks
        VStack(spacing: 0) {
            NativeSimStatusBar()
            HStack { Text("Fechar"); Spacer(); Text(current.categoryID.isEmpty ? "Financeiro" : store.category(current)).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary); Spacer(); Text("Salvar").bold() }.font(.system(size: 16)).foregroundStyle(nativeBlue).padding(.horizontal, 18).padding(.vertical, 10)
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) { Image(systemName: "circle").font(.system(size: 25, weight: .light)).foregroundStyle(nativeBlue); Text(current.title).font(.system(size: 23, weight: .semibold)).lineLimit(2) }
                    HStack(spacing: 7) { NativeChip(title: current.categoryID.isEmpty ? "Financeiro" : store.category(current), icon: "circle.fill"); NativeChip(title: current.moneyMode == "receive" ? "A receber" : current.isMoney ? "A pagar" : "Normal", active: current.isMoney); NativeChip(title: "Avisos", icon: "alarm") }
                    if !current.fields.text("body").isEmpty { Text(current.fields.text("body")).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2) }
                }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                NativeTaskChecklist(checks: checks, money: current.isMoney, receive: current.moneyMode == "receive", pendingAmount: current.isMoney ? current.pendingAmount : nil, layout: layout, collapsed: layout.taskDetailExpandDone ? [] : ["done"]) { check, presentation in
                    NativeInlineCheckRow(fields: .constant(check.fields), money: current.isMoney, editable: true, presentation: presentation, attach: {}, remove: {})
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
        }.background(nativePaper)
    }
}
