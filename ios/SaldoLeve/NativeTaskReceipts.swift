import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct NativeReceiptTarget: Identifiable {
    let id = UUID()
    let task: NativeTask
    let checkID: String
    var paymentID: String? = nil
    var historicalTitle: String? = nil
    var title: String { historicalTitle ?? task.checks.first { $0.id == checkID }?.title ?? task.title }
}

@MainActor
struct NativeTaskReceipts: View {
    @ObservedObject var store: NativeStore
    let target: NativeReceiptTarget
    @Environment(\.dismiss) private var dismiss
    @State private var files: [NativeRecord] = []
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var importing = false
    @State private var working = false
    @State private var loading = true
    @State private var issue: String?
    @State private var status = ""
    @State private var shared: NativeSharedFile?
    private var editable: Bool { store.canWrite && store.canEdit(target.task) && !working && !loading }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(target.title).font(.headline)
                    Text(target.paymentID == nil ? "O comprovante será vinculado a este item. O anexo é opcional." : "Este comprovante ficará no pagamento escolhido do histórico, preservando o mês original. O anexo é opcional.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Adicionar comprovante") {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Escolher foto", systemImage: "photo.on.rectangle") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { camera = true } label: { Label("Tirar foto", systemImage: "camera") } }
                    Button { importing = true } label: { Label("Escolher arquivo", systemImage: "folder") }
                    Button { pasteImage() } label: { Label("Colar imagem copiada", systemImage: "doc.on.clipboard") }
                }.disabled(!editable)
                Section("Comprovantes deste item") {
                    if loading { ProgressView("Carregando…") }
                    else if files.isEmpty { Text("Nenhum comprovante anexado.").foregroundStyle(.secondary) }
                    ForEach(files) { file in
                        Button { Task { do { shared = NativeSharedFile(url: try await store.api.download(id: file.id, name: file.fields.text("name"))) } catch { issue = error.localizedDescription } } } label: {
                            Label(file.fields.text("name"), systemImage: file.fields.text("type").hasPrefix("image/") ? "photo" : "doc")
                        }
                    }
                }
                if working { ProgressView("Enviando comprovante…") }
                if !status.isEmpty { Label(status, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green) }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                Section { Text("Imagens são ajustadas automaticamente. Arquivos e PDFs podem ter até 2 MB. Os comprovantes ficam criptografados no servidor.").font(.footnote).foregroundStyle(.secondary) }
            }.buttonStyle(.borderless)
                .navigationTitle("Comprovantes").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Fechar") { dismiss() }.disabled(working) }
                .interactiveDismissDisabled(working)
                .task { await load() }
                .sheet(item: $shared) { NativeShareSheet(items: [$0.url]) }
                .fullScreenCover(isPresented: $camera) {
                    NativeCamera { image in
                        camera = false
                        if let image { uploadImage(image) }
                    }.ignoresSafeArea()
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf, .data]) { result in importFile(result) }
                .onChange(of: photo) { selection in
                    guard let selection else { return }
                    working = true; issue = nil; status = ""
                    Task {
                        defer { working = false; photo = nil }
                        do {
                            guard let data = try await selection.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw NativeFailure("Não foi possível ler esta foto. Tente escolher a imagem em Arquivos.") }
                            try await upload(NativeImage.receipt(image), name: "Comprovante-\(Int(Date().timeIntervalSince1970)).jpg", type: "image/jpeg")
                        } catch { issue = error.localizedDescription }
                    }
                }
        }.presentationDetents([.medium, .large])
    }
    private func load() async {
        defer { loading = false }
        do {
            let details = try await store.taskDetails(target.task.id)
            files = details.objects("attachments").filter { file in target.paymentID.map { file.text("paymentId") == $0 } ?? (file.text("checkId") == target.checkID) }.map(NativeRecord.init)
        } catch { issue = error.localizedDescription }
    }
    private func upload(_ bytes: Data, name: String, type: String) async throws {
        guard store.canWrite else { throw NativeFailure("Sem conexão com o servidor. Atualize antes de anexar.") }
        guard !bytes.isEmpty, bytes.count <= 2_097_152 else { throw NativeFailure("Escolha um arquivo de até 2 MB.") }
        var payload: JSONObject = ["itemId": .string(target.task.id), "checkId": .string(target.checkID), "name": .string(name), "type": .string(type), "base64": .string(bytes.base64EncodedString())]
        if let id = target.paymentID { payload["paymentId"] = .string(id) }
        _ = try await store.mutate("org_attach", payload)
        status = "Comprovante salvo no servidor."
        await load()
    }
    private func uploadImage(_ image: UIImage) {
        guard !working else { return }
        working = true; issue = nil; status = ""
        Task {
            defer { working = false }
            do { try await upload(NativeImage.receipt(image), name: "Comprovante-\(Int(Date().timeIntervalSince1970)).jpg", type: "image/jpeg") }
            catch { issue = error.localizedDescription }
        }
    }
    private func pasteImage() {
        guard let image = UIPasteboard.general.image else { issue = "Copie uma imagem e toque em Colar. Para PDF, use Escolher arquivo."; return }
        uploadImage(image)
    }
    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
            return
        }
        guard !working else { return }
        working = true; issue = nil; status = ""
        Task {
            defer { working = false }
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= (type.hasPrefix("image/") ? 30_000_000 : 2_097_152) else { throw NativeFailure("O arquivo é muito grande. PDFs podem ter até 2 MB.") }
                let bytes = try Data(contentsOf: url)
                if type.hasPrefix("image/"), let image = UIImage(data: bytes) { try await upload(NativeImage.receipt(image), name: url.deletingPathExtension().lastPathComponent + ".jpg", type: "image/jpeg") }
                else { try await upload(bytes, name: url.lastPathComponent, type: type) }
            } catch { issue = error.localizedDescription }
        }
    }
}
