import SwiftUI

struct NativeFinanceActionForm: View {
    @ObservedObject var finance: NativeFinanceStore
    let route: NativeFinanceRoute
    @State private var amount = ""
    @State private var note = ""
    @State private var acceptPending = false
    @State private var end = Date()
    @State private var resume = false
    @State private var issue: String?
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss
    private var data: NativeFinanceSnapshot { finance.snapshot }
    private var calculation: JSONObject { data.transactionCalculation(route.fields.text("id")) }
    private var title: String { ["income": "Renda do mês", "invoice": "Informar fatura", "settle": "Quitar parcelamento", "fixed": "Cobrança fixa", "fixedAmount": "Valor deste mês", "close": "Fechar mês"][route.kind] ?? "SaldoLeve" }
    private var hasIncome: Bool { data.fields.objects("incomes").contains { $0.text("month") == data.month } }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(NativeFinanceFormat.month(data.month)).font(.headline) }
                if route.kind == "income" {
                    Section { TextField("Renda deste mês", text: $amount).keyboardType(.decimalPad) } footer: { Text("O saldo usa sua renda menos sua parte nas despesas, calculada pelo servidor.") }
                } else if route.kind == "invoice" {
                    Section(route.fields.text("name")) {
                        TextField("Valor total da fatura", text: $amount).keyboardType(.decimalPad)
                        LabeledContent("Parcelas do mês", value: NativeFinanceFormat.money(data.expenseCalculation(route.fields.text("id")).decimal("installments")))
                        if let cents = NativeDate.cents(amount) { LabeledContent("Outros gastos", value: NativeFinanceFormat.money(max(0, Double(cents) / 100 - data.expenseCalculation(route.fields.text("id")).decimal("installments")))) }
                    }
                    Text("A fatura informada passa a ser o total do cartão neste mês, como no web.").font(.footnote).foregroundStyle(.secondary)
                } else if route.kind == "settle" {
                    Section(route.fields.text("desc")) {
                        LabeledContent("Parcela deste mês", value: NativeFinanceFormat.money(calculation.decimal("activeValue")))
                        LabeledContent("Parcelas futuras", value: "\(calculation.integer("remainingAfterActive"))")
                        LabeledContent("Saldo futuro", value: NativeFinanceFormat.money(calculation.decimal("remainingValueAfterActive")))
                        TextField("Valor pago pela antecipação", text: $amount).keyboardType(.decimalPad)
                        if let cents = NativeDate.cents(amount) {
                            LabeledContent("Desconto", value: NativeFinanceFormat.money(max(0, calculation.decimal("remainingValueAfterActive") - Double(cents) / 100)))
                            LabeledContent("Total neste mês", value: NativeFinanceFormat.money(calculation.decimal("activeValue") + Double(cents) / 100))
                        }
                    }
                    if data.paid(route.fields.text("expenseId")) { Text("Esta despesa já está paga. Após quitar, confira e atualize o pagamento na despesa.").font(.footnote).foregroundStyle(.orange) }
                    if data.invoice(route.fields.text("expenseId")) != nil { Text("A fatura informada continua valendo. Atualize-a se a antecipação entrou nela.").font(.footnote).foregroundStyle(.orange) }
                } else if route.kind == "fixedAmount" {
                    Section(route.fields.text("desc")) { DatePicker("Mês (use qualquer dia)", selection: $end, displayedComponents: .date); Text(NativeFinanceFormat.month(String(NativeFinanceFormat.day(end).prefix(7)))).foregroundStyle(.secondary); TextField("Valor somente deste mês", text: $amount).keyboardType(.decimalPad); Toggle("Voltar ao valor base neste mês", isOn: $resume) }
                    Text("Os outros meses e os valores já informados ficam preservados. Meses fechados precisam ser reabertos antes de alterar.").font(.footnote).foregroundStyle(.secondary)
                } else if route.kind == "fixed" {
                    Section(route.fields.text("desc")) {
                        Toggle("Retomar cobrança sem data de fim", isOn: $resume)
                        if !resume { DatePicker("Último mês com cobrança", selection: $end, displayedComponents: .date); Text(NativeFinanceFormat.month(String(NativeFinanceFormat.day(end).prefix(7)))).foregroundStyle(.secondary) }
                    }
                } else if route.kind == "close" {
                    Section("Resumo do fechamento") {
                        LabeledContent("Renda", value: NativeFinanceFormat.money(data.active.decimal("income")))
                        LabeledContent("Gastos", value: NativeFinanceFormat.money(data.active.decimal("spent")))
                        LabeledContent("Saldo", value: NativeFinanceFormat.money(data.active.decimal("balance")))
                        LabeledContent("Pago", value: NativeFinanceFormat.money(data.active.decimal("paid")))
                        LabeledContent("Pendente", value: NativeFinanceFormat.money(data.active.decimal("pending")))
                    }
                    if !hasIncome { Text("Informe a renda antes de fechar este mês.").foregroundStyle(.red) }
                    if data.active.integer("pendingCount") > 0 {
                        Section("Contas ainda pendentes") {
                            ForEach(data.active.objects("pendingItems").map { NativeRecord(fields: $0.merging(["id": .string($0.text("expenseId"))]) { _, new in new }) }) { record in LabeledContent(record.fields.text("name"), value: NativeFinanceFormat.money(record.fields.decimal("value"))) }
                            Toggle("Estou ciente e quero fechar com pendências", isOn: $acceptPending)
                        }
                    }
                    Section("Observações") { TextEditor(text: $note).frame(minHeight: 90).onChange(of: note) { note = String($0.prefix(1000)) } }
                    Text("O fechamento salva o retrato do mês e avança o mês em aberto. Os valores serão novamente conferidos pelo servidor.").font(.footnote).foregroundStyle(.secondary)
                }
                if let issue { Section { Text(issue).foregroundStyle(.red); if finance.needsSync { Button("Sincronizar e conferir") { Task { await finance.refresh() } } } } }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(finance.busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(route.kind == "close" ? "Fechar mês" : "Salvar") { if ["close", "settle", "fixed"].contains(route.kind) { confirming = true } else { save() } }.disabled(!finance.canWrite || (route.kind == "close" && (!hasIncome || (data.active.integer("pendingCount") > 0 && !acceptPending)))) }
                }
                .confirmationDialog(title + "?", isPresented: $confirming, titleVisibility: .visible) { Button("Confirmar") { save() } }
                .onChange(of: end) { date in if route.kind == "fixedAmount" { let month = String(NativeFinanceFormat.day(date).prefix(7)); amount = NativeFinanceFormat.input(route.fields.record("monthlyAmounts")[month]?.number ?? route.fields.decimal("amount")) } }
                .onAppear {
                    if route.kind == "income" { amount = NativeFinanceFormat.input(data.active.decimal("income")) }
                    if route.kind == "invoice" { amount = data.invoice(route.fields.text("id")).map { NativeFinanceFormat.input($0.decimal("total")) } ?? "" }
                    if route.kind == "settle" { amount = NativeFinanceFormat.input(calculation.decimal("remainingValueAfterActive")) }
                    if route.kind == "fixedAmount" { amount = NativeFinanceFormat.input(calculation.decimal("activeValue")) }
                    end = NativeFinanceFormat.date((route.kind == "fixedAmount" || route.fields.text("endMonth").isEmpty ? data.month : route.fields.text("endMonth")) + "-01") ?? Date()
                }
        }.interactiveDismissDisabled(finance.busy)
    }
    private func save() {
        Task { do {
            let action: String; var body: JSONObject = [:]
            switch route.kind {
            case "income": action = "save_income"; body["amount"] = .number(try NativeFinanceFormat.amount(amount, allowZero: true))
            case "invoice": action = "save_invoice"; body = ["expenseId": route.fields["id"] ?? .string(""), "total": .number(try NativeFinanceFormat.amount(amount))]
            case "settle":
                let paid = try NativeFinanceFormat.amount(amount)
                guard paid <= calculation.decimal("remainingValueAfterActive") + 0.009 else { throw NativeFailure("O valor não pode superar o saldo futuro.") }
                action = "settle_installment"; body = ["id": route.fields["id"] ?? .string(""), "paidAmount": .number(paid)]
            case "fixed": action = "end_fixed"; body = ["id": route.fields["id"] ?? .string(""), "endMonth": resume ? .null : .string(String(NativeFinanceFormat.day(end).prefix(7)))]
            case "fixedAmount": action = "set_fixed_month_amount"; body = ["id": route.fields["id"] ?? .string(""), "month": .string(String(NativeFinanceFormat.day(end).prefix(7))), "clear": .bool(resume), "amount": .number(resume ? 0 : try NativeFinanceFormat.amount(amount, allowZero: true))]
            case "close": action = "close_month"; body = ["note": .string(note), "acceptPending": .bool(acceptPending)]
            default: return
            }
            _ = try await finance.save(action, body); dismiss()
        } catch { issue = error.localizedDescription } }
    }
}
struct NativeFutureInvoices: View {
    @ObservedObject var finance: NativeFinanceStore
    var expenseID = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(finance.snapshot.future.filter { expenseID.isEmpty || $0.text("expenseId") == expenseID }.map { NativeRecord(fields: $0.merging(["id": .string($0.text("expenseId"))]) { _, new in new }) }) { group in
                    Section(finance.snapshot.expense(group.id).text("name")) {
                        LabeledContent("Compromissos futuros", value: NativeFinanceFormat.money(group.fields.decimal("total")))
                        ForEach(group.fields.objects("months").map { NativeRecord(fields: $0.merging(["id": .string($0.text("month"))]) { _, new in new }) }) { month in
                            VStack(alignment: .leading, spacing: 6) { HStack { Text(NativeFinanceFormat.month(month.id)); Spacer(); Text(NativeFinanceFormat.money(month.fields.decimal("total"))).fontWeight(.semibold) }; Text("Parcelas: \(NativeFinanceFormat.money(month.fields.decimal("installments"))) · Fixos: \(NativeFinanceFormat.money(month.fields.decimal("fixed")))").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 4)
                        }
                    }
                }
                Section { Text("Projeção calculada pelo servidor com parcelas e fixos até o fim dos parcelamentos. Novos gastos e valores integrais de faturas futuras ainda não informadas não estão previstos.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Próximas faturas").navigationBarTitleDisplayMode(.inline).toolbar { Button("Fechar") { dismiss() } }
        }
    }
}
struct NativeFinanceClosures: View {
    @ObservedObject var finance: NativeFinanceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(finance.snapshot.closures.map(NativeRecord.init)) { closure in
                    NavigationLink { NativeClosureDetail(finance: finance, record: closure.fields) } label: {
                        VStack(alignment: .leading, spacing: 7) { Text(NativeFinanceFormat.month(closure.fields.text("month"))).font(.headline); Text("Gastos: \(NativeFinanceFormat.money(closure.fields.decimal("spent"))) · Saldo: \(NativeFinanceFormat.money(closure.fields.decimal("balance")))").font(.subheadline).foregroundStyle(.secondary); if closure.fields.flag("closedWithPending") { Text("Fechado com pendências").font(.caption).foregroundStyle(.orange) } }
                    }
                }
                if finance.snapshot.closures.isEmpty { Text("Nenhum mês fechado.").foregroundStyle(.secondary) }
            }.navigationTitle("Meses fechados").toolbar { Button("Fechar") { dismiss() } }
        }
    }
}
struct NativeClosureDetail: View {
    @ObservedObject var finance: NativeFinanceStore
    let record: JSONObject
    @State private var details: JSONObject = [:]
    @State private var search = ""
    @State private var issue: String?
    @State private var reopen = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("Retrato salvo no fechamento") {
                LabeledContent("Renda", value: NativeFinanceFormat.money(record.decimal("income")))
                LabeledContent("Gastos", value: NativeFinanceFormat.money(record.decimal("spent")))
                LabeledContent("Saldo", value: NativeFinanceFormat.money(record.decimal("balance")))
                if !record.text("note").isEmpty { Text(record.text("note")) }
            }
            Section("Despesas") {
                ForEach(details.objects("expenses").filter { search.isEmpty || $0.text("name").localizedStandardContains(search) }.map(NativeRecord.init)) { expense in
                    VStack(alignment: .leading, spacing: 6) { HStack { Text(expense.fields.text("name")); Spacer(); Text(NativeFinanceFormat.money(expense.fields.decimal("considered"))) }; Text("Integral: \(NativeFinanceFormat.money(expense.fields.decimal("integral"))) · \(expense.fields.flag("paid") ? "Paga" : "Pendente")").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Lançamentos") {
                ForEach(details.objects("transactions").filter { search.isEmpty || [$0.text("desc"), $0.text("category"), $0.text("expenseName"), $0.text("note")].joined(separator: " ").localizedStandardContains(search) }.map(NativeRecord.init)) { transaction in
                    VStack(alignment: .leading, spacing: 5) { HStack { Text(transaction.fields.text("desc")); Spacer(); Text(NativeFinanceFormat.money(transaction.fields.decimal("monthValue"))) }; Text(transaction.fields.text("expenseName") + " · " + transaction.fields.text("category")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if finance.snapshot.closures.first?.text("id") == record.text("id") { Section { Button("Reabrir este mês", role: .destructive) { reopen = true }.disabled(!finance.canWrite) } footer: { Text("O servidor verifica se este é o último fechamento e se o mês seguinte pode ser reaberto.") } }
            if let issue { Text(issue).foregroundStyle(.red) }
        }.navigationTitle(NativeFinanceFormat.month(record.text("month"))).navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "Buscar neste fechamento")
            .task { do { details = try await finance.parent.api.post(action: "closure_detail", body: ["id": record["id"] ?? .string("")]) } catch { issue = error.localizedDescription } }
            .confirmationDialog("Reabrir este mês?", isPresented: $reopen, titleVisibility: .visible) { Button("Reabrir mês", role: .destructive) { Task { do { _ = try await finance.save("reopen_month", ["id": record["id"] ?? .string("")]); dismiss() } catch { issue = error.localizedDescription } } } }
    }
}
