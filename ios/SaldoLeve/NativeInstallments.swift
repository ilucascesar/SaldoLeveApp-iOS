import SwiftUI

struct NativeTaskMoneyTotals {
    let nominal: Double, paid: Double, discount: Double, remaining: Double
    let paidCount: Int, unknown: Int
    init(_ task: NativeTask) {
        let checks = task.checks
        var nominalTotal: Double = 0, paidTotal: Double = 0, discountTotal: Double = 0, pendingTotal: Double = 0
        for check in checks {
            let value: Double = check.fields["amountCents"]?.number ?? 0
            let actual: Double = check.fields["paidAmountCents"]?.number ?? value
            nominalTotal += value
            if check.done { paidTotal += actual; discountTotal += max(0, value - actual) }
            else { pendingTotal += value }
        }
        nominal = nominalTotal; paid = paidTotal; discount = discountTotal; remaining = pendingTotal
        paidCount = checks.filter(\.done).count
        unknown = checks.filter { $0.fields["amountCents"]?.number == nil }.count
    }
}
struct NativeTaskMoneySummary: View {
    let task: NativeTask
    var body: some View {
        let totals = NativeTaskMoneyTotals(task)
        Section("Valores desta tarefa") {
            LabeledContent("Total nominal", value: NativeDate.money(totals.nominal))
            LabeledContent("Pago efetivamente", value: NativeDate.money(totals.paid))
            LabeledContent("Descontos registrados", value: NativeDate.money(totals.discount))
            LabeledContent("Saldo nominal restante", value: NativeDate.money(totals.remaining))
            LabeledContent("Parcelas pagas", value: "\(totals.paidCount) de \(task.checks.count)")
            if totals.unknown > 0 { Text("\(totals.unknown) parcelas ainda sem valor; os totais são parciais.").font(.footnote).foregroundStyle(.orange) }
            Text("O saldo nominal não é uma cotação de quitação. Registre a oferta do banco ao antecipar. Este resumo considera os valores presentes nesta tarefa; o histórico mantém os pagamentos de ciclos anteriores.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
struct NativeInstallmentGenerator: View {
    @Binding var task: NativeTask
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Parcela"
    @State private var total = 60
    @State private var first = 1
    @State private var amount = ""
    @State private var amountMode = "parcel"
    @State private var due = NativeDate.quarter(Date().addingTimeInterval(86400))
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Parcelas com fim definido") {
                    TextField("Nome das parcelas", text: $name)
                    Stepper("Total do contrato: \(total)", value: $total, in: 2...100).onChange(of: total) { first = min(first, $0) }
                    Stepper("Primeira a gerar: \(first)", value: $first, in: 1...total)
                    DatePicker("Vencimento da primeira", selection: $due)
                    Picker("Valor informado", selection: $amountMode) { Text("Por parcela").tag("parcel"); Text("Total do contrato").tag("total") }
                    TextField("Valor (R$)", text: $amount).keyboardType(.decimalPad)
                }
                Section {
                    Text("Serão criadas \(total - first + 1) subtarefas, de \(first)/\(total) até \(total)/\(total), com vencimento mensal. Você poderá pagar qualquer uma, inclusive a última, sem alterar as demais.")
                    Text("A tarefa ficará sem repetição automática. Os centavos do valor total serão ajustados na última parcela. Para datas no fim do mês, o gerador usa o último dia dos meses mais curtos.").font(.footnote).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }.navigationTitle("Gerar parcelas").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Gerar") { generate() }.disabled(task.checks.count + total - first + 1 > 100) } }
        }
    }
    private func generate() {
        do {
            guard let value = NativeDate.cents(amount), value > 0 else { throw NativeFailure("Informe o valor total ou por parcela.") }
            let parcel = amountMode == "parcel" ? value : value / total
            let last = amountMode == "parcel" ? value : value - parcel * (total - 1)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: task.fields.text("timezone")) ?? .current
            let anchor = calendar.component(.day, from: due)
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: due))!
            var checks = task.checks.map { JSONValue.object($0.fields) }
            for number in first...total {
                let month = calendar.date(byAdding: .month, value: number - first, to: start)!
                let lastDay = calendar.range(of: .day, in: .month, for: month)!.count
                let day = calendar.date(bySetting: .day, value: min(anchor, lastDay), of: month)!
                let date = calendar.date(bySettingHour: calendar.component(.hour, from: due), minute: calendar.component(.minute, from: due), second: 0, of: day)!
                checks.append(.object(["id": .string(UUID().uuidString), "text": .string("\(name) \(number)/\(total)"), "done": .bool(false), "repeatMonthly": .bool(false), "remindAt": .string(NativeDate.iso(date)), "amountCents": .number(Double(number == total ? last : parcel)), "installmentNumber": .number(Double(number))]))
            }
            task.fields["checklist"] = .array(checks); task.fields["repeat"] = .object(["frequency": .string("none"), "interval": .number(1)])
            if !task.isMoney { task.fields["moneyMode"] = .string("pay") }
            if task.title.isEmpty { task.fields["title"] = .string(name + " (\(total)x)") }
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
struct NativeInstallmentPayment: View {
    @Binding var task: NativeTask
    var initialCheckID: String? = nil
    let commit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NativeInstallmentDraft()
    @State private var initialized = false
    @State private var issue: String?
    @State private var confirming = false
    private var pending: [NativeCheck] { task.checks.filter { !$0.done && !$0.paused } }
    private var valid: Bool { (try? draft.applying(to: task)) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Informe o valor original da parcela e quanto você pagou. O desconto é calculado automaticamente.").font(.subheadline)
                    HStack { Button("Próxima e última") { draft.selected = []; if let first = pending.first { draft.selected.insert(first.id) }; if let last = pending.last { draft.selected.insert(last.id) } }; Spacer(); Button("Limpar seleção") { draft.selected = [] } }.font(.subheadline)
                }
                ForEach(pending.filter { draft.selected.contains($0.id) }) { check in
                    Section(check.title) {
                        LabeledContent("Valor original da parcela") {
                            TextField("R$ 0,00", text: Binding(get: { draft.originals[check.id] ?? "" }, set: { draft.setOriginal($0, id: check.id) }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth: 80)
                                .accessibilityLabel("Valor original da parcela").accessibilityIdentifier("installment-original-" + check.id)
                        }
                        LabeledContent(task.moneyMode == "receive" ? "Valor recebido" : "Valor pago") {
                            TextField("R$ 0,00", text: Binding(get: { draft.paid[check.id] ?? "" }, set: { draft.setPaid($0, id: check.id) }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth: 80)
                                .accessibilityLabel(task.moneyMode == "receive" ? "Valor recebido" : "Valor pago").accessibilityIdentifier("installment-paid-" + check.id)
                        }
                        HStack { Text("Desconto calculado"); Spacer(); Text(draft.discount(check.id).map { NativeDate.money(Double($0)) } ?? "Confira os valores").foregroundStyle(draft.discount(check.id) == nil ? Color.red : .green).accessibilityIdentifier("installment-discount-" + check.id) }.font(.subheadline)
                        Text("O valor original fica preservado junto do valor pago no histórico.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("Escolher parcelas (\(draft.selected.count) selecionadas)") {
                        ForEach(pending) { check in Toggle(check.title, isOn: Binding(get: { draft.selected.contains(check.id) }, set: { enabled in if enabled { draft.selected.insert(check.id) } else { draft.selected.remove(check.id) } })) }
                    }
                    if pending.isEmpty { Text("Todas as parcelas já foram pagas. Consulte ou corrija os registros no Histórico.").foregroundStyle(.secondary) }
                }
                Section("Conferência") {
                    LabeledContent("Total original selecionado", value: NativeDate.money(Double(draft.nominalTotal)))
                    LabeledContent("Valor efetivamente pago", value: NativeDate.money(Double(draft.paidTotal)))
                    LabeledContent("Desconto total", value: NativeDate.money(Double(max(0, draft.nominalTotal - draft.paidTotal))))
                    Text("Registre somente depois do pagamento. As demais parcelas continuam pendentes.").font(.footnote).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }.navigationTitle("Pagamento de parcelas").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Registrar") { confirming = true }.disabled(!valid) }; ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Pronto") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } } }
                .onAppear { if !initialized { draft = NativeInstallmentDraft(task, checkID: initialCheckID); initialized = true } }
                .confirmationDialog("Registrar os valores das parcelas selecionadas?", isPresented: $confirming, titleVisibility: .visible) { Button("Confirmar pagamento") { pay() } }
        }
    }
    private func pay() {
        do { task = try draft.applying(to: task); dismiss(); commit() }
        catch { issue = error.localizedDescription }
    }
}
