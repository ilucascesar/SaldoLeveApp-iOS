import SwiftUI

@MainActor
final class NativeFinanceStore: ObservableObject {
    unowned let parent: NativeStore
    @Published var snapshot = NativeFinanceSnapshot()
    @Published var loading = false
    @Published var needsSync = true
    @Published var syncedAt: Date?
    @Published var issue: String?
    @Published var busy = false
    init(parent: NativeStore) { self.parent = parent }
    var canWrite: Bool { parent.canWrite && !needsSync && !loading && !busy }
    func refresh() async {
        guard parent.user != nil, !loading else { return }
        if parent.isPreview { preview(); return }
        guard parent.networkAvailable else { needsSync = true; issue = "Sem conexão com o servidor. Somente consulta."; return }
        let userID = parent.user?.id
        loading = true; defer { loading = false }
        do {
            let next = try await parent.api.get(NativeFinanceSnapshot.self, action: "bootstrap")
            guard parent.user?.id == userID else { return }
            snapshot = next; needsSync = false; syncedAt = Date(); issue = nil
            await parent.refreshExpenseReminders()
        } catch { parent.noteConnectionFailure(error); needsSync = true; issue = error.localizedDescription }
    }
    @discardableResult
    func save(_ action: String, _ body: JSONObject) async throws -> JSONObject {
        guard canWrite else { throw NativeFailure("Sincronize as despesas antes de alterar os valores.") }
        busy = true; parent.working = true; defer { parent.working = false; busy = false }
        do {
            let response = try await parent.api.post(action: action, body: body)
            needsSync = true; await refresh()
            return response
        } catch {
            if (error as? NativeFailure)?.status == 499 { throw error }
            // A timed-out POST might have committed. Block writes until a fresh
            // bootstrap, never automatically repeat a financial transaction.
            needsSync = true; parent.noteConnectionFailure(error)
            throw NativeFailure(error.localizedDescription + " Sincronize e confira o resultado antes de reenviar.", status: (error as? NativeFailure)?.status ?? 0)
        }
    }
    func reset() { snapshot = NativeFinanceSnapshot(); needsSync = true; syncedAt = nil; issue = nil }
    private func preview() {
        #if DEBUG
        let month = String(NativeFinanceFormat.day(Date()).prefix(7))
        snapshot = NativeFinanceSnapshot([
            "user": .object(["activeMonth": .string(month)]),
            "users": .array([.object(["id": .string("preview"), "name": .string("Lucas")])]),
            "expenses": .array([
                .object(["id": .string("1"), "name": .string("Cartão principal"), "type": .string("card"), "active": .bool(true), "ownerId": .string("preview"), "accent": .string("#1f6feb"), "percent": .number(100)]),
                .object(["id": .string("2"), "name": .string("Casa"), "type": .string("home"), "active": .bool(true), "ownerId": .string("preview"), "accent": .string("#159a68"), "shared": .bool(true), "percent": .number(50)])]),
            "calc": .object(["active": .object(["spent": .number(2549.90), "paid": .number(1200), "pending": .number(1349.90), "pendingCount": .number(2), "income": .number(5500), "balance": .number(2950.10)]), "months": .object([month: .object(["expenses": .object(["1": .object(["integral": .number(1849.90), "considered": .number(1849.90), "installments": .number(499.90)]), "2": .object(["integral": .number(1400), "considered": .number(700)])])])])])])
        var fields = snapshot.fields
        let extra: [(String, String, Double)] = [("3", "Internet", 142.32), ("4", "Seguro do carro", 360.50), ("5", "Energia", 150.80), ("6", "Água", 89.90)]
        fields["expenses"] = .array((fields.objects("expenses") + extra.map { id, name, _ in ["id": .string(id), "name": .string(name), "type": .string("home"), "active": .bool(true), "ownerId": .string("preview"), "accent": .string("#7650c4"), "percent": .number(100)] }).map(JSONValue.object))
        var calc = fields.record("calc"), months = calc.record("months"), monthData = months.record(month), expenses = monthData.record("expenses")
        for (id, _, amount) in extra { expenses[id] = .object(["integral": .number(amount), "considered": .number(amount)]) }
        monthData["expenses"] = .object(expenses); months[month] = .object(monthData); calc["months"] = .object(months)
        var active = calc.record("active"); active["spent"] = .number(3293.42); active["pending"] = .number(2093.42); active["pendingCount"] = .number(6); calc["active"] = .object(active)
        fields["calc"] = .object(calc); snapshot = NativeFinanceSnapshot(fields)
        needsSync = false; syncedAt = Date()
        #endif
    }
}
