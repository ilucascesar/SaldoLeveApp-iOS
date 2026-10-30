import SwiftUI

struct NativeFinanceScreen: View {
    @ObservedObject var store: NativeStore
    @ObservedObject var finance: NativeFinanceStore
    let section: NativeAppSection
    var secondary = false
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var status = "all"
    @State private var initialized = false
    @State private var txType = ""
    @State private var txExpense = ""
    @State private var activeOnly = false
    @State private var route: NativeFinanceRoute?
    @AppStorage("nativeMoneyVisible") private var moneyVisible = false
    private var data: NativeFinanceSnapshot { finance.snapshot }
    private var layout: NativeLayoutPreferences { store.layout }
    private var expenses: [JSONObject] {
        ordered(data.expenses.filter { e in
            let id = e.text("id")
            return (section != .shared || e.flag("shared")) && (search.isEmpty || e.text("name").localizedStandardContains(search)) &&
                (status == "all" || (status == "active" && e["active"] != .bool(false)) || (status == "inactive" && e["active"] == .bool(false)) || (status == "pending" && data.isPending(id)) || (status == "paid" && data.paid(id)))
        })
    }
    private var dashboardExpenses: [JSONObject] {
        let all = ordered(data.expenses.filter { layout.dashboardShowPaid || !data.paid($0.text("id")) })
        return layout.dashboardExpenseLimit == 0 ? all : Array(all.prefix(layout.dashboardExpenseLimit))
    }
    private var transactions: [JSONObject] {
        data.transactions(txExpense, activeOnly: activeOnly).filter { tx in (txType.isEmpty || tx.text("type") == txType) && (search.isEmpty || [tx.text("desc"), tx.text("note"), tx.text("category"), data.expense(tx.text("expenseId")).text("name")].joined(separator: " ").localizedStandardContains(search)) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: layout.spacing) {
                    if layout.showMonth { monthHeader }
                    if let issue = finance.issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                    if finance.needsSync { Button("Sincronizar despesas") { Task { await finance.refresh() } }.disabled(finance.loading) }
                    if section == .dashboard { dashboard }
                    else if section == .transactions { transactionContent }
                    else { expenseContent }
                }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
            }.background(nativeCanvas).navigationTitle(section.rawValue)
                .navigationBarTitleDisplayMode(layout.compactHeader ? .inline : .large)
                .financeSearch(enabled: layout.showSearch && section != .dashboard, text: $search)
                .refreshable { await finance.refresh() }
                .toolbar { toolbar }
                .sheet(item: $route) { NativeFinanceModal(finance: finance, route: $0) }
                .task { if finance.needsSync { await finance.refresh() } }
                .onAppear { if !initialized { status = layout.expenseDefaultFilter; initialized = true } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    if (store.section == section || secondary) && !store.isPreview && !finance.busy && (finance.needsSync || Date().timeIntervalSince(finance.syncedAt ?? .distantPast) > 15) { Task { await finance.refresh() } }
                }
        }
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if secondary { Button("Fechar") { dismiss() } }
            else { Button { store.menuOpen = true } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Menu do aplicativo") }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                Button("Personalizar layout") { route = .init(kind: "layout") }
                Button("Próximas faturas") { route = .init(kind: "future") }
                Button("Meses fechados") { route = .init(kind: "closures") }
                Button("Informar renda") { route = .init(kind: "income") }
                Button("Fechar mês") { route = .init(kind: "close") }
                Button("Exportar lançamentos CSV") { export("lancamentos") }
                Button("Exportar resumo mensal CSV") { export("meses") }
            } label: { Image(systemName: "ellipsis.circle") }
            Menu {
                Button("Nova despesa") { route = .init(kind: "expense") }
                Button("Novo gasto") { route = .init(kind: "transaction") }
            } label: { Image(systemName: "plus") }.disabled(!finance.canWrite)
        }
    }
    private var monthHeader: some View {
        HStack { Label(NativeFinanceFormat.month(data.month), systemImage: "calendar").font(.system(size: 13 * layout.textScale, weight: .semibold)); Spacer(); if finance.loading { ProgressView() } else { Text("Mês em aberto").font(.caption2).foregroundStyle(.secondary) } }.padding(.vertical, 5)
    }
    @ViewBuilder private var dashboard: some View {
        ForEach(layout.visibleDashboard, id: \.self) { key in
            switch key {
            case "balance": balance
            case "totals": totals
            case "expenses":
                sectionHeading("Minhas despesas", subtitle: "\(dashboardExpenses.count) contas")
                cards(dashboardExpenses)
            case "pending": pending
            default: shortcuts
            }
        }
    }
    private var balance: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Resumo do mês").font(.headline); Spacer(); Button { moneyVisible.toggle() } label: { Image(systemName: moneyVisible ? "eye" : "eye.slash") }.accessibilityLabel("Mostrar ou ocultar renda e saldo") }
            HStack(alignment: .top) {
                metric("Renda do mês", moneyVisible ? (data.active["income"] == .null ? "Não informada" : NativeFinanceFormat.money(data.active.decimal("income"))) : "••••••", .primary)
                metric("Saldo do mês", moneyVisible ? NativeFinanceFormat.money(data.active.decimal("balance")) : "••••••", data.active.decimal("balance") < 0 ? .red : .green)
            }
            Button("Informar renda") { route = .init(kind: "income") }.font(.subheadline).disabled(!finance.canWrite)
        }.padding(18).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
    }
    private var totals: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: layout.spacing) {
            totalCard("Gastos do mês", NativeFinanceFormat.money(data.active.decimal("spent")), "arrow.up.right", .primary)
            totalCard("Já pago", NativeFinanceFormat.money(data.active.decimal("paid")), "checkmark.circle", .green)
            totalCard("Falta pagar", NativeFinanceFormat.money(data.active.decimal("pending")), "clock", .orange)
            totalCard("Contas pendentes", "\(data.active.integer("pendingCount"))", "wallet.pass", nativeBlue)
        }
    }
    private func totalCard(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) { Image(systemName: icon).foregroundStyle(color); metric(title, value, color) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
    }
    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 12 * layout.textScale)).foregroundStyle(.secondary); Text(value).font(.system(size: 21 * layout.textScale, weight: .semibold, design: layout.roundedValues ? .rounded : .default)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var pending: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pendências do mês").font(.headline)
            if data.active.objects("pendingItems").isEmpty { Label("Tudo em dia", systemImage: "checkmark.circle").foregroundStyle(.green) }
            ForEach(data.active.objects("pendingItems").map { NativeRecord(fields: $0.merging(["id": .string($0.text("expenseId"))]) { _, new in new }) }) { item in
                Button { route = .init(kind: "detail", fields: data.expense(item.id)) } label: { HStack { Text(item.fields.text("name")).foregroundStyle(.primary); Spacer(); Text(NativeFinanceFormat.money(item.fields.decimal("value"))).foregroundStyle(.orange).fontWeight(.semibold) }.font(.system(size: 14 * layout.textScale)) }.padding(.vertical, 3)
            }
        }.padding(18).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
    }
    private var shortcuts: some View {
        VStack(spacing: 14) {
            Button { route = .init(kind: "future") } label: { HStack { Label("Próximas faturas", systemImage: "calendar.badge.clock"); Spacer(); Text(NativeFinanceFormat.money(data.calc.decimal("futureTotal"))).foregroundStyle(.secondary) } }
            HStack { Button("Meses fechados") { route = .init(kind: "closures") }; Spacer(); Button("Fechar mês") { route = .init(kind: "close") }.disabled(!finance.canWrite) }
        }.font(.subheadline).padding(18).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
    }
    private var expenseContent: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(["active", "pending", "paid", "all", "inactive"], id: \.self) { key in Button { status = key } label: { Text(["active":"Ativas", "pending":"Pendentes", "paid":"Pagas", "all":"Todas", "inactive":"Desativadas"][key]!).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(status == key ? .white : Color.primary).background(status == key ? nativeBlue : nativePaper, in: Capsule()) }.buttonStyle(.plain) } }
            }
            if section == .shared { Text("Sua parte no mês: " + NativeFinanceFormat.money(data.active.decimal("sharedConsidered"))).font(.subheadline).foregroundStyle(.secondary) }
            if layout.expenseGrouping == "none" { cards(expenses) }
            else {
                ForEach(groupNames, id: \.self) { name in
                    let group = expenses.filter { groupName($0) == name }
                    sectionHeading(name, subtitle: "\(group.count) contas")
                    cards(group)
                }
            }
            if expenses.isEmpty { Label("Nenhuma despesa neste filtro", systemImage: "wallet.pass").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 48) }
        }
    }
    private func sectionHeading(_ title: String, subtitle: String) -> some View { HStack { Text(title).font(.system(size: 16 * layout.textScale, weight: .semibold)); Spacer(); Text(subtitle).font(.caption).foregroundStyle(.secondary) }.padding(.top, 7) }
    private var groupNames: [String] { Array(Set(expenses.map(groupName))).sorted() }
    private func groupName(_ e: JSONObject) -> String { layout.expenseGrouping == "type" ? NativeFinanceFormat.expenseType(e.text("type")) : data.paid(e.text("id")) ? "Pagas" : "Pendentes" }
    private func cards(_ list: [JSONObject]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: layout.cardColumns >= 3 ? 7 : layout.spacing, alignment: .top), count: layout.cardColumns), alignment: .leading, spacing: layout.cardColumns >= 3 ? 8 : layout.spacing) {
            ForEach(list.map(NativeRecord.init)) { record in
                NativeWebExpenseCard(store: store, finance: finance, expenseID: record.id, route: $route)
                    .draggable("saldoleve-expense:" + record.id)
                    .dropDestination(for: String.self) { values, _ in
                        guard let value = values.first, value.hasPrefix("saldoleve-expense:") else { return false }
                        let allIDs = ordered(data.expenses).map { $0.text("id") }
                        guard let next = NativeExpenseOrder.moving(String(value.dropFirst(18)), before: record.id, in: allIDs) else { return false }
                        guard store.platform.canWrite else { return false }
                        var changed = store.layout; changed.expenseOrder = "manual"; changed.expenseCustomOrder = next
                        let revision = store.platform.snapshot.revision
                        Task { do { try await store.platform.saveLayout(changed, revision: revision) } catch { store.report(error) } }
                        UISelectionFeedbackGenerator().selectionChanged(); return true
                    }
            }
        }
    }
    private var transactionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack {
                Toggle("Só o mês em aberto", isOn: $activeOnly)
                Picker("Despesa", selection: $txExpense) { Text("Todas").tag(""); ForEach(data.expenses.map(NativeRecord.init)) { Text($0.fields.text("name")).tag($0.id) } }
                Picker("Tipo", selection: $txType) { Text("Todos").tag(""); ForEach(["single", "fixed", "installment", "refund"], id: \.self) { Text(NativeFinanceFormat.type($0)).tag($0) } }
            }.padding(16).background(nativePaper, in: RoundedRectangle(cornerRadius: layout.cardRadius))
            sectionHeading("Lançamentos", subtitle: "\(transactions.count) registros")
            ForEach(transactions.map(NativeRecord.init)) { record in Button { route = .init(kind: "transactionDetail", fields: record.fields) } label: { NativeFinanceTransactionRow(data: data, transaction: record.fields).padding(14).background(nativePaper, in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain) }
            if transactions.isEmpty { Text("Nenhum lançamento neste filtro").foregroundStyle(.secondary) }
        }
    }
    private func ordered(_ list: [JSONObject]) -> [JSONObject] {
        let positions = Dictionary(layout.expenseCustomOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return list.enumerated().sorted { a, b in
            let x = a.element, y = b.element, ix = x.text("id"), iy = y.text("id")
            let px = layout.pinnedExpenses.contains(ix), py = layout.pinnedExpenses.contains(iy)
            if px != py { return px }
            switch layout.expenseOrder {
            case "name": return x.text("name").localizedStandardCompare(y.text("name")) == .orderedAscending
            case "amount": let ax = data.expenseCalculation(ix).decimal("integral"), ay = data.expenseCalculation(iy).decimal("integral"); if ax != ay { return ax > ay }
            case "pending": if data.isPending(ix) != data.isPending(iy) { return data.isPending(ix) }
            default: let ox = positions[ix] ?? (positions.count + a.offset), oy = positions[iy] ?? (positions.count + b.offset); if ox != oy { return ox < oy }
            }
            return a.offset < b.offset
        }.map(\.element)
    }
    private func export(_ kind: String) { Task { do { let file = try await store.api.exportFinance(kind: kind); route = .init(kind: "export", fields: ["path": .string(file.path)]) } catch { store.report(error) } } }
}
struct NativeWebExpenseCard: View {
    @ObservedObject var store: NativeStore
    @ObservedObject var finance: NativeFinanceStore
    let expenseID: String
    @Binding var route: NativeFinanceRoute?
    private var data: NativeFinanceSnapshot { finance.snapshot }
    private var e: JSONObject { data.expense(expenseID) }
    private var c: JSONObject { data.expenseCalculation(expenseID) }
    private var p: NativeLayoutPreferences { store.layout }
    private var accent: Color { Color(nativeHex: e.text("accent")) }
    private var compact: Bool { p.cardStyle == "compact" || p.cardColumns == 2 }
    private var progress: JSONObject { data.active.record("paymentProgress").record(expenseID) }
    var body: some View {
        Group { if p.cardColumns >= 3 { miniCard } else { fullCard } }
            .contextMenu { actions }
            .accessibilityIdentifier("expense-card-" + expenseID)
    }
    private var fullCard: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : p.spacing) {
            HStack(alignment: .top, spacing: 9) {
                if p.cardShowIcon { Image(systemName: e.text("type") == "card" ? "creditcard.fill" : e.text("type") == "home" ? "house.fill" : "wallet.pass.fill").font(.system(size: 15)).foregroundStyle(accent).frame(width: 32, height: 32).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)) }
                Button { open("detail") } label: { VStack(alignment: .leading, spacing: 4) { Text(e.text("name")).font(.system(size: (compact ? 15 : 17) * p.textScale, weight: .semibold)).multilineTextAlignment(.leading); if p.cardShowType { Text(NativeFinanceFormat.expenseType(e.text("type"))).font(.system(size: 11 * p.textScale)).foregroundStyle(.secondary).multilineTextAlignment(.leading) } }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                Menu { actions
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30).foregroundStyle(.secondary) }.accessibilityLabel("Opções de " + e.text("name"))
            }
            Button { open("detail") } label: { Text(NativeFinanceFormat.money(c.decimal("integral"))).font(.system(size: (compact ? 23 : 30) * p.textScale, weight: .bold, design: p.roundedValues ? .rounded : .default)).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
            HStack(spacing: 5) { Circle().fill(data.paid(expenseID) ? Color.green : .orange).frame(width: 6, height: 6); Text(e["active"] == .bool(false) ? "Desativada" : data.paid(expenseID) ? "Paga" : "Pendente").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); if p.pinnedExpenses.contains(expenseID) { Spacer(); Image(systemName: "pin.fill").font(.caption2).foregroundStyle(accent) } }
            if p.cardShowShare && e.flag("shared") {
                VStack(alignment: .leading, spacing: 5) { Text("Sua parte: " + NativeFinanceFormat.money(c.decimal("considered"))).font(.system(size: 12 * p.textScale, weight: .semibold)); if progress.flag("ledger") { Text("Pago: " + NativeFinanceFormat.money(progress.decimal("paidCents") / 100) + " · Falta: " + NativeFinanceFormat.money(progress.decimal("pendingCents") / 100)).font(.system(size: 11)).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if p.cardShowBreakdown && !compact && e.text("type") == "card" {
                HStack(spacing: 12) { breakdown("Fatura", data.invoice(expenseID).map { NativeFinanceFormat.money($0.decimal("total")) } ?? "Não informada"); breakdown("Parcelas", NativeFinanceFormat.money(c.decimal("installments"))); breakdown("Outros gastos", data.invoice(expenseID).map { NativeFinanceFormat.money(max(0, $0.decimal("total") - c.decimal("installments"))) } ?? "—") }
            }
            if !data.active.record("paymentChanges").record(expenseID).isEmpty { Label("Valor alterado após pagamento", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange) }
            if p.cardShowActions {
                Divider()
                if !compact { HStack { Button { route = .init(kind: "transaction", fields: ["expenseId": .string(expenseID)]) } label: { Label("Novo gasto", systemImage: "plus") }.disabled(!finance.canWrite); Spacer(); if e.text("type") == "card" { Button("Fatura") { open("invoice") }.disabled(!finance.canWrite) } }.font(.system(size: 13 * p.textScale, weight: .semibold)) }
                Button { pay() } label: { Label(e.flag("shared") ? "Pagamentos" : data.paid(expenseID) ? "Reabrir pagamento" : "Marcar como paga", systemImage: data.paid(expenseID) ? "checkmark.circle.fill" : "circle").font(.system(size: 12 * p.textScale, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10).foregroundStyle(data.paid(expenseID) ? Color.green : accent).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).disabled(!finance.canWrite || (!data.paid(expenseID) && c.decimal("integral") <= 0))
            }
        }.padding(compact ? 13 : 18).background(nativePaper, in: RoundedRectangle(cornerRadius: p.cardRadius))
            .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(accent).frame(height: 3).padding(.horizontal, p.cardRadius) }
            .overlay { RoundedRectangle(cornerRadius: p.cardRadius).strokeBorder(Color.primary.opacity(0.055), lineWidth: 1) }
    }
    private var miniCard: some View {
        Button { open("detail") } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 3) {
                    if p.cardShowIcon { Image(systemName: e.text("type") == "card" ? "creditcard.fill" : e.text("type") == "home" ? "house.fill" : "wallet.pass.fill").font(.system(size: 13)).foregroundStyle(accent) }
                    Spacer(minLength: 0)
                    Circle().fill(data.paid(expenseID) ? Color.green : e["active"] == .bool(false) ? .gray : .orange).frame(width: 5, height: 5)
                }
                Text(e.text("name")).font(.system(size: 11 * p.textScale, weight: .semibold)).lineLimit(2).frame(height: 30 * p.textScale, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
                Text(NativeFinanceFormat.money(c.decimal("integral"))).font(.system(size: (p.cardColumns == 4 ? 13 : 16) * p.textScale, weight: .bold, design: p.roundedValues ? .rounded : .default)).lineLimit(1).minimumScaleFactor(0.6)
                if p.cardShowType { Text(e.text("type") == "card" ? "Cartão" : e.text("type") == "home" ? "Casa" : "Outros").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                if p.cardShowShare && e.flag("shared") { Text("Sua parte").font(.system(size: 9)).foregroundStyle(.secondary); Text(NativeFinanceFormat.money(c.decimal("considered"))).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6) }
                if p.cardShowActions { HStack(spacing: 2) { Text(e["active"] == .bool(false) ? "Inativa" : data.paid(expenseID) ? "Paga" : "Pendente").font(.system(size: 9)); Spacer(minLength: 0); Image(systemName: "ellipsis").font(.system(size: 10)) }.foregroundStyle(.secondary) }
            }.padding(p.cardColumns == 4 ? 8 : 10).frame(maxWidth: .infinity, minHeight: p.cardShowShare && e.flag("shared") ? 152 : 120, alignment: .topLeading)
                .background(nativePaper, in: RoundedRectangle(cornerRadius: min(14, p.cardRadius)))
                .overlay(alignment: .top) { Capsule().fill(accent).frame(height: 3).padding(.horizontal, 12) }
                .overlay { RoundedRectangle(cornerRadius: min(14, p.cardRadius)).strokeBorder(accent.opacity(0.13), lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityHint("Toque para abrir. Mantenha pressionado para ações ou arraste para reorganizar.")
    }
    @ViewBuilder private var actions: some View {
        Button { open("detail") } label: { Label("Abrir detalhes", systemImage: "info.circle") }
        Button { route = .init(kind: "transaction", fields: ["expenseId": .string(expenseID)]) } label: { Label("Novo gasto", systemImage: "plus") }.disabled(!finance.canWrite)
        if e.text("type") == "card" { Button { open("invoice") } label: { Label("Informar fatura", systemImage: "creditcard") }.disabled(!finance.canWrite) }
        Button { pay() } label: { Label(e.flag("shared") ? "Registrar pagamento" : data.paid(expenseID) ? "Reabrir pagamento" : "Marcar como paga", systemImage: "checkmark.circle") }.disabled(!finance.canWrite)
        Button { open("payments") } label: { Label("Pagamentos e divisão", systemImage: "person.2") }
        Button { open("expense") } label: { Label("Editar despesa", systemImage: "pencil") }.disabled(!finance.canWrite)
        Button { open("reminders") } label: { Label("Lembretes", systemImage: "bell") }
        Button { var changed = store.layout
            if p.pinnedExpenses.contains(expenseID) { changed.pinnedExpenses.removeAll { $0 == expenseID } } else { changed.pinnedExpenses.append(expenseID) }
            let revision = store.platform.snapshot.revision
            Task { do { try await store.platform.saveLayout(changed, revision: revision) } catch { store.report(error) } } } label: { Label(p.pinnedExpenses.contains(expenseID) ? "Desafixar" : "Fixar no início", systemImage: "pin") }.disabled(!store.platform.canWrite)
        Button { open("layout") } label: { Label("Personalizar cards", systemImage: "slider.horizontal.3") }
    }
    private func breakdown(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func open(_ kind: String) { route = .init(kind: kind, fields: e) }
    private func pay() { if e.flag("shared") { open("payments") } else { Task { do { _ = try await finance.save("toggle_payment", ["expenseId": .string(expenseID), "paid": .bool(!data.paid(expenseID))]) } catch { store.report(error) } } } }
}
extension View {
    @ViewBuilder func financeSearch(enabled: Bool, text: Binding<String>) -> some View { if enabled { self.searchable(text: text, prompt: "Buscar despesa ou lançamento") } else { self } }
}
