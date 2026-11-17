import SwiftUI

/// UITextView somente leitura: permite selecionar e copiar trechos do texto.
struct NativeSelectableText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { if view.text != text { view.text = text } }
}

/// Balão de leitura da observação: ver, selecionar e copiar. A edição fica no menu da subtarefa.
struct NativeSubtaskNoteViewer: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty { Text(title).font(.headline).padding(.horizontal, 16).padding(.top, 8) }
                NativeSelectableText(text: text)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                    .padding(.horizontal, 12)
                Text("Toque e segure para selecionar trechos. Para editar, use os três pontos da subtarefa.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            }
            .navigationTitle("Observação").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Copiado" : "Copiar tudo") { UIPasteboard.general.string = text; copied = true }
                }
            }
        }.presentationDetents([.medium, .large])
    }
}

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
