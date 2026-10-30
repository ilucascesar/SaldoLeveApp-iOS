import SwiftUI

@MainActor struct NativeCheckValues: View {
    @ObservedObject var store: NativeStore
    let taskID: String
    let checkID: String
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var details: JSONObject = [:]
    @State private var original = ""
    @State private var paid = ""
    @State private var variable = false
    @State private var loading = true
    @State private var working = false
    @State private var issue: String?
    private var valid: Bool { guard let a = NativeDate.cents(original), let b = NativeDate.cents(paid) else { return false }; return b >= 0 && a >= b }
    var body: some View {
        NavigationStack {
            Form {
                Section("Valores da subtarefa") {
                    TextField("Valor original (R$)", text: $original).keyboardType(.decimalPad).accessibilityIdentifier("check-original-amount")
                    TextField("Valor pago (R$)", text: $paid).keyboardType(.decimalPad).accessibilityIdentifier("check-paid-amount")
                    if let a = NativeDate.cents(original), let b = NativeDate.cents(paid) { LabeledContent("Desconto", value: NativeDate.money(Double(max(0, a - b)))) }
                    Toggle("Definir novo valor a cada mês", isOn: $variable)
                }.disabled(loading || working || !store.canWrite || details.record("payment").isEmpty)
                Section { Text("Ajusta o pagamento deste ciclo no histórico e os valores da subtarefa. A data do pagamento e os ciclos anteriores são preservados.").font(.footnote).foregroundStyle(.secondary) }
                if loading { ProgressView("Consultando servidor…") }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Valores").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.disabled(working) }
                    ToolbarItem(placement: .confirmationAction) { Button("Salvar") { Task { await save() } }.disabled(!valid || loading || working || !store.canWrite || details.record("payment").isEmpty) }
                }.task { await load() }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            details = try await store.api.get(JSONObject.self, action: "org_check_values", query: ["id": taskID, "checkId": checkID])
            let check = details.record("check")
            original = NativeFinanceFormat.input((check["amountCents"]?.number ?? details.record("payment")["nominalAmountCents"]?.number ?? 0) / 100); paid = NativeFinanceFormat.input((check["paidAmountCents"]?.number ?? details.record("payment")["amountCents"]?.number ?? check["amountCents"]?.number ?? 0) / 100)
            variable = check.flag("variableAmount")
            issue = details.record("payment").isEmpty ? "Este ciclo não tem um pagamento ajustável. Confira os registros no Histórico da tarefa." : nil
        } catch { store.noteConnectionFailure(error); issue = error.localizedDescription }
    }
    private func save() async {
        guard valid, store.canWrite else { return }; working = true; defer { working = false }
        do {
            let payment = details.record("payment"), item = details.record("item")
            _ = try await store.api.post(action: "org_adjust_check_values", body: ["id": .string(taskID), "checkId": .string(checkID), "revision": item["revision"] ?? .number(0), "paymentId": payment["id"] ?? .null, "paymentRevision": payment["revision"] ?? .number(0), "originalAmountCents": .number(Double(NativeDate.cents(original)!)), "paidAmountCents": .number(Double(NativeDate.cents(paid)!)), "variableAmount": .bool(variable)])
            await store.refresh(); changed(); dismiss()
        } catch { store.noteConnectionFailure(error); issue = error.localizedDescription; if (error as? NativeFailure)?.status == 409 { await load(); issue = "Valores atuais do servidor recarregados. Confira antes de salvar." } }
    }
}
