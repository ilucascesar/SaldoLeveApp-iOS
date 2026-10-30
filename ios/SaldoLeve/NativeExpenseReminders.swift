import SwiftUI

enum NativeExpenseReminderPlan {
    static func build(_ records: [JSONObject], now: Date, preferences: NativeNotificationPreferences) -> [PlannedReminder] {
        guard preferences.expenses else { return [] }
        var planned: [PlannedReminder] = []
        for record in records {
            guard var candidate = NativeDate.parse(record.text("scheduledAt")) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: record.text("timezone")) ?? TimeZone(identifier: "America/Sao_Paulo")!
            let originalDay = calendar.component(.day, from: candidate)
            let originalMonth = calendar.component(.month, from: candidate)
            var seen = Set<Date>()
            for index in 0..<8 {
                let fire = preferences.deliveryDate(candidate)
                if fire > now && seen.insert(fire).inserted { planned.append(.init(id: "sl-task-expense-\(record.text("id"))-\(index)", taskID: "expense:" + record.text("expenseId"), title: record.text("title"), body: record.text("body"), date: fire)) }
                let recurrence = record.text("recurrence")
                guard recurrence != "once" else { break }
                let component: Calendar.Component = recurrence == "daily" ? .day : recurrence == "weekly" ? .weekOfYear : recurrence == "yearly" ? .year : .month
                guard var next = calendar.date(byAdding: component, value: 1, to: candidate) else { break }
                if recurrence == "monthly" || recurrence == "yearly" {
                    if recurrence == "yearly" { next = calendar.date(bySetting: .month, value: originalMonth, of: next) ?? next }
                    let lastDay = calendar.range(of: .day, in: .month, for: next)?.count ?? originalDay
                    next = calendar.date(bySetting: .day, value: min(originalDay, lastDay), of: next) ?? next
                }
                candidate = next
            }
        }
        return planned
    }
}

struct NativeExpenseReminders: View {
    @ObservedObject var finance: NativeFinanceStore
    let expenseID: String
    @State private var records: [JSONObject] = []
    @State private var editing: NativeRecord?
    @State private var issue: String?
    @State private var cancelling: NativeRecord?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Os lembretes são compartilhados com o site. Neste iPhone, habilite Despesas em Configurações → Notificações e sincronize para programar os avisos locais.").font(.footnote).foregroundStyle(.secondary) }
                ForEach(records.map(NativeRecord.init)) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.fields.text("title")).font(.headline)
                        if let date = NativeDate.parse(record.fields.text("scheduledAt")) { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary) }
                        Text(record.fields.text("status") == "active" ? "Ativo · " + record.fields.text("recurrence") : "Concluído").font(.caption).foregroundStyle(.secondary)
                        if record.fields.text("status") == "active" { HStack { Button("Editar") { editing = record }; Spacer(); Button("Cancelar lembrete", role: .destructive) { cancelling = record } }.buttonStyle(.borderless).disabled(!finance.canWrite) }
                    }.padding(.vertical, 5)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
                if records.isEmpty && issue == nil { Text("Nenhum lembrete nesta despesa.").foregroundStyle(.secondary) }
            }.navigationTitle("Lembretes da despesa").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button { editing = NativeRecord(fields: [:]) } label: { Image(systemName: "plus") }.disabled(!finance.canWrite) } }
                .task { await reload() }.refreshable { await reload() }
                .sheet(item: $editing, onDismiss: { Task { await reload(); await finance.parent.refreshExpenseReminders() } }) { NativeExpenseReminderEditor(finance: finance, expenseID: expenseID, original: $0.fields) }
                .confirmationDialog("Cancelar este lembrete?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible) { Button("Cancelar lembrete", role: .destructive) { if let cancelling { Task { do { _ = try await finance.save("push_cancel_reminder", ["id": .string(cancelling.id)]); await reload(); await finance.parent.refreshExpenseReminders() } catch { issue = error.localizedDescription } } }; cancelling = nil } }
        }
    }
    private func reload() async { do { records = try await finance.parent.api.get([JSONObject].self, action: "expense_reminders", query: ["expenseId": expenseID]); issue = nil } catch { issue = error.localizedDescription } }
}
struct NativeExpenseReminderEditor: View {
    @ObservedObject var finance: NativeFinanceStore
    let expenseID: String
    let original: JSONObject
    @State private var title = ""
    @State private var message = ""
    @State private var date = NativeDate.quarter(Date().addingTimeInterval(3600))
    @State private var recurrence = "monthly"
    @State private var purpose = "pay"
    @State private var onlyPending = true
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Título", text: $title).onChange(of: title) { title = String($0.prefix(100)) }
                TextField("Mensagem", text: $message, axis: .vertical).onChange(of: message) { message = String($0.prefix(300)) }
                DatePicker("Próximo aviso", selection: $date, in: Date()...)
                Text("Escolha minutos 00, 15, 30 ou 45, seguindo os lembretes do site.").font(.footnote).foregroundStyle(.secondary)
                Picker("Finalidade", selection: $purpose) { Text("Pagar despesa").tag("pay"); Text("Informar fatura").tag("invoice"); Text("Registrar gastos").tag("entry") }
                Picker("Repetir", selection: $recurrence) { Text("Uma vez").tag("once"); Text("Diariamente").tag("daily"); Text("Semanalmente").tag("weekly"); Text("Mensalmente").tag("monthly"); Text("Anualmente").tag("yearly") }
                if purpose == "pay" { Toggle("Avisar somente se houver pendência", isOn: $onlyPending) }
                if let issue { Text(issue).foregroundStyle(.red) }
            }.navigationTitle(original.text("id").isEmpty ? "Novo lembrete" : "Editar lembrete").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(finance.busy) }; ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.disabled(!finance.canWrite || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
                .onAppear { title = original.text("title").isEmpty ? "Lembrete · " + finance.snapshot.expense(expenseID).text("name") : original.text("title"); message = original.text("body"); date = NativeDate.parse(original.text("scheduledAt")) ?? date; recurrence = original.text("recurrence").isEmpty ? "monthly" : original.text("recurrence"); purpose = original.text("purpose").isEmpty ? "pay" : original.text("purpose"); onlyPending = original["onlyIfPending"] != .bool(false) }
        }
    }
    private func save() {
        Task { do {
            guard Calendar.current.component(.minute, from: date) % 15 == 0 else { throw NativeFailure("Use minutos 00, 15, 30 ou 45.") }
            let rounded = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
            var body: JSONObject = ["expenseId": .string(expenseID), "title": .string(title), "body": .string(message), "scheduledAt": .string(NativeDate.iso(rounded)), "timezone": .string(TimeZone.current.identifier), "recurrence": .string(recurrence), "purpose": .string(purpose), "onlyIfPending": .bool(onlyPending)]
            if !original.text("id").isEmpty { body["id"] = original["id"] }
            _ = try await finance.save(original.text("id").isEmpty ? "push_create_reminder" : "push_update_reminder", body); dismiss()
        } catch { issue = error.localizedDescription } }
    }
}
