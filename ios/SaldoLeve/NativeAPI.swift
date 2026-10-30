import Foundation
import Security
import CryptoKit

struct NativeEnvelope<T: Decodable>: Decodable {
    var ok: Bool
    var message: String?
    var data: T?
}
struct NativeSession: Codable {
    var authenticated: Bool
    var requiresPasswordChange: Bool
    var csrf: String
    var loginCsrf: String
    var user: NativeIdentity?
    var deviceToken: String?
    var nativeApiVersion: Int?
}
enum NativeKeychain {
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SaldoLeve.Native",
                                   kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String?, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SaldoLeve.Native", kSecAttrAccount as String: account]
        guard let value else { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class NativeAPI {
    let address: SiteAddress
    let storageID: String
    private let session: URLSession
    private var cookie: String?
    var csrf = ""
    var loginCsrf = ""
    private var restoring: Task<NativeSession, Error>?
    var reviewWarnings: (([JSONObject]) async -> Bool)?
    private var pendingOperations: [String: String] = [:]
    private var acceptedReviews: [String: String] = [:]
    init(address: SiteAddress) {
        self.address = address
        storageID = SHA256.hash(data: Data(address.home.deletingLastPathComponent().absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        cookie = NativeKeychain.read("session-" + storageID)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    private func url(_ file: String, query: [String: String]) -> URL {
        let base = address.home.deletingLastPathComponent().appendingPathComponent(file)
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    private func transport(file: String, query: [String: String], body: JSONObject? = nil, token: String? = nil, operationKey: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(file, query: query), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let operationKey { request.setValue(operationKey, forHTTPHeaderField: "Idempotency-Key") }
        request.setValue("SaldoLeveNativeTasks/2.0", forHTTPHeaderField: "User-Agent")
        if let cookie { request.setValue("SALDOLEVESESSID=" + cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token ?? csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeFailure("Resposta inválida da hospedagem.") }
        if let cookieHeader = http.value(forHTTPHeaderField: "Set-Cookie"), let origin = http.url {
            let values = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookieHeader], for: origin)
            if let value = values.first(where: { $0.name == "SALDOLEVESESSID" }) {
                cookie = value.value.isEmpty || (value.expiresDate.map { $0 < Date() } ?? false) ? nil : value.value
                NativeKeychain.write(cookie, account: "session-" + storageID)
            }
        }
        return (bytes, http)
    }
    private func decode<T: Decodable>(_ type: T.Type, file: String, query: [String: String], body: JSONObject? = nil, token: String? = nil) async throws -> T {
        let (bytes, response) = try await transport(file: file, query: query, body: body, token: token)
        let decoded = await Task.detached(priority: .userInitiated) { try? JSONDecoder().decode(NativeEnvelope<T>.self, from: bytes) }.value
        guard let result = decoded else {
            throw NativeFailure(response.statusCode == 404
                ? "Envie mobile-auth.php e config/mobile-auth.php para a HostGator antes de usar esta versão nativa."
                : "A hospedagem não respondeu com a API esperada. Confira a atualização do servidor.", status: response.statusCode)
        }
        guard result.ok, (200..<300).contains(response.statusCode), let data = result.data else {
            throw NativeFailure(result.message ?? "Não foi possível concluir a solicitação.", status: response.statusCode)
        }
        return data
    }
    func restore() async throws -> NativeSession {
        if let restoring { return try await restoring.value }
        let task = Task { try await performRestore() }; restoring = task
        defer { restoring = nil }; return try await task.value
    }
    private func performRestore() async throws -> NativeSession {
        var data: NativeSession
        do { data = try await decode(NativeSession.self, file: "mobile-auth.php", query: ["action": "session"]) }
        catch let failure as NativeFailure where failure.status == 401 {
            clearSession()
            data = try await decode(NativeSession.self, file: "mobile-auth.php", query: ["action": "session"])
        }
        if !data.authenticated, let token = NativeKeychain.read("device-" + storageID) {
            do { data = try await decode(NativeSession.self, file: "mobile-auth.php", query: ["action": "resume"], body: ["token": .string(token)], token: data.loginCsrf) }
            catch let failure as NativeFailure where [401, 403].contains(failure.status) { NativeKeychain.write(nil, account: "device-" + storageID); throw failure }
        }
        if data.authenticated && (data.nativeApiVersion ?? 1) >= 2 && NativeKeychain.read("device-" + storageID) == nil {
            data = try await decode(NativeSession.self, file: "mobile-auth.php", query: ["action": "remember"], body: ["deviceName": .string("SaldoLeve · iPhone")], token: data.loginCsrf)
        }
        if let token = data.deviceToken { NativeKeychain.write(token, account: "device-" + storageID) }
        csrf = data.csrf; loginCsrf = data.loginCsrf
        return data
    }
    func login(user: String, password: String, changingPassword: Bool) async throws -> NativeSession {
        if loginCsrf.isEmpty { _ = try await restore() }
        var body: JSONObject = changingPassword
            ? ["nova_senha": .string(password), "confirmar_senha": .string(password)]
            : ["usuario": .string(user), "senha": .string(password)]
        body["deviceName"] = .string("SaldoLeve · iPhone")
        let data = try await decode(NativeSession.self, file: "mobile-auth.php", query: ["action": changingPassword ? "password" : "login"], body: body, token: loginCsrf)
        csrf = data.csrf; loginCsrf = data.loginCsrf
        if let token = data.deviceToken { NativeKeychain.write(token, account: "device-" + storageID) }
        return data
    }
    func logout() async throws {
        if loginCsrf.isEmpty { _ = try await restore() }
        let (_, response) = try await transport(file: "mobile-auth.php", query: ["action": "logout"], body: [:], token: loginCsrf)
        guard (200..<300).contains(response.statusCode) else { throw NativeFailure("Não foi possível encerrar a sessão no servidor.", status: response.statusCode) }
        clearSession(forgetDevice: true)
    }
    func clearSession(forgetDevice: Bool = false) {
        cookie = nil; csrf = ""; loginCsrf = ""; pendingOperations = [:]; acceptedReviews = [:]
        NativeKeychain.write(nil, account: "session-" + storageID)
        if forgetDevice { NativeKeychain.write(nil, account: "device-" + storageID) }
    }
    func get<T: Decodable>(_ type: T.Type, action: String, query: [String: String] = [:]) async throws -> T {
        do { return try await decode(type, file: "api.php", query: query.merging(["api": action]) { _, new in new }) }
        catch let failure as NativeFailure where failure.status == 401 && NativeKeychain.read("device-" + storageID) != nil {
            let session = try await restore()
            guard session.authenticated else { throw failure }
            return try await decode(type, file: "api.php", query: query.merging(["api": action]) { _, new in new })
        }
    }
    func devices() async throws -> JSONObject {
        _ = try await restore()
        return try await decode(JSONObject.self, file: "mobile-auth.php", query: ["action": "devices"])
    }
    func revokeDevice(_ id: String) async throws -> Bool {
        let result = try await decode(JSONObject.self, file: "mobile-auth.php", query: ["action": "revoke_device"], body: ["id": .string(id)], token: loginCsrf)
        if result.flag("current") { clearSession(forgetDevice: true) }
        return result.flag("current")
    }
    func post(action: String, body: JSONObject) async throws -> JSONObject {
        var payload = body
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var fingerprintBody = body; fingerprintBody.removeValue(forKey: "_smartConfirmation")
        let encoded = try encoder.encode(fingerprintBody)
        let fingerprint = action + "|" + SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let watched = ["org_save_item", "org_adjust_check_values", "org_edit_payment", "create_transaction", "update_transaction", "update_expense", "record_expense_payment", "set_fixed_month_amount", "save_income", "save_invoice", "settle_installment"]
        if watched.contains(action) {
            let preview = try await post(action: "smart_preview", body: ["action": .string(action), "payload": .object(body)])
            let warnings = preview.objects("warnings"), token = preview.text("confirmToken")
            if !warnings.isEmpty && acceptedReviews[fingerprint] != token {
                guard let reviewWarnings, await reviewWarnings(warnings) else { throw NativeFailure("Revise os valores e as datas antes de salvar.", status: 499) }
                acceptedReviews[fingerprint] = token
            }
            if !warnings.isEmpty { payload["_smartConfirmation"] = .string(token) }
        }
        let key: String?
        if action == "smart_preview" { key = nil }
        else { key = pendingOperations[fingerprint] ?? UUID().uuidString; pendingOperations[fingerprint] = key }
        let (bytes, response) = try await transport(file: "api.php", query: ["api": action], body: payload, operationKey: key)
        guard let envelope = try? JSONDecoder().decode(NativeEnvelope<JSONObject>.self, from: bytes) else {
            throw NativeFailure("Resposta inválida ao salvar. Sincronize e confira antes de reenviar.", status: response.statusCode)
        }
        guard envelope.ok && (200..<300).contains(response.statusCode) else {
            if response.statusCode < 500 && envelope.data?.flag("operationPending") != true { pendingOperations.removeValue(forKey: fingerprint) }
            throw NativeFailure(envelope.message ?? "Não foi possível salvar.", status: response.statusCode, details: envelope.data)
        }
        pendingOperations.removeValue(forKey: fingerprint)
        var result = envelope.data ?? [:]
        if let message = envelope.message { result["message"] = .string(message) }
        return result
    }
    func download(id: String, name: String) async throws -> URL {
        let (bytes, response) = try await transport(file: "api.php", query: ["api": "org_download", "id": id])
        guard response.statusCode == 200, response.value(forHTTPHeaderField: "Content-Disposition") != nil else {
            throw NativeFailure("Não foi possível baixar o anexo. Atualize sua sessão.", status: response.statusCode)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAttachments").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = String((name as NSString).lastPathComponent.prefix(170))
        let target = folder.appendingPathComponent(clean.isEmpty || clean == "." || clean == ".." ? "Anexo" : clean)
        try bytes.write(to: target, options: [.atomic, .completeFileProtection])
        return target
    }
    func exportFinance(kind: String) async throws -> URL {
        let (bytes, response) = try await transport(file: "api.php", query: ["api": "export", "tipo": kind])
        guard response.statusCode == 200, response.value(forHTTPHeaderField: "Content-Disposition") != nil else { throw NativeFailure("Não foi possível exportar. Sincronize sua conta.", status: response.statusCode) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(kind == "meses" ? "SaldoLeve-meses.csv" : "SaldoLeve-lancamentos.csv")
        try bytes.write(to: file, options: [.atomic, .completeFileProtection]); return file
    }
}

enum NativeCache {
    private static let io = DispatchQueue(label: "SaldoLeve.cache", qos: .utility)
    private static let lock = NSLock()
    private static var latest: [String: UUID] = [:]
    static func enqueue(_ value: NativeLocalData, id: String, completion: @escaping (Bool) -> Void) {
        let token = UUID(); lock.lock(); latest[id] = token; lock.unlock()
        io.async {
            lock.lock(); let current = latest[id] == token; lock.unlock()
            guard current else { return }
            let success: Bool
            do { try write(value, id: id); success = true } catch { success = false }
            DispatchQueue.main.async { completion(success) }
        }
    }
    static func url(_ id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SaldoLeveNative", isDirectory: true).appendingPathComponent(id + ".json")
    }
    static func read(_ id: String) -> NativeLocalData? {
        guard let bytes = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(NativeLocalData.self, from: bytes)
    }
    static func write(_ value: NativeLocalData, id: String) throws {
        let target = url(id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var folder = target.deletingLastPathComponent()
        var options = URLResourceValues(); options.isExcludedFromBackup = true
        try folder.setResourceValues(options)
        try JSONEncoder().encode(value).write(to: target, options: [.atomic, .completeFileProtection])
    }
    static func remove(_ id: String) {
        lock.lock(); latest.removeValue(forKey: id); lock.unlock()
        io.sync { try? FileManager.default.removeItem(at: url(id)) }
    }
}
