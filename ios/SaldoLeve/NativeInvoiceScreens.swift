import SwiftUI

// Telas do app para faturas (usam o armazenamento financeiro; ficam fora da extensão de compartilhamento).
@MainActor
struct NativeInvoiceFlowSheet: View {
    @ObservedObject var finance: NativeFinanceStore
    var cardID = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { NativeInvoiceFlow(api: finance.parent.api, preselectedCard: cardID) { dismiss() } }
                .navigationTitle("Lançar fatura")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
    }
}

@MainActor
struct NativeInvoicePanorama: View {
    @ObservedObject var finance: NativeFinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var payload = ""
    @State private var issue: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if let issue {
                    VStack(spacing: 14) {
                        Text(issue).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Tentar de novo") { Task { await load() } }
                    }.padding(24)
                } else if payload.isEmpty {
                    ProgressView("Carregando as faturas…")
                } else {
                    NativePanoramaWeb(address: finance.parent.api.address, payload: payload)
                }
            }
            .navigationTitle("Panorama das faturas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        issue = nil
        defer { loading = false }
        do {
            let list = try await finance.parent.api.get(JSONObject.self, action: "invoice_list")
            var names: JSONObject = [:]
            for expense in finance.snapshot.expenses { names[expense.text("id")] = .string(expense.text("name")) }
            let body: JSONObject = ["analyses": list["analyses"] ?? .array([]), "names": .object(names)]
            let encoded = try JSONEncoder().encode(body)
            payload = String(decoding: encoded, as: UTF8.self)
        } catch {
            issue = error.localizedDescription
        }
    }
}
