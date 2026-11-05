import SwiftUI

struct NativeStandaloneReminders: View {
    @ObservedObject var store: NativeStore
    @State private var records: [NativeRecord] = []
    @State private var editing: NativeRecord?
    @State private var cancelling: NativeRecord?
    @State private var loading = false
    @State private var issue: String?
    var body: some View {
        List {
            Section {
                Button { editing = NativeRecord(fields: [:]) } label: { Label("Novo lembrete avulso", systemImage: "plus.circle") }.disabled(!store.canWrite)
                Text("Título, mensagem e repetição, sem criar uma tarefa. Os mesmos lembretes aparecem na web. Para avisar neste iPhone, ative as notificações.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.fields.text("title")).font(.headline)
                    if !record.fields.text("body").isEmpty { Text(record.fields.text("body")).font(.subheadline) }
                    if let date = NativeDate.parse(record.fields.text("scheduledAt")) { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text(["once":"Uma vez", "daily":"Diário", "weekly":"Semanal", "monthly":"Mensal", "yearly":"Anual"][record.fields.text("recurrence")] ?? "Uma vez").font(.caption)
                    if record.fields.text("status") == "active" {
                        HStack { Button("Editar") { editing = record }; Spacer(); Button("Cancelar lembrete", role: .destructive) { cancelling = record } }.font(.caption).disabled(!store.canWrite)
                    } else { Text("Encerrado / enviado pelo servidor").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 5)
            }
            if loading { ProgressView() }
            if !loading && records.isEmpty { Text("Nenhum lembrete avulso.").foregroundStyle(.secondary) }
            if let issue { Text(issue).foregroundStyle(.red) }
        }.buttonStyle(.borderless).navigationTitle("Lembretes avulsos").navigationBarTitleDisplayMode(.inline)
            .task { await load() }.refreshable { await load() }
            .sheet(item: $editing, onDismiss: { Task { await load() } }) { NativeStandaloneReminderEditor(store: store, original: $0.fields) }
            .confirmationDialog("Cancelar este lembrete?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible) { Button("Cancelar lembrete", role: .destructive) { if let record = cancelling { Task { do { _ = try await store.mutate("push_cancel_reminder", ["id": .string(record.id)]); await load() } catch { issue = error.localizedDescription } } }; cancelling = nil } }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { let response = try await store.api.get(JSONObject.self, action: "native_general_reminders"); records = response.objects("items").map(NativeRecord.init); issue = nil }
        catch { issue = error.localizedDescription }
    }
}

struct NativeStandaloneReminderEditor: View {
    @ObservedObject var store: NativeStore
    let original: JSONObject
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message = ""
    @State private var fields: JSONObject = [:]
    @State private var repeatKind = "once"
    @State private var working = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Título", text: $title).onChange(of: title) { title = String($0.prefix(100)) }
                TextField("Mensagem (opcional)", text: $message, axis: .vertical).onChange(of: message) { message = String($0.prefix(300)) }
                NativeDateField(fields: $fields, key: "dueAt", title: "Data e horário")
                Picker("Repetir", selection: $repeatKind) { Text("Uma vez").tag("once"); Text("Todo dia").tag("daily"); Text("Toda semana").tag("weekly"); Text("Todo mês").tag("monthly"); Text("Todo ano").tag("yearly") }
                if let issue { Text(issue).foregroundStyle(.red) }
            }.disabled(working).navigationTitle(original.text("id").isEmpty ? "Novo lembrete" : "Editar lembrete").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(working) }; ToolbarItem(placement: .confirmationAction) { Button(working ? "Salvando…" : "Salvar") { Task { await save() } }.disabled(!store.canWrite || working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
                .onAppear { title = original.text("title"); message = original.text("body"); fields["dueAt"] = .string(original.text("scheduledAt").isEmpty ? NativeDate.iso(NativeDate.quarter(Date().addingTimeInterval(3600))) : original.text("scheduledAt")); repeatKind = original.text("recurrence").isEmpty ? "once" : original.text("recurrence") }
        }
    }
    private func save() async {
        guard !working else { return }; working = true; defer { working = false }
        do {
            guard let date = NativeDate.parse(fields.text("dueAt")), date > Date() else { throw NativeFailure("Escolha uma data e horário futuros.") }
            var payload: JSONObject = ["title": .string(title), "body": .string(message), "scheduledAt": .string(NativeDate.iso(date)), "timezone": .string(original.text("timezone").isEmpty ? TimeZone.current.identifier : original.text("timezone")), "recurrence": .string(repeatKind)]
            let action = original.text("id").isEmpty ? "push_create_reminder" : "push_update_reminder"
            if !original.text("id").isEmpty { payload["id"] = original["id"] }
            _ = try await store.mutate(action, payload); dismiss()
        } catch { issue = error.localizedDescription }
    }
}
