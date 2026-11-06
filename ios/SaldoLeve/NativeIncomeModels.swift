import Foundation

struct NativeIncomeExtra: Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var amount = ""
}
struct NativeIncomeDraft {
    let month: String, version: String
    var baseAmount: String
    var extras: [NativeIncomeExtra]
    init(month: String, record: JSONObject = [:]) {
        self.month = month; version = record.text("version")
        baseAmount = record.isEmpty ? "" : NativeFinanceFormat.input(record["baseAmount"]?.number ?? record.decimal("amount"))
        extras = record.objects("extras").map { NativeIncomeExtra(id: $0.text("id"), name: $0.text("name"), amount: NativeFinanceFormat.input($0.decimal("amount"))) }
    }
    func payload() throws -> JSONObject {
        guard extras.count <= 100 else { throw NativeFailure("Adicione até 100 extras por mês.") }
        let base = try NativeFinanceFormat.amount(baseAmount.trimmingCharacters(in: .whitespaces).isEmpty ? "0" : baseAmount, allowZero: true)
        var total = Int((base * 100).rounded()), ids = Set<String>()
        let items: [JSONValue] = try extras.map { extra in
            let name = extra.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100, ids.insert(extra.id).inserted else { throw NativeFailure("Informe o nome de cada extra.") }
            let amount = try NativeFinanceFormat.amount(extra.amount); total += Int((amount * 100).rounded())
            return .object(["id": .string(extra.id), "name": .string(name), "amount": .number(amount)])
        }
        guard total <= 9_999_999_999 else { throw NativeFailure("O total da renda ultrapassa o limite permitido.") }
        return ["month": .string(month), "version": .string(version), "baseAmount": .number(base), "extras": .array(items), "amount": .number(Double(total) / 100)]
    }
}
