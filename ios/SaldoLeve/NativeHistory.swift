import SwiftUI

struct NativeHistoryView: View {
    @ObservedObject var store: NativeStore
    let taskID: String
    @Environment(\.dismiss) private var dismiss
    @State private var records: [NativeRecord] = []
    @State private var taskRevision = 0
    @State private var offset = 0
    @State private var more = false
    @State private var editable = false
    @State private var loading = false
    @State private var error: String?
    @State private var undo: NativeRecord?
    @State private var shared: NativeSharedFile?
    @State private var editing: NativeRecord?
    @State private var deleting: NativeRecord?
    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty && !loading { Text("Nenhum pagamento ou conclusão registrado.").foregroundStyle(.secondary) }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.fields.text("title")).font(.headline)
                        if let paid = NativeDate.parse(record.fields.text("paidAt")) { Text(paid.formatted(date: .abbreviated, time: .shortened)).font(.subheadline) }
                        if record.fields["amountCents"]?.number != nil { Text(NativeDate.money(record.fields["amountCents"]?.number)).font(.subheadline.bold()) }
                        if !record.fields.text("actor").isEmpty { Text(record.fields.text("actor")).font(.caption).foregroundStyle(.secondary) }
                        if !record.fields.text("notes").isEmpty { Text(record.fields.text("notes")).font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(record.fields.objects("files").map(NativeRecord.init)) { file in
                            Button { Task {
                                do { shared = NativeSharedFile(url: try await store.api.download(id: file.id, name: file.fields.text("name"))) }
                                catch { self.error = error.localizedDescription }
                            } } label: { Label(file.fields.text("name"), systemImage: "paperclip") }
                        }
                        if editable && store.canWrite {
                            HStack {
                                Button("Editar registro") { editing = record }
                                Spacer()
                                Button("Excluir registro", role: .destructive) { deleting = record }
                            }.font(.caption)
                            Button("Desfazer pagamento / conclusão") { undo = record }.font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(.vertical, 8)
                }
                if loading { ProgressView() }
                else if more { Button("Carregar mais") { Task { await load(reset: false) } } }
            }.navigationTitle("Histórico").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Fechar") { dismiss() } }
                .task { await load(reset: true) }
                .sheet(item: $shared) { NativeShareSheet(items: [$0.url]) }
                .sheet(item: $editing, onDismiss: { Task { await load(reset: true) } }) { NativePaymentEditor(store: store, record: $0) }
                .confirmationDialog("Excluir este registro do histórico?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("Excluir registro", role: .destructive) {
                        if let entry = deleting { Task { do { _ = try await store.mutate("org_history_delete", ["id": .string(entry.id), "revision": .number(Double(entry.fields.integer("revision")))]); await load(reset: true) } catch { self.error = error.localizedDescription } } }; deleting = nil
                    }
                } message: { Text("A tarefa permanece como está. Para reabrir uma pendência, use Desfazer.") }
                .alert("Histórico", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
                .confirmationDialog("Desfazer este pagamento ou conclusão?", isPresented: Binding(get: { undo != nil }, set: { if !$0 { undo = nil } }), titleVisibility: .visible) {
                    Button("Desfazer", role: .destructive) {
                        if let entry = undo { Task {
                            do {
                                _ = try await store.mutate("org_history_undo", ["id": .string(entry.id), "revision": .number(Double(entry.fields.integer("revision"))), "taskRevision": .number(Double(taskRevision))])
                                await load(reset: true)
                            } catch { self.error = error.localizedDescription }
                        } }
                        undo = nil
                    }
                } message: { Text("O servidor verificará os ciclos e as alterações posteriores antes de reabrir a pendência.") }
        }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }
        if store.offline { error = "Conecte e sincronize para consultar o histórico."; return }
        loading = true; defer { loading = false }
        do {
            let data = try await store.api.get(JSONObject.self, action: "org_history", query: ["id": taskID, "offset": String(reset ? 0 : offset)])
            if reset { records = [] }
            records += data.objects("entries").map(NativeRecord.init)
            more = data.flag("hasMore"); offset = data.integer("nextOffset")
            taskRevision = data.integer("taskRevision"); editable = data.flag("canEdit")
        } catch { self.error = error.localizedDescription }
    }
}

struct NativeGlobalHistoryView: View {
    @ObservedObject var store: NativeStore
    var categoryID = ""
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var month = Date()
    @State private var monthOnly = false
    @State private var entries: [NativeRecord] = []
    @State private var more = false
    @State private var offset = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var opened: NativeRecord?
    private var requestKey: String { search + "|" + (monthOnly ? NativeMonth.key(month) : "") + "|" + categoryID }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Filtrar por mês", isOn: $monthOnly)
                    if monthOnly { DatePicker("Mês", selection: $month, displayedComponents: .date).datePickerStyle(.compact) }
                }
                ForEach(entries) { entry in
                    Button { opened = entry } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.fields.text("title")).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                            Text(entry.fields.text("taskTitle") + " · " + entry.fields.text("category")).font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack { if let date = NativeDate.parse(entry.fields.text("paidAt")) { Text(date.formatted(date: .abbreviated, time: .omitted)) }; Spacer(); Text(NativeDate.money(entry.fields["amountCents"]?.number)).fontWeight(.medium) }.font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
                if loading { ProgressView() }
                if more && !loading { Button("Carregar mais") { Task { await load(reset: false, key: requestKey) } } }
                if entries.isEmpty && !loading { Text("Nenhum registro encontrado.").foregroundStyle(.secondary) }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
            }.navigationTitle("Histórico de pagamentos").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Pessoa, tarefa, categoria ou valor")
                .toolbar { Button("Fechar") { dismiss() } }
                .task(id: requestKey) { try? await Task.sleep(nanoseconds: 300_000_000); if !Task.isCancelled { await load(reset: true, key: requestKey) } }
                .sheet(item: $opened) { NativeHistoryView(store: store, taskID: $0.fields.text("itemId")) }
        }
    }
    private func load(reset: Bool, key: String) async {
        guard !store.offline, !store.isPreview else { return }
        loading = true; failure = nil
        do {
            let data = try await store.api.get(JSONObject.self, action: "org_global_history", query: ["q": String(search.prefix(150)), "month": monthOnly ? NativeMonth.key(month) : "", "listId": categoryID, "offset": String(reset ? 0 : offset)])
            guard !Task.isCancelled, key == requestKey else { return }
            entries = (reset ? [] : entries) + data.objects("entries").map(NativeRecord.init)
            more = data.flag("hasMore"); offset = data.integer("nextOffset"); loading = false
        } catch { if !Task.isCancelled && key == requestKey { failure = error.localizedDescription; loading = false } }
    }
}
struct NativePaymentEditor: View {
    @ObservedObject var store: NativeStore
    let record: NativeRecord
    @Environment(\.dismiss) private var dismiss
    @State private var fields: JSONObject = [:]
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Descrição", text: text("title"))
                NativeMoneyField(fields: $fields)
                NativeDateField(fields: $fields, key: "paidAt", title: "Pagamento em")
                NativeDateField(fields: $fields, key: "dueAt", title: "Competência / vencimento")
                TextField("Observações", text: text("notes"), axis: .vertical)
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
            }.navigationTitle("Editar registro").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(store.working) }
                    ToolbarItem(placement: .confirmationAction) { Button("Salvar") { Task { do { _ = try await store.mutate("org_history_edit", fields); dismiss() } catch { failure = error.localizedDescription } } }.disabled(!store.canWrite || fields.text("title").isEmpty || fields.flag("_nativeInvalidAmount")) }
                }.onAppear { fields = record.fields }
        }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { fields.text(key) }, set: { fields[key] = .string($0) }) }
}

struct NativeTrashCollection: View {
    @ObservedObject var store: NativeStore
    @State private var entries: [JSONObject] = []
    @State private var offset = 0
    @State private var more = false
    @State private var loading = false
    @State private var removing: JSONObject?
    var body: some View {
        List {
            if entries.isEmpty && !loading { Text("A lixeira está vazia. Tarefas e subtarefas removidas aparecem aqui.").foregroundStyle(.secondary).padding(.vertical, 26) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 7) {
                    Label(entry.text("title"), systemImage: entry.text("type") == "check" ? "checklist" : "doc.text").font(.system(size: 16, weight: .medium))
                    Text(entry.text("category") + (entry.text("type") == "check" ? " · " + entry.text("taskTitle") : "")).font(.caption).foregroundStyle(.secondary)
                    if entry.flag("parentTrashed") && entry.text("type") == "check" { Text("Restaure primeiro a tarefa principal.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Restaurar") { restore(entry) }.disabled(!store.canWrite || !entry.flag("canEdit") || entry.text("type") == "check" && entry.flag("parentTrashed"))
                        Spacer()
                        if entry.flag("canDelete") && entry.text("type") == "task" { Button("Excluir definitivamente", role: .destructive) { removing = entry }.disabled(!store.canWrite) }
                    }.font(.caption)
                }.padding(.vertical, 7).buttonStyle(.borderless)
            }
            if loading { ProgressView() } else if more { Button("Carregar mais") { Task { await load(reset: false) } } }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(nativeCanvas)
            .task { await load(reset: true) }.refreshable { await load(reset: true) }
            .confirmationDialog("Excluir tarefa e anexos definitivamente?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Excluir definitivamente", role: .destructive) {
                    if let entry = removing { Task { do { _ = try await store.mutate("org_delete_item", ["id": .string(entry.text("itemId")), "revision": entry["revision"] ?? .number(0)]); await load(reset: true) } catch { store.report(error) } } }; removing = nil
                }
            } message: { Text("Esta exclusão não pode ser desfeita.") }
    }
    private func restore(_ entry: JSONObject) {
        Task { do { _ = try await store.mutate(entry.text("type") == "task" ? "org_restore_item" : "org_restore_check", ["id": .string(entry.text("id")), "itemId": .string(entry.text("itemId")), "revision": entry["revision"] ?? .number(0)]); await load(reset: true) } catch { store.report(error) } }
    }
    private func load(reset: Bool) async {
        guard !loading, !store.offline, !store.isPreview else { return }; loading = true; defer { loading = false }
        do { let data = try await store.api.get(JSONObject.self, action: "org_trash", query: ["offset": String(reset ? 0 : offset)]); entries = (reset ? [] : entries) + data.objects("entries"); offset = data.integer("nextOffset"); more = data.flag("hasMore") } catch { store.report(error) }
    }
}
