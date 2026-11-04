import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct NativeSharedFile: Identifiable { let id = UUID(); let url: URL }
struct NativeShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct NativeCamera: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { onCapture(info[.originalImage] as? UIImage) }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCapture(nil) }
    }
}
enum NativeImage {
    static func receipt(_ image: UIImage) throws -> Data {
        let ratio = min(1, 1800 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.85, 0.65, 0.4] {
            if let bytes = resized.jpegData(compressionQuality: quality), bytes.count <= 2_097_152 { return bytes }
        }
        throw NativeFailure("A imagem continua maior que 2 MB. Escolha uma imagem menor.")
    }
}

struct NativeCollectionTools: View {
    @ObservedObject var store: NativeStore
    var categoryID: String
    var items: [NativeTask]
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var pasted = ""
    @State private var proposed: [NativeTask] = []
    @State private var shared: NativeSharedFile?
    @State private var importing = false
    var body: some View {
        NavigationStack {
            Form {
                if !categoryID.isEmpty { Section("Resumo do mês") { NativeMoneySummaryLine(store: store, categoryID: categoryID, expanded: true) } }
                Section("Exportar") {
                    Button("Exportar \(items.count) tarefas em JSON") {
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SaldoLeve-Tarefas-\(UUID().uuidString.prefix(8)).json")
                            try JSONEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtection]); shared = NativeSharedFile(url: url)
                        } catch { store.report(error) }
                    }
                }
                Section("Importar") {
                    Picker("Categoria de destino", selection: $target) { ForEach(store.editableCategories) { Text($0.name).tag($0.id) } }
                    Button("Abrir arquivo JSON") { importing = true }
                    TextEditor(text: $pasted).frame(minHeight: 120).overlay(alignment: .topLeading) { if pasted.isEmpty { Text("Cole uma tarefa por linha ou uma tabela com nome, valor e data (dd/mm/aaaa).").font(.footnote).foregroundStyle(.secondary).padding(5).allowsHitTesting(false) } }
                    Button("Conferir lista / tabela") { do { proposed = try NativeTableImport.parse(pasted, categoryID: target) } catch { store.report(error) } }.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.isEmpty)
                }
                if !proposed.isEmpty {
                    Section("Conferir \(proposed.count) novas tarefas") {
                        ForEach(Array(proposed.enumerated()), id: \.offset) { _, task in VStack(alignment: .leading, spacing: 4) { Text(task.title); if task.isMoney { Text(NativeDate.money(task.pendingAmount)).font(.caption).foregroundStyle(.secondary) }; if let date = task.listDate { Text(NativeDateLabel.text(date)).font(.caption).foregroundStyle(.secondary) } }.id(task.fields.text("captureKey")) }
                        Button("Importar na categoria selecionada") { let batch = proposed; Task { do { _ = try await store.mutate("org_import", ["listId": .string(target), "items": .array(batch.map { .object($0.fields) })]); proposed = []; pasted = "" } catch { store.report(error) } } }.disabled(!store.canWrite || target.isEmpty)
                        Button("Descartar prévia", role: .destructive) { proposed = [] }
                    }
                }
            }.navigationTitle("Ferramentas da lista").navigationBarTitleDisplayMode(.inline).toolbar { Button("Fechar") { dismiss() } }
                .onAppear { target = store.editableCategories.first(where: { $0.id == categoryID })?.id ?? store.editableCategories.first?.id ?? "" }
                .sheet(item: $shared) { NativeShareSheet(items: [$0.url]) }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_097_152 else { throw NativeFailure("Importe um arquivo de até 2 MB.") }
                        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
                        let values = raw.array.isEmpty ? raw.object["items"]?.array ?? [] : raw.array
                        guard !values.isEmpty && values.count <= 200 else { throw NativeFailure("O JSON deve conter de 1 a 200 tarefas.") }
                        proposed = values.map { raw in var draft = NativeTask.draft(categoryID: target); draft.fields.merge(raw.object) { _, value in value }; draft.fields["id"] = .string(UUID().uuidString); return draft }.filter { !$0.title.isEmpty }
                    } catch { store.report(error) }
                }
        }
    }
}
struct NativeMoneySummaryLine: View {
    @ObservedObject var store: NativeStore
    var categoryID: String
    var expanded = false
    @State private var totals: JSONObject = [:]
    @State private var open = false
    var body: some View {
        Group {
            if expanded { details }
            else if !totals.isEmpty { Button { open = true } label: { Label("Este mês · a pagar \(NativeDate.money(totals["pay"]?.object["pending"]?.number)) · a receber \(NativeDate.money(totals["receive"]?.object["pending"]?.number))", systemImage: "chart.bar").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }.padding(9).background(nativePaper, in: RoundedRectangle(cornerRadius: 10)) }
        }
        .task(id: categoryID + String(describing: store.syncedAt)) {
            guard !categoryID.isEmpty, !store.offline, !store.isPreview, store.snapshot.items.contains(where: { $0.categoryID == categoryID && $0.isMoney }) else { totals = [:]; return }
            do { let data = try await store.api.get(JSONObject.self, action: "org_money_summary", query: ["listId": categoryID, "month": NativeMonth.key(Date())]); if !Task.isCancelled { totals = data["totals"]?.object ?? [:] } } catch { }
        }
        .sheet(isPresented: $open) { NavigationStack { Form { details }.navigationTitle("Resumo do mês").navigationBarTitleDisplayMode(.inline).toolbar { Button("Fechar") { open = false } } }.presentationDetents([.medium, .large]) }
    }
    private var details: some View {
        ForEach(["pay", "receive"], id: \.self) { mode in
            let value = totals[mode]?.object ?? [:]
            VStack(alignment: .leading, spacing: 8) { Text(mode == "pay" ? "A pagar" : "A receber").font(.headline); LabeledContent("Pendente", value: NativeDate.money(value["pending"]?.number)); LabeledContent("Pago / recebido", value: NativeDate.money(value["paid"]?.number)); if value.integer("unknown") > 0 { Text("\(value.integer("unknown")) valores a definir").font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 6)
        }
    }
}
