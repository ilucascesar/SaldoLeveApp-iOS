import SwiftUI

@MainActor
struct NativeTaskGate: View {
    @ObservedObject var store: NativeStore
    let taskID: String
    @State private var password = ""
    @State private var busy = false
    @State private var issue: String?
    @State private var recovery = false
    private var usesPassword: Bool { store.taskProtection(taskID).text("mode") == "password" }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: usesPassword ? "lock.shield" : "faceid").font(.largeTitle).foregroundStyle(nativeBlue).accessibilityHidden(true)
                Text(store.taskByID(taskID)?.title ?? "Tarefa protegida").font(.title3.bold())
                Text("Desbloqueie para ver o conteúdo.").foregroundStyle(.secondary)
                if usesPassword {
                    SecureField("Senha desta tarefa", text: $password)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).submitLabel(.go).onSubmit { Task { await unlock() } }
                }
                Button(usesPassword ? "Desbloquear" : "Desbloquear com Face ID") { Task { await unlock() } }
                    .buttonStyle(.borderedProminent).disabled(busy || usesPassword && password.isEmpty)
                if busy { ProgressView() }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Button("Esqueci a senha / redefinir proteção") { recovery = true }.font(.footnote).disabled(busy)
            }.frame(maxWidth: 340).padding(24).frame(maxWidth: .infinity)
        }
        .task(id: store.taskProtection(taskID).text("revision")) { if !usesPassword { await unlock() } }
        .sheet(isPresented: $recovery) { NavigationStack { NativeTaskPasswordRecovery(store: store, taskID: taskID) } }
    }
    private func unlock() async {
        guard !busy, !usesPassword || !password.isEmpty else { return }
        busy = true; issue = nil
        defer { busy = false; password = "" }
        do { try await store.unlockTask(taskID, password: password) }
        catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
}

@MainActor
struct NativeTaskPasswordRecovery: View {
    @ObservedObject var store: NativeStore
    let taskID: String
    @Environment(\.dismiss) private var dismiss
    @State private var accountPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var issue: String?
    var body: some View {
        Form {
            Section {
                SecureField("Senha da conta SaldoLeve", text: $accountPassword).textContentType(.password)
            } footer: { Text("Confirme sua identidade com a senha usada para entrar no SaldoLeve. Só a proteção desta tarefa será redefinida; seu conteúdo será preservado.") }
            Section("Nova senha desta tarefa") {
                SecureField("Nova senha escrita", text: $password).textContentType(.newPassword)
                SecureField("Repita a nova senha", text: $confirmation).textContentType(.newPassword)
            }
            Text("Use pelo menos 6 caracteres, incluindo uma letra ou um símbolo.").font(.footnote).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.red) }
            Button(busy ? "Redefinindo…" : "Redefinir senha") { Task { await recover() } }
                .disabled(!store.canWrite || busy || accountPassword.isEmpty || password.isEmpty || password != confirmation)
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("Redefinir senha").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
    }
    private func recover() async {
        busy = true; issue = nil
        defer { busy = false; accountPassword = "" }
        do {
            try await store.recoverTaskProtection(taskID, password: accountPassword, newPassword: password)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

@MainActor
struct NativeTaskPrivacyEditor: View {
    @ObservedObject var store: NativeStore
    let task: NativeTask
    @Environment(\.dismiss) private var dismiss
    @State private var original: JSONObject = [:]
    @State private var mode = "password"
    @State private var password = ""
    @State private var confirmation = ""
    @State private var currentPassword = ""
    @State private var busy = false
    @State private var issue: String?
    @State private var recovery = false
    private var previousMode: String { original["mode"]?.string ?? "none" }
    private var canSave: Bool {
        store.canWrite && !busy && (mode != previousMode || mode == "password" && !password.isEmpty)
            && (previousMode != "password" || !currentPassword.isEmpty)
            && (mode != "password" || !password.isEmpty && password == confirmation)
    }
    var body: some View {
        Form {
            Section { Text(task.title).font(.headline) } footer: { Text("Esta proteção vale apenas para esta tarefa. O título continua visível na lista; o conteúdo fica oculto até desbloquear.") }
            Picker("Desbloquear com", selection: $mode) {
                Text("Sem proteção").tag("none")
                Text("Senha escrita").tag("password")
                Text("Face ID").tag("face")
            }
            if previousMode == "password" {
                SecureField("Senha atual desta tarefa", text: $currentPassword).textContentType(.password)
            }
            if mode == "password" {
                Section {
                    SecureField("Nova senha escrita", text: $password).textContentType(.newPassword)
                    SecureField("Repita a nova senha", text: $confirmation).textContentType(.newPassword)
                } footer: { Text("Use pelo menos 6 caracteres, incluindo uma letra ou símbolo. O desbloqueio usa somente esta senha escrita, sem PIN do aparelho.") }
            }
            if mode == "face" { Text("Usa somente o Face ID deste iPhone.").font(.footnote).foregroundStyle(.secondary) }
            if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
            Button(busy ? "Salvando…" : "Salvar proteção") { Task { await save() } }.disabled(!canSave)
            if !original.isEmpty { Button("Esqueci a senha / redefinir proteção") { recovery = true }.disabled(busy) }
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("Proteção da tarefa").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
        .onAppear { reloadProtection() }
        .sheet(isPresented: $recovery, onDismiss: { reloadProtection() }) { NavigationStack { NativeTaskPasswordRecovery(store: store, taskID: task.id) } }
    }
    private func reloadProtection() {
        original = store.taskProtection(task.id)
        mode = original.isEmpty ? "password" : previousMode
        password = ""; confirmation = ""; currentPassword = ""
    }
    private func save() async {
        guard canSave else { return }
        busy = true; issue = nil
        defer { busy = false }
        do {
            if mode == "face" || previousMode == "face" { try await NativeStore.authenticateTaskWithFaceID() }
            try await store.saveTaskProtection(task.id, mode: mode, revision: original.text("revision"), password: mode == "password" ? password : "", currentPassword: currentPassword)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
