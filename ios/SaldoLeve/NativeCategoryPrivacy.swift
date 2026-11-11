import SwiftUI

@MainActor
struct NativeCategoryGate: View {
    @ObservedObject var store: NativeStore
    let categoryID: String
    @State private var password = ""
    @State private var busy = false
    @State private var issue: String?
    @State private var recovery = false
    @State private var accountPassword = ""

    private var usesPassword: Bool { store.categoryProtection(categoryID).text("mode") == "password" }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: usesPassword ? "lock.shield" : "faceid")
                    .font(.largeTitle).foregroundStyle(nativeBlue).accessibilityHidden(true)
                Text("Categoria protegida").font(.title3.bold())
                if usesPassword {
                    SecureField("Senha da categoria", text: $password)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).submitLabel(.go).onSubmit { Task { await unlock() } }
                }
                Button(usesPassword ? "Desbloquear" : "Desbloquear com Face ID") {
                    Task { await unlock() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || usesPassword && password.isEmpty)
                if busy { ProgressView() }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if usesPassword {
                    Button("Esqueci a senha da categoria") { recovery = true }.font(.footnote)
                }
            }.frame(maxWidth: 340).padding(24).frame(maxWidth: .infinity)
        }
        .task(id: store.categoryProtection(categoryID).text("revision")) {
            if !usesPassword { await unlock() }
        }
        .alert("Redefinir proteção da categoria?", isPresented: $recovery) {
            SecureField("Senha da sua conta SaldoLeve", text: $accountPassword)
            Button("Cancelar", role: .cancel) { accountPassword = "" }
            Button("Redefinir") { Task { await recover() } }
        } message: { Text("Confirme a senha da sua conta para remover a senha esquecida desta categoria.") }
    }

    private func unlock() async {
        guard !busy, !usesPassword || !password.isEmpty else { return }
        busy = true; issue = nil
        defer { busy = false; password = "" }
        do { try await store.unlockCategory(categoryID, password: password) }
        catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
    private func recover() async {
        guard !busy else { return }
        busy = true; issue = nil
        defer { busy = false; accountPassword = "" }
        do { try await store.recoverCategoryProtection(categoryID, password: accountPassword) }
        catch { issue = error.localizedDescription }
    }
}

@MainActor
struct NativeCategoryPrivacySettings: View {
    @ObservedObject var store: NativeStore

    var body: some View {
        List {
            ForEach(store.snapshot.lists) { category in
                NavigationLink {
                    NativeCategoryPrivacyEditor(store: store, category: category)
                } label: {
                    LabeledContent(category.name, value: label(store.categoryProtection(category.id).text("mode")))
                }
            }
            if store.snapshot.lists.isEmpty { Text("Crie uma categoria em Tarefas para protegê-la.").foregroundStyle(.secondary) }
        }.navigationTitle("Privacidade das categorias").navigationBarTitleDisplayMode(.inline)
    }

    private func label(_ mode: String) -> String {
        switch mode {
        case "face": return "Face ID"
        case "password": return "Senha escrita"
        default: return "Sem proteção"
        }
    }
}

@MainActor
private struct NativeCategoryPrivacyEditor: View {
    @ObservedObject var store: NativeStore
    let category: NativeCategory
    @Environment(\.dismiss) private var dismiss
    @State private var original: JSONObject = [:]
    @State private var mode = "none"
    @State private var password = ""
    @State private var confirmation = ""
    @State private var currentPassword = ""
    @State private var busy = false
    @State private var issue: String?

    private var previousMode: String { original["mode"]?.string ?? "none" }
    private var canSave: Bool {
        store.canWrite && !busy && (mode != previousMode || mode == "password" && !password.isEmpty)
            && (previousMode != "password" || !currentPassword.isEmpty)
            && (mode != "password" || !password.isEmpty && password == confirmation)
    }

    var body: some View {
        Form {
            Picker("Desbloquear com", selection: $mode) {
                Text("Sem proteção").tag("none")
                Text("Face ID").tag("face")
                Text("Senha escrita").tag("password")
            }
            if previousMode == "password" {
                SecureField("Senha atual da categoria", text: $currentPassword).textContentType(.password)
            }
            if mode == "password" {
                Section {
                    SecureField("Nova senha", text: $password).textContentType(.newPassword)
                    SecureField("Repita a nova senha", text: $confirmation).textContentType(.newPassword)
                } footer: {
                    Text("Use pelo menos 6 caracteres, incluindo uma letra ou um símbolo. O app confere essa senha pela internet.")
                }
            }
            if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
            Button(busy ? "Salvando…" : "Salvar proteção") { Task { await save() } }
                .disabled(!canSave)
        }
        .navigationTitle(category.name).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            original = store.categoryProtection(category.id)
            mode = previousMode
        }
    }

    private func save() async {
        guard canSave else { return }
        busy = true; issue = nil
        defer { busy = false }
        do {
            if mode == "face" || previousMode == "face" { try await NativeStore.authenticateCategoryWithFaceID() }
            try await store.saveCategoryProtection(category.id, mode: mode, revision: original.text("revision"),
                password: mode == "password" ? password : "", currentPassword: currentPassword)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
