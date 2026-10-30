import Foundation

struct NativeInstallmentDraft {
    var selected = Set<String>()
    var originals: [String: String] = [:]
    var paid: [String: String] = [:]
    private var editedPaid = Set<String>()
    init() {}
    init(_ task: NativeTask, checkID: String? = nil) {
        let pending = task.checks.filter { !$0.done && !$0.paused }
        for check in pending {
            let value = check.fields["amountCents"]?.number.map { NativeFinanceFormat.input($0 / 100) } ?? ""
            originals[check.id] = value; paid[check.id] = value
        }
        if let id = checkID, pending.contains(where: { $0.id == id }) { selected.insert(id) }
        else if let first = pending.first { selected.insert(first.id) }
    }
    mutating func setOriginal(_ value: String, id: String) {
        originals[id] = value
        if !editedPaid.contains(id) { paid[id] = value }
    }
    mutating func setPaid(_ value: String, id: String) { paid[id] = value; editedPaid.insert(id) }
    var nominalTotal: Int { selected.reduce(0) { $0 + (NativeDate.cents(originals[$1] ?? "") ?? 0) } }
    var paidTotal: Int { selected.reduce(0) { $0 + (NativeDate.cents(paid[$1] ?? "") ?? 0) } }
    func discount(_ id: String) -> Int? {
        guard let original = NativeDate.cents(originals[id] ?? ""), let actual = NativeDate.cents(paid[id] ?? ""), actual <= original else { return nil }
        return original - actual
    }
    func applying(to task: NativeTask) throws -> NativeTask {
        guard task.isMoney, !selected.isEmpty else { throw NativeFailure("Selecione pelo menos uma parcela.") }
        let pending = task.checks.filter { selected.contains($0.id) && !$0.done && !$0.paused }
        guard pending.count == selected.count else { throw NativeFailure("A seleção mudou. Reabra o pagamento para conferir as parcelas pendentes.") }
        for check in pending {
            guard NativeDate.cents(originals[check.id] ?? "") != nil else { throw NativeFailure("Informe o valor original de \(check.title).") }
            guard NativeDate.cents(paid[check.id] ?? "") != nil else { throw NativeFailure("Informe o valor pago de \(check.title).") }
            guard discount(check.id) != nil else { throw NativeFailure("O valor pago não pode superar o valor original de \(check.title).") }
        }
        var result = task
        result.fields["checklist"] = .array(task.checks.map { check in
            var fields = check.fields
            if selected.contains(check.id) {
                fields["amountCents"] = .number(Double(NativeDate.cents(originals[check.id] ?? "")!))
                fields["paidAmountCents"] = .number(Double(NativeDate.cents(paid[check.id] ?? "")!)); fields["done"] = .bool(true)
            }
            return .object(fields)
        })
        return result
    }
}
