import SwiftUI

@MainActor struct NativeUnifiedSearch: View {
    @ObservedObject var store: NativeStore
    @ObservedObject var platform: NativePlatformStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var type = "all"
    @State private var status = "all"
    @State private var person = ""
    @State private var from = ""
    @State private var to = ""
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var filters = false
    @State private var items: [JSONObject] = []
    @State private var users: [JSONObject] = []
    @State private var total = 0
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var issue: String?
    @State private var task: NativeTask?
    @State private var route: NativeFinanceRoute?
    @State private var birthday: NativeBirthday?
    @State private var receipt: NativeSharedFile?
    @State private var detail: NativeRecord?
    private let types = ["all":"Tudo", "tasks":"Tarefas", "installments":"Parcelas e subtarefas", "expenses":"Despesas", "transactions":"Lançamentos", "payments":"Pagamentos", "attachments":"Comprovantes e anexos", "birthdays":"Aniversariantes"]
    private var signature: String { [query, type, status, person, from, to, minimum, maximum, String(store.offline)].joined(separator: "|") }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(platform.text("searchPlaceholder", fallback: "Buscar no SaldoLeve"), text: $query).submitLabel(.search).accessibilityIdentifier("global-search-input")
                    Picker("Tipo de registro", selection: $type) { ForEach(["all", "tasks", "installments", "expenses", "transactions", "payments", "attachments", "birthdays"], id: \.self) { Text(types[$0] ?? $0).tag($0) } }
                    Button { filters = true } label: { Label("Período, pessoa, valor e situação", systemImage: "line.3.horizontal.decrease.circle") }
                    Text("Os resultados vêm do servidor. O filtro de período considera a data indicada em cada resultado; despesas mostram o mês em aberto.").font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView("Buscando no servidor…") }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                Section("\(total) resultado(s)") {
                    ForEach(items.map(NativeRecord.init)) { record in
                        Button { Task { await open(record.fields) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .top) { Text(record.fields.text("title")).font(.headline).foregroundStyle(.primary); Spacer(); if let cents = record.fields["amountCents"]?.number { Text(NativeDate.money(cents)).font(.subheadline.bold()).foregroundStyle(.primary) } }
                                Text(record.fields.text("subtitle")).font(.caption).foregroundStyle(.secondary)
                                Text((types[record.fields.text("type")] ?? "Registro") + " · " + String(record.fields.text("date").prefix(10)) + " · " + statusLabel(record.fields.text("status"))).font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                    if nextOffset != nil { Button("Carregar mais resultados") { Task { await fetch(reset: false) } }.disabled(loading) }
                }
            }.navigationTitle(platform.label("search")).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Fechar") { dismiss() } }
                .task(id: signature) { try? await Task.sleep(nanoseconds: 350_000_000); guard !Task.isCancelled else { return }; await fetch(reset: true) }
                .sheet(isPresented: $filters) { filterForm }
                .sheet(item: $task) { NativeTaskEditor(store: store, original: $0) }
                .sheet(item: $route) { NativeFinanceModal(finance: store.finance, route: $0) }
                .sheet(item: $birthday) { NativeBirthdayEditor(platform: platform, original: $0) }
                .sheet(item: $receipt) { NativeShareSheet(items: [$0.url]) }
                .sheet(item: $detail) { value in NavigationStack { List { LabeledContent("Registro", value: value.fields.text("title")); Text(value.fields.text("subtitle")); if let cents = value.fields["amountCents"]?.number { LabeledContent("Valor confirmado", value: NativeDate.money(cents)) }; LabeledContent("Data", value: String(value.fields.text("date").prefix(10))); Text("Este é o registro encontrado no servidor. Abra a despesa para acompanhar seus pagamentos e períodos.").font(.footnote).foregroundStyle(.secondary); Button("Abrir despesa relacionada") { let target = value.fields.record("target"); detail = nil; Task { try? await Task.sleep(nanoseconds: 350_000_000); await store.finance.refresh(); route = .init(kind: "detail", fields: ["id": .string(target.text("id"))]) } } }.navigationTitle("Pagamento").toolbar { Button("Fechar") { detail = nil } } } }
        }
    }
    private var filterForm: some View {
        NavigationStack {
            Form {
                Section("Período") { TextField("De: AAAA-MM-DD", text: $from).keyboardType(.numbersAndPunctuation); TextField("Até: AAAA-MM-DD", text: $to).keyboardType(.numbersAndPunctuation) }
                Section("Pessoa participante") { Picker("Pessoa", selection: $person) { Text("Todas").tag(""); ForEach(users.map(NativeRecord.init)) { Text($0.fields.text("name")).tag($0.id) } } }
                Section("Valores em R$") { TextField("Mínimo", text: $minimum).keyboardType(.decimalPad); TextField("Máximo", text: $maximum).keyboardType(.decimalPad) }
                Section("Situação") { Picker("Situação", selection: $status) { Text("Todas").tag("all"); Text("Pendente").tag("open"); Text("Pago / recebido").tag("paid"); Text("Parcial").tag("partial"); Text("Concluído").tag("done"); Text("Atrasado").tag("overdue"); Text("Arquivado").tag("archived"); Text("Lixeira").tag("trashed"); Text("Inativo").tag("inactive") } }
                Button("Limpar filtros") { from = ""; to = ""; person = ""; minimum = ""; maximum = ""; status = "all"; type = "all" }
            }.navigationTitle("Filtros da busca").navigationBarTitleDisplayMode(.inline).toolbar { Button("Pronto") { filters = false } }
        }
    }
    private func fetch(reset: Bool) async {
        #if DEBUG
        if store.isPreview {
            items = store.snapshot.items.filter { query.isEmpty || $0.title.localizedStandardContains(query) }.map { task in
                ["id": .string("task:" + task.id), "type": .string("tasks"), "title": .string(task.title), "subtitle": .string("Categoria de teste"), "date": .string(task.fields.text("dueAt")), "status": .string("open"), "target": .object(["kind": .string("task"), "id": .string(task.id)])] as JSONObject
            }; total = items.count; nextOffset = nil; users = []; issue = nil; return
        }
        #endif
        guard store.networkAvailable && !store.offline else { issue = "Sem conexão. Conecte-se para buscar os dados atuais do servidor."; return }
        guard minimum.isEmpty || NativeDate.cents(minimum) != nil, maximum.isEmpty || NativeDate.cents(maximum) != nil else { issue = "Confira os valores do filtro."; return }
        var parameters = ["q":query, "type":type, "status":status, "personId":person, "from":from, "to":to, "offset":String(reset ? 0 : nextOffset ?? 0), "limit":"50"]
        if let cents = NativeDate.cents(minimum) { parameters["minCents"] = String(cents) }; if let cents = NativeDate.cents(maximum) { parameters["maxCents"] = String(cents) }
        loading = true; defer { loading = false }
        do {
            let response = try await store.api.get(NativeSearchPage.self, action: "platform_search", query: parameters)
            guard !Task.isCancelled else { return }; items = reset ? response.items : items + response.items; total = response.total; nextOffset = response.nextOffset; users = response.users; issue = nil
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
    private func open(_ row: JSONObject) async {
        let target = row.record("target")
        do {
            switch target.text("kind") {
            case "task": let response = try await store.taskDetails(target.text("id")); task = NativeTask(response.record("item"))
            case "taskHistory": route = .init(kind: "taskHistory", fields: ["id": .string(target.text("id"))])
            case "expense": await store.finance.refresh(); route = .init(kind: "detail", fields: ["id": .string(target.text("id"))])
            case "transaction": await store.finance.refresh(); if let item = store.finance.snapshot.transactions.first(where: { $0.text("id") == target.text("id") }) { route = .init(kind: "transactionDetail", fields: item) }
            case "expensePayments": detail = NativeRecord(fields: row)
            case "attachment": receipt = NativeSharedFile(url: try await store.api.download(id: target.text("id"), name: target.text("name")))
            case "birthday": await platform.refresh(); birthday = platform.snapshot.birthdays.first { $0.id == target.text("id") }
            default: break
            }
        } catch { issue = error.localizedDescription }
    }
    private func statusLabel(_ value: String) -> String { ["open":"pendente", "todo":"a fazer", "paid":"pago", "done":"concluído", "partial":"parcial", "archived":"arquivado", "trashed":"lixeira", "inactive":"inativo"][value] ?? value }
}
