import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import PDFKit
import QuickLook

func nativeCurrentReceipt(_ file: NativeRecord, task: NativeTask) -> Bool {
    let check = task.checks.first { $0.id == file.fields.text("checkId") }
    if !file.fields.text("paymentId").isEmpty, let scope = file.fields["scopeDueAt"] {
        let due = check.map { $0.fields.text("remindAt") } ?? task.fields.text("dueAt")
        return (check?.done ?? task.isDone) && (scope.string ?? "") == due
    }
    return file.fields["cycleNumber"] == nil || file.fields.integer("cycleNumber") == task.fields.integer("cycleNumber")
}

struct NativeReceiptThumbnail: View {
    let api: NativeAPI
    let file: NativeRecord
    var size = CGSize(width: 46, height: 46)
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: file.fields.text("type").hasPrefix("image/") ? "photo" : "doc.text")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: file.id) {
            image = nil
            guard let bytes = try? await api.attachmentData(id: file.id), !Task.isCancelled else { return }
            if bytes.starts(with: Data("%PDF-".utf8)) || file.fields.text("type") == "application/pdf" {
                image = PDFDocument(data: bytes)?.page(at: 0)?.thumbnail(of: CGSize(width: size.width * 3, height: size.height * 3), for: .cropBox)
            } else if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 3)
                      ] as CFDictionary) {
                image = UIImage(cgImage: thumbnail)
            }
        }
    }
}

struct NativeReceiptTarget: Identifiable {
    let id = UUID()
    let task: NativeTask
    let checkID: String
    var paymentID: String? = nil
    var historicalTitle: String? = nil
    var viewOnly = false
    var quickAttach: Bool { !checkID.isEmpty && paymentID == nil && !viewOnly }
    var title: String { historicalTitle ?? task.checks.first { $0.id == checkID }?.title ?? task.title }
}

@MainActor
struct NativeTaskReceipts: View {
    @ObservedObject var store: NativeStore
    let target: NativeReceiptTarget
    var onFilesChanged: ([NativeRecord]) -> Void = { _ in }
    var onAttached: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var files: [NativeRecord] = []
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var importing = false
    @State private var working = false
    @State private var loading = true
    @State private var issue: String?
    @State private var status = ""
    @State private var preview: URL?
    private var editable: Bool { store.canWrite && store.canEdit(target.task) && !working && (target.quickAttach || !loading) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(target.title).font(.headline)
                    if target.quickAttach {
                        if working { ProgressView("Enviando comprovante…").font(.footnote) }
                        if !status.isEmpty { Label(status, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green) }
                        if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                    }
                    if !target.viewOnly && !target.quickAttach {
                        Text(target.paymentID == nil ? "O comprovante será vinculado a este item. O anexo é opcional." : "Este comprovante ficará no pagamento escolhido do histórico, preservando o mês original. O anexo é opcional.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !target.viewOnly && (!target.quickAttach || !working) {
                Section {
                    PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) { Label("Escolher foto", systemImage: "photo.on.rectangle") }
                    Button { importing = true } label: { Label("Escolher PDF ou arquivo", systemImage: "folder") }
                    Button { pasteReceipt() } label: { Label("Colar comprovante", systemImage: "doc.on.clipboard") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { camera = true } label: { Label("Tirar foto", systemImage: "camera") } }
                }.disabled(!editable)
                }
                if !target.quickAttach {
                Section("Comprovantes deste item") {
                    if loading { ProgressView("Carregando…") }
                    else if files.isEmpty { Text("Nenhum comprovante anexado.").foregroundStyle(.secondary) }
                    ForEach(files) { file in
                        Button { Task { do { preview = try await store.api.download(id: file.id, name: file.fields.text("name")) } catch { issue = error.localizedDescription } } } label: {
                            HStack(spacing: 10) {
                                NativeReceiptThumbnail(api: store.api, file: file)
                                Text(file.fields.text("name"))
                            }
                        }
                    }
                }
                }
                if !target.quickAttach {
                    if working { ProgressView("Enviando comprovante…") }
                    if !status.isEmpty { Label(status, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green) }
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                }
                if !target.viewOnly && !target.quickAttach {
                    Section { Text("Arquivos e PDFs podem ter até 2 MB. Imagens maiores são reduzidas. Os comprovantes ficam criptografados no servidor.").font(.footnote).foregroundStyle(.secondary) }
                }
            }.buttonStyle(.borderless)
                .navigationTitle(target.quickAttach ? "Anexar comprovante" : "Comprovantes").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(target.quickAttach ? "Cancelar" : "Fechar") { dismiss() }.disabled(working) }
                .interactiveDismissDisabled(working)
                .task { if !target.quickAttach { await load() } }
                .quickLookPreview($preview)
                .onChange(of: preview) { [preview] next in
                    if let preview, preview != next { try? FileManager.default.removeItem(at: preview.deletingLastPathComponent()) }
                }
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
                            let source = CGImageSourceCreateWithData(data as CFData, nil)
                            let type = source.flatMap { CGImageSourceGetType($0) as String? }.flatMap { UTType($0) }
                            if data.count <= 2_097_152, let mime = type?.preferredMIMEType, let ext = type?.preferredFilenameExtension {
                                try await upload(data, name: "Comprovante-\(Int(Date().timeIntervalSince1970))." + ext, type: mime)
                            } else {
                                try await upload(NativeImage.receipt(image), name: "Comprovante-\(Int(Date().timeIntervalSince1970)).jpg", type: "image/jpeg")
                            }
                        } catch { issue = error.localizedDescription }
                    }
                }
        }
        .presentationDetents(target.quickAttach ? [.height(360), .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }
    @discardableResult private func load() async -> Bool {
        defer { loading = false }
        do {
            let details = try await store.taskDetails(target.task.id)
            let all = details.objects("attachments").map(NativeRecord.init)
            let task = NativeTask(details.record("item"))
            files = all.filter { file in
                target.paymentID.map { file.fields.text("paymentId") == $0 }
                    ?? (file.fields.text("checkId") == target.checkID && (!target.viewOnly || nativeCurrentReceipt(file, task: task)))
            }
            onFilesChanged(all)
            return true
        } catch { issue = error.localizedDescription; return false }
    }
    private func upload(_ bytes: Data, name: String, type: String) async throws {
        guard store.canWrite else { throw NativeFailure("Sem conexão com o servidor. Atualize antes de anexar.") }
        guard !bytes.isEmpty, bytes.count <= 2_097_152 else { throw NativeFailure("Escolha um arquivo de até 2 MB.") }
        var payload: JSONObject = ["itemId": .string(target.task.id), "checkId": .string(target.checkID), "name": .string(name), "type": .string(type), "base64": .string(bytes.base64EncodedString())]
        if let id = target.paymentID { payload["paymentId"] = .string(id) }
        let confirmDestination = target.quickAttach && (target.task.isActive || target.task.isDone)
        if confirmDestination { payload["revision"] = .number(Double(target.task.revision)) }
        _ = try await store.mutate(confirmDestination ? "org_attach_receipt" : "org_attach", payload)
        status = "Comprovante salvo no servidor."
        let refreshed = await load()
        onAttached()
        if target.quickAttach && refreshed { dismiss() }
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
    private func pasteReceipt() {
        guard !working else { return }
        let clipboard = UIPasteboard.general
        if let type = clipboard.types.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .pdf) || $0.conforms(to: .image) }),
           let data = clipboard.data(forPasteboardType: type.identifier),
           let ext = type.preferredFilenameExtension, let mime = type.preferredMIMEType {
            if data.count > 2_097_152, type.conforms(to: .image), let image = UIImage(data: data) {
                uploadImage(image)
                return
            }
            working = true; issue = nil; status = ""
            Task {
                defer { working = false }
                do { try await upload(data, name: "Comprovante-\(Int(Date().timeIntervalSince1970))." + ext, type: mime) }
                catch { issue = error.localizedDescription }
            }
        } else if let url = clipboard.url, url.isFileURL {
            importFile(.success(url))
        } else if let image = clipboard.image {
            uploadImage(image)
        } else {
            issue = "Copie uma imagem ou um PDF e toque em Colar comprovante. Você também pode escolher o arquivo."
        }
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
                if bytes.count > 2_097_152, type.hasPrefix("image/"), let image = UIImage(data: bytes) { try await upload(NativeImage.receipt(image), name: url.deletingPathExtension().lastPathComponent + ".jpg", type: "image/jpeg") }
                else { try await upload(bytes, name: url.lastPathComponent, type: type) }
            } catch { issue = error.localizedDescription }
        }
    }
}
