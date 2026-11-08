import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SharedReceipt {
    let name: String
    let type: String
    let data: Data
    private static let maxBytes = 2_097_152

    static func read(from context: NSExtensionContext) async throws -> SharedReceipt {
        let providers = context.inputItems.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }
        let files = providers.compactMap { provider -> (NSItemProvider, UTType)? in
            let supported = [UTType.pdf, .image, .fileURL]
            let offered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            for type in supported {
                if let identifier = offered.first(where: { $0.conforms(to: type) }) { return (provider, identifier) }
            }
            return offered.contains(.data) ? (provider, .data) : nil
        }
        guard files.count == 1, let (provider, type) = files.first else {
            throw NativeFailure(files.isEmpty ? "Compartilhe um comprovante em PDF ou imagem." : "Compartilhe um comprovante por vez.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            if type.conforms(to: .fileURL) {
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                    continuation.resume(with: Result {
                        if let error { throw error }
                        guard let url = item as? URL, url.isFileURL else { throw NativeFailure("O aplicativo de origem não enviou um arquivo.") }
                        return try readFile(at: url, suggestedName: provider.suggestedName)
                    })
                }
            } else {
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    // The provider owns the temporary file only until this callback returns.
                    continuation.resume(with: Result {
                        if let error { throw error }
                        guard let url else { throw NativeFailure("Não foi possível ler o comprovante compartilhado.") }
                        return try readFile(at: url, suggestedName: provider.suggestedName)
                    })
                }
            }
        }
    }

    static func readFile(at url: URL, suggestedName: String?) throws -> SharedReceipt {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 1024) ?? Data()
        let givenName = ((suggestedName ?? url.lastPathComponent) as NSString).lastPathComponent
        let stem = (givenName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((stem.isEmpty ? "Comprovante" : stem).prefix(165))
        if header.range(of: Data("%PDF-".utf8)) != nil {
            try file.seek(toOffset: 0)
            guard let bytes = try file.read(upToCount: maxBytes + 1), bytes.count <= maxBytes else {
                throw NativeFailure("O PDF pode ter até 2 MB.")
            }
            return SharedReceipt(name: name + ".pdf", type: "application/pdf", data: bytes)
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let identifier = CGImageSourceGetType(source) as String?, let format = UTType(identifier), format.conforms(to: .image) else {
            throw NativeFailure("O arquivo precisa ser um PDF ou uma imagem válida.")
        }
        if let ext = format.preferredFilenameExtension, let type = format.preferredMIMEType {
            try file.seek(toOffset: 0)
            if let bytes = try file.read(upToCount: maxBytes + 1), !bytes.isEmpty, bytes.count <= maxBytes {
                return SharedReceipt(name: name + "." + ext, type: type, data: bytes)
            }
        }
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 1800]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw NativeFailure("Não foi possível preparar a imagem do comprovante.")
        }
        for quality in [0.85, 0.65, 0.4] {
            let bytes = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            let encoding: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                             kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)]
            CGImageDestinationAddImage(writer, image, encoding as CFDictionary)
            if CGImageDestinationFinalize(writer), bytes.length <= maxBytes {
                return SharedReceipt(name: name + ".jpg", type: "image/jpeg", data: bytes as Data)
            }
        }
        throw NativeFailure("A imagem ficou maior que 2 MB após o ajuste.")
    }
}
