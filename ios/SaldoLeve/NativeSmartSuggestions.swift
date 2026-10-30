import SwiftUI

@MainActor struct NativeSmartSuggestions: View {
    @ObservedObject var store: NativeStore
    let context: String
    let text: String
    var excludeID = ""
    let apply: (JSONObject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [JSONObject] = []
    @State private var selected = Set<String>()
    @State private var issue: String?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Sugestões baseadas em descrições parecidas no seu histórico. Escolha os campos que deseja aplicar; depois confirme o salvamento do registro.").font(.footnote).foregroundStyle(.secondary) }
                if loading { ProgressView("Consultando histórico…") }
                ForEach(suggestions.indices, id: \.self) { index in
                    let value = suggestions[index], field = value.text("field")
                    Toggle(isOn: Binding(get: { selected.contains(field) }, set: { if $0 { selected.insert(field) } else { selected.remove(field) } })) {
                        VStack(alignment: .leading, spacing: 4) { Text(value.text("label") + ": " + value.text("display")); Text(value.text("reason")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Sugestões de organização").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Aplicar") { var values: JSONObject = [:]; for value in suggestions where selected.contains(value.text("field")) { values[value.text("field")] = value["value"] }; apply(values); dismiss() }.disabled(selected.isEmpty || !store.canWrite) }
                }
                .task {
                    defer { loading = false }
                    do { let result = try await store.api.get(JSONObject.self, action: "smart_suggestions", query: ["context": context, "q": text, "excludeId": excludeID]); suggestions = result.objects("suggestions"); if suggestions.isEmpty { issue = result.text("message").isEmpty ? "Nenhum padrão consistente encontrado." : result.text("message") } }
                    catch { store.noteConnectionFailure(error); issue = error.localizedDescription }
                }
        }
    }
}
