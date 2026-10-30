import SwiftUI

struct NativeFinanceModal: View {
    @ObservedObject var finance: NativeFinanceStore
    let route: NativeFinanceRoute
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        switch route.kind {
        case "moduleTransactions": NativeFinanceScreen(store: finance.parent, finance: finance, section: .transactions, secondary: true)
        case "moduleShared": NativeFinanceScreen(store: finance.parent, finance: finance, section: .shared, secondary: true)
        case "settings": NativeSettingsView(store: finance.parent)
        case "remote": NativeSettingsView(store: finance.parent, initialPage: .menus)
        case "birthdays": NativeBirthdaysView(store: finance.parent, platform: finance.parent.platform, initialID: route.fields.text("id"))
        case "search": NativeUnifiedSearch(store: finance.parent, platform: finance.parent.platform)
        case "taskHistory": NativeHistoryView(store: finance.parent, taskID: route.fields.text("id"))
        case "layout": NativeSettingsView(store: finance.parent, initialPage: .layout)
        case "widgets": NativeSettingsView(store: finance.parent, initialPage: .widgets)
        case "profile": NativeProfileView(store: finance.parent)
        case "focus": NativeDailyFocus(store: finance.parent)
        case "detail": NativeFinanceExpenseDetail(finance: finance, expenseID: route.fields.text("id"))
        case "expense": NativeExpenseEditor(finance: finance, original: route.fields)
        case "transaction": NativeTransactionEditor(finance: finance, original: route.fields)
        case "transactionDetail": NativeTransactionDetail(finance: finance, original: route.fields)
        case "future": NativeFutureInvoices(finance: finance, expenseID: route.fields.text("id"))
        case "closures": NativeFinanceClosures(finance: finance)
        case "reminders": NativeExpenseReminders(finance: finance, expenseID: route.fields.text("id"))
        case "payments": NativeExpensePayments(finance: finance, expenseID: route.fields.text("id"))
        case "previewNotifications": NativeSettingsView(store: finance.parent, initialPage: .notifications)
        case "export": NativeShareSheet(items: [URL(fileURLWithPath: route.fields.text("path"))])
        default: NativeFinanceActionForm(finance: finance, route: route)
        }
    }
}
struct NativeFinanceExpenseDetail: View {
    @ObservedObject var finance: NativeFinanceStore
    let expenseID: String
    @State private var route: NativeFinanceRoute?
    @State private var deactivate = false
    @State private var allTransactions = false
    @Environment(\.dismiss) private var dismiss
    private var data: NativeFinanceSnapshot { finance.snapshot }
    private var expense: JSONObject { data.expense(expenseID) }
    private var calculation: JSONObject { data.expenseCalculation(expenseID) }
    var body: some View {
        NavigationStack {
            List {
                Section { NativeExpenseCard(finance: finance, expenseID: expenseID, open: { if expense.flag("shared") { route = .init(kind: "payments", fields: expense) } }) }
                if expense.text("type") == "card" {
                    Section("Fatura de \(NativeFinanceFormat.month(data.month))") {
                        LabeledContent("Fatura informada", value: data.invoice(expenseID).map { NativeFinanceFormat.money($0.decimal("total")) } ?? "Não informada")
                        LabeledContent("Parcelas", value: NativeFinanceFormat.money(calculation.decimal("installments")))
                        LabeledContent("Outros gastos", value: data.invoice(expenseID).map { NativeFinanceFormat.money(max(0, $0.decimal("total") - calculation.decimal("installments"))) } ?? "—")
                        Button("Informar ou atualizar fatura") { route = .init(kind: "invoice", fields: expense) }.disabled(!finance.canWrite)
                    }
                }
                if !data.active.record("paymentChanges").record(expenseID).isEmpty {
                    Section("Valor alterado após pagamento") {
                        LabeledContent("Valor registrado", value: NativeFinanceFormat.money(data.active.record("paymentChanges").record(expenseID).decimal("paidIntegral")))
                        LabeledContent("Valor atual", value: NativeFinanceFormat.money(calculation.decimal("integral")))
                        Button("Atualizar pagamento para o valor atual") { save("toggle_payment", ["expenseId": .string(expenseID), "paid": .bool(true)]) }.disabled(!finance.canWrite)
                    }
                }
                if expense.flag("shared") {
                    Section("Divisão da despesa") {
                        ForEach(expense.objects("participants").map(NativeRecord.init)) { user in
                            HStack { Text(user.fields.text("name")); Spacer(); Text("\(user.fields.decimal("percent").formatted())% · \(NativeFinanceFormat.money(calculation.decimal("integral") * user.fields.decimal("percent") / 100))").font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    Section { Button("Registrar e acompanhar pagamentos parciais") { route = .init(kind: "payments", fields: expense) }.disabled(!finance.canWrite) }
                }
                Section {
                    Button { route = .init(kind: "transaction", fields: ["expenseId": .string(expenseID)]) } label: { Label("Novo gasto", systemImage: "plus.circle") }.disabled(!finance.canWrite || expense["active"] == .bool(false))
                    Button { route = .init(kind: "future", fields: expense) } label: { Label("Próximas faturas", systemImage: "calendar.badge.clock") }
                    Button { route = .init(kind: "reminders", fields: expense) } label: { Label("Lembretes", systemImage: "bell") }
                    if expense.text("ownerId") == finance.parent.user?.id {
                        Button("Editar despesa e divisão") { route = .init(kind: "expense", fields: expense) }.disabled(!finance.canWrite || expense["active"] == .bool(false))
                        Button(expense["active"] == .bool(false) ? "Reativar despesa" : "Desativar despesa", role: expense["active"] == .bool(false) ? nil : .destructive) { deactivate = true }.disabled(!finance.canWrite)
                    }
                }
                Section {
                    Toggle("Mostrar todos os meses", isOn: $allTransactions)
                    ForEach(data.transactions(expenseID, activeOnly: !allTransactions).map(NativeRecord.init)) { transaction in
                        Button { route = .init(kind: "transactionDetail", fields: transaction.fields) } label: { NativeFinanceTransactionRow(data: data, transaction: transaction.fields) }.foregroundStyle(.primary)
                    }
                } header: { Text("Lançamentos") }
            }.navigationTitle(expense.text("name")).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Fechar") { dismiss() } }
                .sheet(item: $route) { NativeFinanceModal(finance: finance, route: $0) }
                .confirmationDialog(expense["active"] == .bool(false) ? "Reativar despesa?" : "Desativar despesa?", isPresented: $deactivate, titleVisibility: .visible) {
                    Button(expense["active"] == .bool(false) ? "Reativar" : "Desativar", role: expense["active"] == .bool(false) ? nil : .destructive) { save("set_expense_active", ["id": .string(expenseID), "active": .bool(expense["active"] == .bool(false))]) }
                } message: { Text("Lançamentos, faturas, pagamentos e histórico serão preservados. Desativar impede novos gastos.") }
        }
    }
    private func save(_ action: String, _ body: JSONObject) { Task { do { _ = try await finance.save(action, body) } catch { finance.parent.report(error) } } }
}
struct NativeExpenseEditor: View {
    @ObservedObject var finance: NativeFinanceStore
    let original: JSONObject
    @State private var name = ""
    @State private var type = "card"
    @State private var shared = false
    @State private var selected = Set<String>()
    @State private var shares: [String: String] = [:]
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss
    private var ownerID: String { finance.parent.user?.id ?? "" }
    private var ids: [String] { [ownerID] + selected.sorted() }
    var body: some View {
        NavigationStack {
            Form {
                Section("Despesa") {
                    TextField("Nome", text: $name).onChange(of: name) { name = String($0.prefix(150)) }
                    Picker("Tipo", selection: $type) { Text("Cartão de crédito").tag("card"); Text("Despesa da casa").tag("home"); Text("Outros").tag("other") }
                }
                Section {
                    Toggle("Compartilhar despesa", isOn: $shared)
                    if shared {
                        ForEach(finance.snapshot.users.filter { $0.text("id") != ownerID }.map(NativeRecord.init)) { user in
                            Toggle(user.fields.text("name"), isOn: Binding(get: { selected.contains(user.id) }, set: { enabled in if enabled { selected.insert(user.id) } else { selected.remove(user.id) }; equalShares() }))
                        }
                    }
                } footer: { Text("As pessoas selecionadas poderão consultar e registrar lançamentos nesta despesa, como no sistema web.") }
                if shared {
                    Section("Divisão em percentuais") {
                        ForEach(ids, id: \.self) { id in
                            HStack { Text(finance.snapshot.users.first { $0.text("id") == id }?.text("name") ?? "Você"); Spacer(); TextField("%", text: Binding(get: { shares[id] ?? "0" }, set: { shares[id] = $0 })).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80); Text("%") }
                        }
                        Button("Dividir igualmente") { equalShares() }
                        Text("A soma deve ser exatamente 100%.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let issue { Section { Text(issue).foregroundStyle(.red) } }
            }.navigationTitle(original.text("id").isEmpty ? "Nova despesa" : "Editar despesa").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(finance.busy) }; ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.disabled(!finance.canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (shared && selected.isEmpty)) } }
                .onAppear { name = original.text("name"); type = original.text("type").isEmpty ? "card" : original.text("type"); shared = original.flag("shared"); selected = Set(original["sharedWith"]?.array.map(\.string).filter { $0 != ownerID } ?? []); for user in original.objects("participants") { shares[user.text("id")] = NativeFinanceFormat.input(user.decimal("percent")) }; if shares.isEmpty { equalShares() } }
        }.interactiveDismissDisabled(finance.busy)
    }
    private func equalShares() {
        let base = 10000 / max(1, ids.count)
        for (index, id) in ids.enumerated() { shares[id] = NativeFinanceFormat.input(Double(index == 0 ? 10000 - base * (ids.count - 1) : base) / 100) }
    }
    private func save() {
        Task { do {
            let division = shared ? try NativeFinanceFormat.shares(shares, ids: ids) : [:]
            var body: JSONObject = ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "type": .string(type), "sharedWith": .array(shared ? selected.sorted().map(JSONValue.string) : []), "shares": .object(division)]
            if !original.text("id").isEmpty { body["id"] = original["id"] }
            _ = try await finance.save(original.text("id").isEmpty ? "create_expense" : "update_expense", body); dismiss()
        } catch { issue = error.localizedDescription } }
    }
}
struct NativeTransactionEditor: View {
    @ObservedObject var finance: NativeFinanceStore
    let original: JSONObject
    @State private var expenseID = ""
    @State private var description = ""
    @State private var suggestions = false
    @State private var type = "single"
    @State private var category = "Outros"
    @State private var amount = ""
    @State private var parcel = ""
    @State private var installments = 2
    @State private var installmentStart = 1
    @State private var day = Date()
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var note = ""
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss
    private var editing: Bool { !original.text("id").isEmpty }
    private var selectableExpenses: [JSONObject] { finance.snapshot.expenses.filter { $0["active"] != .bool(false) || $0.text("id") == original.text("expenseId") } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Lançamento") {
                    Picker("Despesa", selection: $expenseID) { ForEach(selectableExpenses.map(NativeRecord.init)) { Text($0.fields.text("name")).tag($0.id) } }
                    TextField("Descrição", text: $description).onChange(of: description) { description = String($0.prefix(150)) }
                    if finance.parent.platform.enabled("suggestions") { Button { suggestions = true } label: { Label("Sugerir organização pelo histórico", systemImage: "sparkles") }.disabled(!finance.canWrite || description.count < 3) }
                    Picker("Tipo", selection: $type) { ForEach(["single", "fixed", "installment", "refund"], id: \.self) { Text(NativeFinanceFormat.type($0)).tag($0) } }
                    DatePicker(type == "refund" ? "Data do estorno" : "Data da compra", selection: $day, displayedComponents: .date)
                    Picker("Categoria", selection: $category) { ForEach(Array(Set(finance.snapshot.categories.map { $0.text("name") } + [category, "Outros"])).sorted(), id: \.self) { Text($0).tag($0) } }
                    TextField(type == "refund" ? "Valor devolvido" : "Valor total", text: $amount).keyboardType(.decimalPad)
                    if type == "refund" { Text("Informe um valor positivo. O estorno será abatido pelo servidor.").font(.footnote).foregroundStyle(.secondary) }
                }
                if type == "installment" {
                    Section("Parcelamento") {
                        Stepper("Total: \(installments) parcelas", value: $installments, in: 2...120).onChange(of: installments) { installmentStart = min(installmentStart, $0) }
                        Stepper("Começar na parcela \(installmentStart)", value: $installmentStart, in: 1...installments)
                        HStack { TextField("Ou informe o valor da parcela", text: $parcel).keyboardType(.decimalPad); Button("Calcular total") { do { amount = NativeFinanceFormat.input(try NativeFinanceFormat.amount(parcel) * Double(installments)) } catch { issue = error.localizedDescription } } }
                        if let cents = NativeDate.cents(amount), cents > 0 { Text("Parcela aproximada: \(NativeFinanceFormat.money(Double(cents / installments) / 100)). O servidor ajusta os centavos na última parcela.").font(.footnote).foregroundStyle(.secondary) }
                        Text("A primeira parcela entra no mês seguinte à data da compra, seguindo a regra do site.").font(.footnote).foregroundStyle(.secondary)
                        if !original.text("settledMonth").isEmpty { Text("Este parcelamento está quitado. Alterar o período pode remover a quitação; o servidor fará essa validação.").font(.footnote).foregroundStyle(.orange) }
                    }
                }
                if type == "fixed" {
                    Section("Cobrança fixa") { Toggle("Definir último mês de cobrança", isOn: $hasEnd); if hasEnd { DatePicker("Último mês (use qualquer dia)", selection: $end, displayedComponents: .date); Text(NativeFinanceFormat.month(String(NativeFinanceFormat.day(end).prefix(7)))).font(.caption).foregroundStyle(.secondary) } }
                }
                Section("Observação") { TextEditor(text: $note).frame(minHeight: 90).onChange(of: note) { note = String($0.prefix(1000)) } }
                if let issue { Section { Text(issue).foregroundStyle(.red) } }
            }.navigationTitle(editing ? "Editar lançamento" : type == "refund" ? "Novo estorno" : "Novo gasto").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(finance.busy) }; ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.disabled(!finance.canWrite || expenseID.isEmpty || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
                .sheet(isPresented: $suggestions) { NativeSmartSuggestions(store: finance.parent, context: "transaction", text: description, excludeID: original.text("id")) { values in if let id = values["expenseId"]?.string { expenseID = id }; if let name = values["category"]?.string { category = name } } }
                .onAppear {
                    expenseID = original.text("expenseId").isEmpty ? selectableExpenses.first?.text("id") ?? "" : original.text("expenseId")
                    description = original.text("desc"); type = original.text("type").isEmpty ? "single" : original.text("type"); category = original.text("category").isEmpty ? "Outros" : original.text("category")
                    amount = editing ? NativeFinanceFormat.input(original.decimal("amount")) : ""; installments = max(2, original.integer("installments")); installmentStart = max(1, original.integer("installmentNoAtStart")); note = original.text("note")
                    day = NativeFinanceFormat.date(original.text("date")) ?? NativeFinanceFormat.date(finance.snapshot.month + "-01") ?? Date()
                    hasEnd = !original.text("endMonth").isEmpty; end = NativeFinanceFormat.date(original.text("endMonth") + "-01") ?? day
                }
        }.interactiveDismissDisabled(finance.busy)
    }
    private func save() {
        Task { do {
            var body: JSONObject = ["expenseId": .string(expenseID), "desc": .string(description.trimmingCharacters(in: .whitespacesAndNewlines)), "category": .string(category), "amount": .number(try NativeFinanceFormat.amount(amount)), "type": .string(type), "date": .string(NativeFinanceFormat.day(day)), "note": .string(note)]
            if editing { body["id"] = original["id"] }
            if type == "installment" { body["installments"] = .number(Double(installments)); body["installmentStart"] = .number(Double(installmentStart)) }
            if type == "fixed" { body["endMonth"] = hasEnd ? .string(String(NativeFinanceFormat.day(end).prefix(7))) : .null }
            let response = try await finance.save(editing ? "update_transaction" : "create_transaction", body)
            if response.text("message").contains("quitação foi removida") { finance.parent.message = response.text("message") }
            dismiss()
        } catch { issue = error.localizedDescription } }
    }
}
struct NativeTransactionDetail: View {
    @ObservedObject var finance: NativeFinanceStore
    let original: JSONObject
    @State private var route: NativeFinanceRoute?
    @State private var deleting = false
    @State private var undo = false
    @Environment(\.dismiss) private var dismiss
    private var transaction: JSONObject { finance.snapshot.transactions.first { $0.text("id") == original.text("id") } ?? original }
    private var calculation: JSONObject { finance.snapshot.transactionCalculation(transaction.text("id")) }
    var body: some View {
        NavigationStack {
            List {
                Section { NativeFinanceTransactionRow(data: finance.snapshot, transaction: transaction); LabeledContent("Valor total", value: NativeFinanceFormat.money(transaction.decimal("amount"))); if !transaction.text("note").isEmpty { Text(transaction.text("note")) } }
                if transaction.text("type") == "installment" {
                    Section("Parcelamento") {
                        LabeledContent("Parcelas", value: "\(transaction.integer("installments"))")
                        LabeledContent("Início", value: NativeFinanceFormat.month(transaction.text("startMonth")))
                        LabeledContent("Fim", value: NativeFinanceFormat.month(transaction.text("endMonth")))
                        LabeledContent("Restante após este mês", value: NativeFinanceFormat.money(calculation.decimal("remainingValueAfterActive")))
                        if !transaction.text("settledMonth").isEmpty { LabeledContent("Quitado em", value: NativeFinanceFormat.month(transaction.text("settledMonth"))); LabeledContent("Desconto", value: NativeFinanceFormat.money(transaction.decimal("settledDiscount"))) }
                        if calculation.flag("canSettle") { Button("Quitar / antecipar parcelas") { route = .init(kind: "settle", fields: transaction) }.disabled(!finance.canWrite) }
                        if calculation.flag("canUnsettle") { Button("Desfazer quitação") { undo = true }.disabled(!finance.canWrite) }
                    }
                }
                if transaction.text("type") == "fixed" { Section("Cobrança fixa") { LabeledContent("Início", value: NativeFinanceFormat.month(transaction.text("startMonth"))); LabeledContent("Último mês", value: transaction.text("endMonth").isEmpty ? "Sem fim" : NativeFinanceFormat.month(transaction.text("endMonth"))); Button("Alterar valor somente de um mês") { route = .init(kind: "fixedAmount", fields: transaction) }.disabled(!finance.canWrite); Button("Encerrar ou retomar cobrança") { route = .init(kind: "fixed", fields: transaction) }.disabled(!finance.canWrite) }; Section("Valores informados por mês") { ForEach(transaction.record("monthlyAmounts").keys.sorted(), id: \.self) { month in LabeledContent(NativeFinanceFormat.month(month), value: NativeFinanceFormat.money(transaction.record("monthlyAmounts").decimal(month))) } } }
                Section { Button("Editar lançamento") { route = .init(kind: "transaction", fields: transaction) }.disabled(!finance.canWrite); Button("Excluir lançamento", role: .destructive) { deleting = true }.disabled(!finance.canWrite) }
            }.navigationTitle("Lançamento").navigationBarTitleDisplayMode(.inline).toolbar { Button("Fechar") { dismiss() } }
                .sheet(item: $route) { NativeFinanceModal(finance: finance, route: $0) }
                .confirmationDialog("Excluir este lançamento?", isPresented: $deleting, titleVisibility: .visible) { Button("Excluir lançamento", role: .destructive) { perform("delete_transaction") } } message: { Text("O servidor impede alterações em valores de meses fechados.") }
                .confirmationDialog("Desfazer quitação?", isPresented: $undo, titleVisibility: .visible) { Button("Desfazer quitação") { perform("unsettle_installment", close: false) } } message: { Text("As parcelas restantes voltarão aos próximos meses.") }
        }
    }
    private func perform(_ action: String, close: Bool = true) { Task { do { _ = try await finance.save(action, ["id": transaction["id"] ?? .string("")]); if close { dismiss() } } catch { finance.parent.report(error) } } }
}
