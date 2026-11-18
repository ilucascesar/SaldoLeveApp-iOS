import SwiftUI

/// UITextView somente leitura: permite selecionar e copiar trechos do texto.
/// `selection` devolve o trecho escolhido, para o botão copiar só aquela parte.
struct NativeSelectableText: UIViewRepresentable {
    let text: String
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        view.tintColor = UIColor(nativeBlue)
        view.delegate = context.coordinator
        view.attributedText = Self.styled(text)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.attributedText.string != text { view.attributedText = Self.styled(text) }
    }
    private static func styled(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 4
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
            .paragraphStyle: style
        ])
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeSelectableText
        init(_ parent: NativeSelectableText) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            // Ao tocar num botão a seleção visual some; mantemos o último trecho escolhido.
            if range.length == 0 && !textView.isFirstResponder { return }
            let value = range.length > 0 ? (textView.text as NSString).substring(with: range) : ""
            if value != parent.selection { DispatchQueue.main.async { self.parent.selection = value } }
        }
    }
}

/// Cartão de leitura da observação: ler, selecionar um trecho ou copiar tudo, com atalho para editar.
struct NativeSubtaskNoteViewer: View {
    let title: String
    let text: String
    var onEdit: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var selection = ""
    private var copyTitle: String {
        if copied { return selection.isEmpty ? "Copiado" : "Trecho copiado" }
        return selection.isEmpty ? "Copiar tudo" : "Copiar trecho"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble.fill").font(.system(size: 17)).foregroundStyle(nativeBlue)
                    .frame(width: 38, height: 38).background(Circle().fill(nativeBlue.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Observação").font(.headline)
                    if !title.isEmpty { Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                }.accessibilityLabel("Fechar")
            }
            NativeSelectableText(text: text, selection: $selection)
                .frame(minHeight: 120, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.06)))
            HStack(spacing: 10) {
                Button(action: copy) {
                    Label(copyTitle, systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .tint(copied ? .green : nativeBlue)
                if let onEdit {
                    Button(action: onEdit) { Label("Editar", systemImage: "pencil").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(nativeBlue)
                }
            }
            Text("Segure e arraste no texto para copiar só um trecho.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
    private func copy() {
        UIPasteboard.general.string = selection.isEmpty ? text : selection
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.2)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            selection = ""
        }
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
