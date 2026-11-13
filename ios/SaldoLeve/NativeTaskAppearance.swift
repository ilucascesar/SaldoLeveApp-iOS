import SwiftUI

struct NativeTaskAppearance: View {
    @ObservedObject var store: NativeStore
    let taskID: String
    var checkID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var choice = ""
    @State private var original = ""
    @State private var busy = false
    @State private var issue: String?
    @State private var configure = false
    @State private var initialized = false
    private var key: String { checkID.map { taskID + ":" + $0 } ?? taskID }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach([("",checkID == nil ? "Usar padrão" : "Seguir layout da tarefa"),("compact","Compacto personalizado"),("regular","Normal")],id:\.0) { value,title in
                        Button { choice = value } label: {
                            HStack { Label(title,systemImage:value == "compact" ? "list.bullet" : "rectangle.grid.1x2");Spacer();if choice == value { Image(systemName:"checkmark").foregroundStyle(nativeBlue) } }.foregroundStyle(.primary)
                        }
                    }
                } footer: { Text(checkID == nil ? "Vale para todas as subtarefas desta tarefa. O menu de cada subtarefa permite uma escolha diferente." : "Esta escolha vale somente para esta subtarefa.") }
                Section {
                    Button { configure = true } label: { Label("Personalizar modelo compacto",systemImage:"slider.horizontal.3") }
                } footer: { Text("Nome, data e indicador de anexo permanecem visíveis no compacto. O modelo é configurado uma vez e reutilizado nas tarefas escolhidas.") }
                if let issue { Text(issue).foregroundStyle(.red).font(.footnote) }
            }.navigationTitle(checkID == nil ? "Layout das subtarefas" : "Layout desta subtarefa").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Fechar") { dismiss() }.disabled(busy) }
                ToolbarItem(placement:.confirmationAction) { Button(busy ? "Salvando…" : "Aplicar") { Task { await save() } }.disabled(busy || !store.platform.canWrite) }
            }
            .onAppear { if !initialized { reload();initialized = true } }
            .sheet(isPresented:$configure) { NativeLayoutSettings(store:store,initialScreen:.task) }
            .interactiveDismissDisabled(busy)
        }
    }
    private func reload() { original = (checkID == nil ? store.layout.taskItemLayouts : store.layout.taskCheckLayouts)[key] ?? "";choice = original }
    private func save() async {
        guard !busy,store.platform.canWrite else { return };busy = true;issue = nil;defer { busy = false }
        do {
            var layout = store.layout
            if checkID == nil { layout.taskItemLayouts[key] = choice.isEmpty ? nil : choice }
            else { layout.taskCheckLayouts[key] = choice.isEmpty ? nil : choice }
            try await store.platform.saveLayout(layout,revision:store.platform.snapshot.revision)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
