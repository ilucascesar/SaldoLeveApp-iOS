import SwiftUI

struct NativeIncomeEditor: View {
    @ObservedObject var finance: NativeFinanceStore
    @State private var draft: NativeIncomeDraft
    @State private var issue: String?
    @Environment(\.dismiss) private var dismiss
    init(finance: NativeFinanceStore) {
        self.finance = finance
        let month = finance.snapshot.month
        _draft = State(initialValue: NativeIncomeDraft(month: month, record: finance.snapshot.fields.objects("incomes").first { $0.text("month") == month } ?? [:]))
    }
    private var preview: JSONObject? { try? draft.payload() }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(NativeFinanceFormat.month(draft.month)).font(.headline) }
                Section("Renda principal") { TextField("Valor (R$)", text: $draft.baseAmount).keyboardType(.decimalPad) }
                Section {
                    ForEach($draft.extras) { $extra in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Nome do extra", text: $extra.name).onChange(of: extra.name) { extra.name = String($0.prefix(100)) }
                            HStack {
                                TextField("Valor (R$)", text: $extra.amount).keyboardType(.decimalPad)
                                Button(role: .destructive) { draft.extras.removeAll { $0.id == extra.id } } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Remover extra \(extra.name)")
                            }
                        }.padding(.vertical, 3)
                    }
                    Button { draft.extras.append(NativeIncomeExtra()) } label: { Label("Adicionar extra", systemImage: "plus.circle") }.disabled(draft.extras.count >= 100)
                } header: { Text("Extras") } footer: { Text("Dinheiro recebido além da renda principal, somente neste mês.") }
                Section("Prévia") {
                    if let preview {
                        LabeledContent("Total da renda", value: NativeFinanceFormat.money(preview.decimal("amount")))
                        LabeledContent("Gastos do mês", value: NativeFinanceFormat.money(finance.snapshot.active.decimal("spent")))
                        LabeledContent("Saldo", value: NativeFinanceFormat.money(preview.decimal("amount") - finance.snapshot.active.decimal("spent")))
                    } else { Text("Preencha o nome e um valor válido para cada extra.").foregroundStyle(.secondary) }
                }
                if let issue { Text(issue).foregroundStyle(.red) }
                if finance.snapshot.month != draft.month { Text("O mês em aberto mudou. Feche e reabra esta tela antes de salvar.").foregroundStyle(.orange) }
            }.buttonStyle(.borderless).disabled(!finance.canWrite)
                .navigationTitle("Renda do mês").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(finance.busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(finance.busy ? "Salvando…" : "Salvar") { Task { do { _ = try await finance.save("save_income", draft.payload()); dismiss() } catch { issue = error.localizedDescription } } }.disabled(!finance.canWrite || preview == nil || finance.snapshot.month != draft.month) }
                }
        }.interactiveDismissDisabled(finance.busy)
    }
}
