import Foundation

extension Dictionary where Key == String, Value == JSONValue {
    func decimal(_ key: String) -> Double { self[key]?.number ?? Double(text(key)) ?? 0 }
    func record(_ key: String) -> JSONObject { self[key]?.object ?? [:] }
}

struct NativeFinanceSnapshot: Codable {
    var fields: JSONObject = [:]
    init() {}
    init(_ fields: JSONObject) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try JSONObject(from: decoder) }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    var month: String { String(fields.record("user").text("activeMonth").prefix(7)) }
    var expenses: [JSONObject] { fields.objects("expenses") }
    var transactions: [JSONObject] { fields.objects("transactions") }
    var users: [JSONObject] { fields.objects("users") }
    var categories: [JSONObject] { fields.objects("categories") }
    var closures: [JSONObject] { fields.objects("closedMonths") }
    var calc: JSONObject { fields.record("calc") }
    var active: JSONObject { calc.record("active") }
    var future: [JSONObject] { calc.objects("future") }
    func expense(_ id: String) -> JSONObject { expenses.first { $0.text("id") == id } ?? [:] }
    func expenseCalculation(_ id: String, month: String? = nil) -> JSONObject { calc.record("months").record(month ?? self.month).record("expenses").record(id) }
    func transactionCalculation(_ id: String) -> JSONObject { calc.record("tx").record(id) }
    func paid(_ id: String) -> Bool {
        let progress = active.record("paymentProgress").record(id)
        if progress.flag("ledger") { return progress.flag("complete") }
        return fields.objects("payments").contains { $0.text("expenseId") == id && $0.text("month") == month }
    }
    func invoice(_ id: String) -> JSONObject? { fields.objects("invoices").first { $0.text("expenseId") == id && $0.text("month") == month } }
    func isPending(_ id: String) -> Bool {
        expenseCalculation(id).decimal("integral") > 0 && (!paid(id) || active.record("paymentChanges").record(id).decimal("difference") > 0.004)
    }
    func transactions(_ id: String, activeOnly: Bool) -> [JSONObject] {
        transactions.filter { ($0.text("expenseId") == id || id.isEmpty) && (!activeOnly || isActive($0)) }
            .sorted { $0.text("date") > $1.text("date") }
    }
    func isActive(_ transaction: JSONObject) -> Bool {
        let calculation = transactionCalculation(transaction.text("id"))
        let from = calculation.text("from"), to = calculation.text("to")
        return !from.isEmpty && from <= month && (to.isEmpty || month <= to)
    }
}

enum NativeFinanceFormat {
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "BRL").locale(Locale(identifier: "pt_BR"))) }
    static func input(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "pt_BR"))) }
    static func date(_ raw: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "America/Sao_Paulo"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f.date(from: String(raw.prefix(10)))
    }
    static func day(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "America/Sao_Paulo"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
    static func month(_ raw: String) -> String {
        guard let date = date(String(raw.prefix(7)) + "-01") else { return raw }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "pt_BR"); formatter.timeZone = TimeZone(identifier: "America/Sao_Paulo"); formatter.dateFormat = "MMMM 'de' yyyy"
        return formatter.string(from: date).capitalized
    }
    static func amount(_ raw: String, allowZero: Bool = false) throws -> Double {
        guard let cents = NativeDate.cents(raw), cents <= 9_999_999_999, allowZero || cents > 0 else { throw NativeFailure("Informe um valor válido de até R$ 99.999.999,99.") }
        return Double(cents) / 100
    }
    static func expenseType(_ type: String) -> String { type == "card" ? "Cartão de crédito" : type == "home" ? "Despesa da casa" : "Outros" }
    static func type(_ type: String) -> String { ["single": "Avulso", "fixed": "Fixo", "installment": "Parcelado", "refund": "Estorno"][type] ?? type }
    static func shares(_ values: [String: String], ids: [String]) throws -> JSONObject {
        var result: JSONObject = [:]; var total = 0
        for id in ids {
            guard let value = NativeDate.cents(values[id] ?? ""), value <= 10000 else { throw NativeFailure("Informe percentuais entre 0 e 100.") }
            total += value; result[id] = .number(Double(value) / 100)
        }
        guard total == 10000 else { throw NativeFailure("A divisão precisa somar exatamente 100%.") }; return result
    }
}
