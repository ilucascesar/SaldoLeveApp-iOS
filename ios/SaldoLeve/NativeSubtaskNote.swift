import SwiftUI

struct NativeSubtaskNoteEditor: View {
    @ObservedObject var store: NativeStore
    let taskID: String
    let checkID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var revision = ""
    @State private var initialized = false
    @State private var busy = false
    @State private var issue: String?
    private var editable: Bool { store.taskByID(taskID).map { store.canEdit($0) } ?? false }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(title).font(.headline) }
                Section {
                    TextField("Informações para consultar depois…",text:$text,axis:.vertical)
                        .lineLimit(6...16).disabled(busy || !editable)
                        .onChange(of:text) { if $0.count > 2000 { text = String($0.prefix(2000)) } }
                } header: { Text("Observação") } footer: { Text("Visível para quem tem acesso à tarefa. Não aparece nas notificações nem na lista copiada. Apague o texto e salve para remover.") }
                if let issue {
                    Section {
                        Text(issue).foregroundStyle(.red).font(.footnote)
                        Button("Recarregar observação") { Task { await store.refresh(); load() } }.disabled(busy)
                    }
                }
            }.navigationTitle("Observação").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancelar") { dismiss() }.disabled(busy) }
                ToolbarItem(placement:.confirmationAction) { Button(busy ? "Salvando…" : "Salvar") { Task { await save() } }.disabled(busy || !editable) }
            }
            .onAppear { if !initialized { load(); initialized = true } }
            .interactiveDismissDisabled(busy)
        }
    }
    private func load() { let note = store.subtaskNote(taskID,checkID); text = note.text("text"); revision = note.text("revision"); issue = nil }
    private func save() async {
        busy = true; issue = nil
        defer { busy = false }
        do { try await store.saveSubtaskNote(taskID,checkID:checkID,text:text,revision:revision); dismiss() }
        catch { issue = error.localizedDescription }
    }
}
