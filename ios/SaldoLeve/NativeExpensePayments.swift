import SwiftUI

struct NativeExpensePayments: View {
    @ObservedObject var finance: NativeFinanceStore
    let expenseID: String
    @State private var participant = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var issue: String?
    @State private var requestKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    @State private var reversing: NativeRecord?
    @Environment(\.dismiss) private var dismiss
    private var data: NativeFinanceSnapshot { finance.snapshot }
    private var progress: JSONObject { data.active.record("paymentProgress").record(expenseID) }
    private var owner: Bool { data.expense(expenseID).text("ownerId") == finance.parent.user?.id }
    private var people: [JSONObject] { progress.objects("participants").filter { owner || $0.text("id") == finance.parent.user?.id } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Pagamento de cada pessoa") {
                    ForEach(progress.objects("participants").map(NativeRecord.init)) { person in
                        VStack(alignment: .leading, spacing: 6) { Text(person.fields.text("name")).font(.headline); LabeledContent("Sua parte", value: NativeDate.money(person.fields["dueCents"]?.number)); LabeledContent("Pago", value: NativeDate.money(person.fields["paidCents"]?.number)); LabeledContent("Pendente", value: NativeDate.money(person.fields["pendingCents"]?.number)) }
                    }
                    Label(progress.flag("complete") ? "Todas as partes pagas" : "A despesa fica paga quando todas as partes forem quitadas", systemImage: progress.flag("complete") ? "checkmark.circle.fill" : "person.2").font(.footnote).foregroundStyle(progress.flag("complete") ? Color.green : Color.secondary)
                }
                Section("Registrar pagamento parcial") {
                    Picker("Quem pagou", selection: $participant) { ForEach(people.map(NativeRecord.init)) { Text($0.fields.text("name")).tag($0.id) } }
                    TextField("Valor pago", text: $amount).keyboardType(.decimalPad)
                    DatePicker("Data", selection: $date, displayedComponents: .date)
                    TextField("Observação", text: $note, axis: .vertical)
                    Button("Registrar pagamento") { save() }.disabled(!finance.canWrite || participant.isEmpty)
                }
                Section("Histórico de pagamentos") {
                    ForEach(progress.objects("entries").map(NativeRecord.init)) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text((progress.objects("participants").first { $0.text("id") == entry.fields.text("participantId") }?.text("name") ?? "Participante") + " · " + NativeDate.money(entry.fields["amountCents"]?.number)).font(.subheadline.weight(.semibold))
                            Text(entry.fields.text("date") + (entry.fields.text("note").isEmpty ? "" : " · " + entry.fields.text("note"))).font(.caption).foregroundStyle(.secondary)
                            if !entry.fields.text("reversedAt").isEmpty { Text("Estornado · histórico preservado").font(.caption).foregroundStyle(.orange) }
                            else if owner || entry.fields.text("participantId") == finance.parent.user?.id { Button("Estornar este pagamento", role: .destructive) { reversing = entry }.font(.caption).disabled(!finance.canWrite) }
                        }
                    }
                    if progress.objects("entries").isEmpty && data.paid(expenseID) { Text("Pagamento integral registrado na versão anterior. Ele será preservado ao registrar ou estornar valores por pessoa.").font(.footnote) }
                }
                if let issue { Section { Text(issue).foregroundStyle(.red); if finance.needsSync { Button("Sincronizar e conferir") { Task { await finance.refresh() } } } } }
            }.navigationTitle("Pagamentos por pessoa").navigationBarTitleDisplayMode(.inline).toolbar { Button("Fechar") { dismiss() }.disabled(finance.busy) }
                .onAppear { participant = finance.parent.user?.id ?? people.first?.text("id") ?? "" }
                .confirmationDialog("Estornar este pagamento?", isPresented: Binding(get: { reversing != nil }, set: { if !$0 { reversing = nil } }), titleVisibility: .visible) { Button("Estornar pagamento", role: .destructive) { if let reversing { Task { do { _ = try await finance.save("reverse_expense_payment", ["expenseId": .string(expenseID), "entryId": .string(reversing.id)]) } catch { issue = error.localizedDescription } } }; reversing = nil } }
        }
    }
    private func save() {
        Task { do {
            _ = try await finance.save("record_expense_payment", ["expenseId": .string(expenseID), "participantId": .string(participant), "amount": .number(try NativeFinanceFormat.amount(amount)), "date": .string(NativeFinanceFormat.day(date)), "note": .string(note), "requestKey": .string(requestKey)])
            amount = ""; note = ""; requestKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(); issue = nil
        } catch { issue = error.localizedDescription } }
    }
}
