import SwiftUI

struct NativeUserAdministration: View {
    @ObservedObject var store: NativeStore
    @State private var users: [NativeRecord] = []
    @State private var name = ""
    @State private var login = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var mustChange = true
    @State private var working = false
    @State private var issue: String?
    @State private var status = ""
    @State private var allowed = false
    var body: some View {
        Form {
            if allowed {
                Section("Criar usuário") {
                    TextField("Nome", text: $name).textContentType(.name)
                    TextField("Usuário", text: $login).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Senha", text: $password).textContentType(.newPassword)
                    SecureField("Confirmar senha", text: $confirmation).textContentType(.newPassword)
                    Toggle("Trocar a senha no primeiro acesso", isOn: $mustChange)
                    Button("Criar usuário") { Task { await create() } }.disabled(!store.canWrite || working || name.trimmingCharacters(in: .whitespaces).isEmpty || login.isEmpty || password.utf8.count < 4 || password != confirmation)
                }
                Section("Usuários cadastrados") {
                    ForEach(users) { user in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.fields.text("name")).font(.headline)
                            Text(user.fields.text("login")).font(.caption).foregroundStyle(.secondary)
                            Text(!user.fields.flag("active") ? "Inativo" : user.fields.flag("mustChangePassword") ? "Troca de senha no primeiro acesso" : "Ativo").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if working { ProgressView() }
            if !status.isEmpty { Text(status).foregroundStyle(.green) }
            if let issue { Text(issue).foregroundStyle(.red) }
        }.navigationTitle("Usuários").navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
    }
    private func load() async {
        do { let result = try await store.api.get(JSONObject.self, action: "admin_users"); users = result.objects("users").map(NativeRecord.init); allowed = true; issue = nil }
        catch { allowed = false; issue = error.localizedDescription }
    }
    private func create() async {
        guard !working else { return }; working = true; issue = nil; status = ""; defer { working = false }
        do {
            let result = try await store.api.post(action: "admin_create_user", body: ["name": .string(name), "login": .string(login), "password": .string(password), "confirm": .string(confirmation), "mustChangePassword": .bool(mustChange)])
            users = result.objects("users").map(NativeRecord.init); name = ""; login = ""; password = ""; confirmation = ""; status = result.text("message")
            if status.isEmpty { status = "Usuário criado no servidor." }
        } catch { issue = error.localizedDescription }
    }
}

struct NativePasswordChange: View {
    @ObservedObject var store: NativeStore
    @State private var current = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var issue: String?
    @State private var status = ""
    var body: some View {
        Form {
            Section("Trocar senha") {
                SecureField("Senha atual", text: $current).textContentType(.password)
                SecureField("Nova senha", text: $password).textContentType(.newPassword)
                SecureField("Confirmar nova senha", text: $confirmation).textContentType(.newPassword)
                Button(working ? "Salvando…" : "Salvar nova senha") { Task { await save() } }.disabled(!store.canWrite || working || current.isEmpty || password.utf8.count < 4 || password != confirmation)
            }
            if !status.isEmpty { Text(status).foregroundStyle(.green) }
            if let issue { Text(issue).foregroundStyle(.red) }
        }.disabled(working).navigationTitle("Trocar senha").navigationBarTitleDisplayMode(.inline)
    }
    private func save() async {
        guard !working else { return }; working = true; issue = nil; status = ""; defer { working = false }
        do { try await store.changePassword(current: current, new: password, confirm: confirmation); current = ""; password = ""; confirmation = ""; status = "Senha alterada no servidor." }
        catch { issue = error.localizedDescription }
    }
}
