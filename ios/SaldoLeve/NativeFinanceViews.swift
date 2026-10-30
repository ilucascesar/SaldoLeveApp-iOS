import SwiftUI

struct NativeFinanceRoute: Identifiable {
    let id = UUID()
    let kind: String
    var fields: JSONObject = [:]
}
struct NativeExpenseCard: View {
    @ObservedObject var finance: NativeFinanceStore
    let expenseID: String
    let open: () -> Void
    private var data: NativeFinanceSnapshot { finance.snapshot }
    private var expense: JSONObject { data.expense(expenseID) }
    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 3).fill(Color(nativeHex: expense.text("accent"))).frame(width: 4)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(expense.text("name")).font(.system(size: 17, weight: .semibold))
                    Text(NativeFinanceFormat.expenseType(expense.text("type")) + (expense["active"] == .bool(false) ? " · Desativada" : "")).font(.caption).foregroundStyle(.secondary)
                    Text(NativeFinanceFormat.money(data.expenseCalculation(expenseID).decimal("integral"))).font(.system(size: 24, weight: .bold, design: .rounded))
                    if expense.flag("shared") { Text("Sua parte: \(NativeFinanceFormat.money(data.expenseCalculation(expenseID).decimal("considered"))) · \(expense.decimal("percent").formatted())%").font(.caption).foregroundStyle(.secondary) }
                    if !data.active.record("paymentChanges").record(expenseID).isEmpty { Label("Valor alterado após pagamento", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { if expense.flag("shared") { open() } else { Task { do { _ = try await finance.save("toggle_payment", ["expenseId": .string(expenseID), "paid": .bool(!data.paid(expenseID))]) } catch { finance.parent.report(error) } } } } label: {
                VStack(spacing: 6) { Image(systemName: data.paid(expenseID) ? "checkmark.circle.fill" : "circle").font(.system(size: 25)); Text(data.paid(expenseID) ? "Paga" : expense.flag("shared") ? "Pagamentos" : "Marcar paga").font(.system(size: 10, weight: .semibold)) }.foregroundStyle(data.paid(expenseID) ? Color.green : nativeBlue).frame(width: 72, height: 65)
            }.buttonStyle(.borderless).disabled(!finance.canWrite || (!data.paid(expenseID) && data.expenseCalculation(expenseID).decimal("integral") <= 0))
        }.padding(.vertical, 5)
    }
}
struct NativeFinanceTransactionRow: View {
    let data: NativeFinanceSnapshot
    let transaction: JSONObject
    var body: some View {
        let calculation = data.transactionCalculation(transaction.text("id"))
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: transaction.text("type") == "refund" ? "arrow.uturn.backward.circle" : transaction.text("type") == "installment" ? "square.stack.3d.up" : transaction.text("type") == "fixed" ? "repeat" : "receipt").foregroundStyle(nativeBlue).frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(transaction.text("desc")).font(.system(size: 15, weight: .medium))
                Text(data.expense(transaction.text("expenseId")).text("name") + " · " + transaction.text("category")).font(.caption).foregroundStyle(.secondary)
                Text(NativeFinanceFormat.type(transaction.text("type")) + (calculation.integer("activeNo") > 0 ? " · \(calculation.integer("activeNo"))/\(transaction.integer("installments"))" : "") + " · " + transaction.text("date")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 5)
            VStack(alignment: .trailing, spacing: 5) {
                Text(NativeFinanceFormat.money(data.isActive(transaction) ? calculation.decimal("activeValue") : (transaction.text("type") == "refund" ? -1 : 1) * transaction.decimal("amount"))).font(.system(size: 15, weight: .semibold)).foregroundStyle(transaction.text("type") == "refund" ? Color.green : Color.primary)
                Text(data.isActive(transaction) ? "neste mês" : "total da compra").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}
