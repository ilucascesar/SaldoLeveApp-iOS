import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let context = extensionContext else { return }
        let view = ReceiptShareView(context: context) { [weak self] title, message, accept in
            guard let self else { return false }
            return await self.confirm(title: title, message: message, accept: accept)
        }
        let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "pt_BR")))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    private func confirm(title: String, message: String, accept: String) async -> Bool {
        guard view.window != nil else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Revisar", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: accept, style: .default) { _ in continuation.resume(returning: true) })
            present(alert, animated: true)
        }
    }
}

private struct ReceiptTask: Decodable, Identifiable {
    let id: String
    let title: String
    let category: String
}

private struct ReceiptTaskPage: Decodable {
    let items: [ReceiptTask]
    let next: String
}

private struct ReceiptDestination {
    let task: NativeTask
    let check: NativeCheck
    let category: String

    var canComplete: Bool { task.isActive && !task.paused && !check.done && !check.paused }

    func completing(with installment: NativeInstallmentDraft) throws -> JSONObject {
        guard canComplete else { throw NativeFailure("Esta subtarefa já está concluída ou precisa ser retomada no SaldoLeve.") }
        if task.usesManualPayment(check) { return try installment.applying(to: task).fields }
        var fields = task.fields
        fields["checklist"] = .array(task.checks.map { item in
            var checkFields = item.fields
            if item.id == check.id { checkFields["done"] = .bool(true) }
            return .object(checkFields)
        })
        return fields
    }
}

@MainActor private struct ReceiptShareView: View {
    let context: NSExtensionContext
    let confirm: @MainActor (String, String, String) async -> Bool
    @State private var api: NativeAPI?
    @State private var receipt: SharedReceipt?
    @State private var account: NativeIdentity?
    @State private var username = ""
    @State private var password = ""
    @State private var changingPassword = false
    @State private var tasks: [ReceiptTask] = []
    @State private var query = ""
    @State private var loadedQuery = ""
    @State private var next = ""
    @State private var task: NativeTask?
    @State private var category = ""
    @State private var selection: ReceiptDestination?
    @State private var attached: ReceiptDestination?
    @State private var installment = NativeInstallmentDraft()
    @State private var working = false
    @State private var started = false
    @State private var uploadUnconfirmed = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                if let receipt { Section { Label(receipt.name, systemImage: "paperclip").lineLimit(2) } }
                if let attached { afterAttachment(attached) }
                else if let selection { destinationReview(selection) }
                else if let task { checklist(task) }
                else if let account { taskPicker(account) }
                else if receipt != nil && api != nil { loginForm }
                else if issue != nil { Button("Tentar novamente") { prepare() } }
                if working { ProgressView(attached == nil ? "Aguarde…" : "Salvando…") }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .disabled(working)
            .navigationTitle("Anexar comprovante")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(attached == nil ? "Cancelar" : "Fechar") { finish() }.disabled(working)
                }
            }
        }
        .task {
            guard !started else { return }
            started = true
            prepare()
        }
    }

    private var loginForm: some View {
        Section(changingPassword ? "Atualize sua senha" : "Entre no SaldoLeve") {
            if !changingPassword {
                TextField("Usuário", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            SecureField(changingPassword ? "Nova senha" : "Senha", text: $password)
                .textContentType(changingPassword ? .newPassword : .password)
            Button(changingPassword ? "Salvar senha e entrar" : "Entrar") { signIn() }
                .disabled(password.isEmpty || (!changingPassword && username.trimmingCharacters(in: .whitespaces).isEmpty))
            Text("O primeiro acesso salva sua sessão para os próximos compartilhamentos.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func taskPicker(_ identity: NativeIdentity) -> some View {
        Group {
            Section {
                LabeledContent("Conta", value: identity.login)
                Button("Trocar conta") { signOut() }
            }
            Section("Escolha a tarefa") {
                TextField("Buscar tarefa, subtarefa ou categoria", text: $query).submitLabel(.search)
                    .onSubmit { search() }
                Button("Buscar") { search() }
                ForEach(tasks) { row in
                    Button { open(row) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).foregroundStyle(.primary)
                            Text(row.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if tasks.isEmpty && !working { Text("Nenhuma tarefa encontrada nesta página.").foregroundStyle(.secondary) }
                if !next.isEmpty { Button("Buscar em mais tarefas") { run { try await loadTasks(reset: false) } } }
            }
        }
    }

    private func checklist(_ task: NativeTask) -> some View {
        Section("Escolha a subtarefa") {
            Button("Voltar às tarefas") { self.task = nil; issue = nil }
            Text(task.title).font(.headline)
            ForEach(task.checks) { check in
                Button {
                    selection = ReceiptDestination(task: task, check: check, category: category)
                    issue = nil
                } label: { checkLabel(check) }
            }
        }
    }

    private func checkLabel(_ check: NativeCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(check.title).foregroundStyle(.primary)
            if let date = check.date {
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            if check.done { Text("Concluída").font(.caption).foregroundStyle(.green) }
        }
    }

    private func destinationReview(_ destination: ReceiptDestination) -> some View {
        Section("Destino do comprovante") {
            Text("\(destination.category) · \(destination.task.title)").font(.caption).foregroundStyle(.secondary)
            checkLabel(destination.check)
            Button(uploadUnconfirmed ? "Conferir o envio" : "Anexar comprovante") { upload(destination) }
            Button("Escolher outra subtarefa") { selection = nil; issue = nil }.disabled(uploadUnconfirmed)
            Button("Atualizar tarefa") {
                run {
                    try await openTask(id: destination.task.id, category: destination.category)
                    selection = nil
                }
            }.disabled(uploadUnconfirmed)
        }
    }

    private func afterAttachment(_ destination: ReceiptDestination) -> some View {
        Group {
            Section {
                Label("Comprovante anexado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(destination.task.title).font(.caption).foregroundStyle(.secondary)
                checkLabel(destination.check)
            }
            if destination.canComplete {
                Section("Quer concluir esta subtarefa?") {
                    if destination.task.usesManualPayment(destination.check) {
                        let id = destination.check.id
                        TextField("Valor original (R$)", text: Binding(get: { installment.originals[id] ?? "" }, set: { installment.setOriginal($0, id: id) })).keyboardType(.decimalPad)
                        TextField(destination.task.moneyMode == "receive" ? "Valor recebido (R$)" : "Valor pago (R$)", text: Binding(get: { installment.paid[id] ?? "" }, set: { installment.setPaid($0, id: id) })).keyboardType(.decimalPad)
                    }
                    Button("Marcar como concluída") { complete(destination) }
                    Button("Deixar pendente") { finish() }
                }
            } else {
                Section { Button("Concluir compartilhamento") { finish() } }
            }
        }
    }

    private func prepare() {
        run {
            if receipt == nil { receipt = try await SharedReceipt.read(from: context) }
            let config = Bundle.main.url(forResource: "config", withExtension: "json")
            guard let config, let fields = try? JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: config)),
                  let address = SiteAddress(fields.text("serverURL")) else { throw NativeFailure("O endereço do SaldoLeve não está configurado.") }
            let client = NativeAPI(address: address, deviceName: "SaldoLeve · Compartilhar comprovantes", credentialNamespace: "|receipts")
            let presentConfirmation = confirm
            client.reviewDuplicate = { names in
                await presentConfirmation("Possível cobrança duplicada", names, "Salvar mesmo assim")
            }
            client.reviewWarnings = { warnings in
                let lines = warnings.map { $0.text("message") }.joined(separator: "\n\n")
                return await presentConfirmation("Confira antes de salvar", lines, "Confirmar")
            }
            api = client
            try await useSession(client.restore())
        }
    }

    private func useSession(_ session: NativeSession) async throws {
        changingPassword = session.requiresPasswordChange
        account = session.authenticated ? session.user : nil
        if account != nil { try await loadTasks(reset: true) }
    }

    private func signIn() {
        guard let api else { return }
        let entered = password
        password = ""
        run { try await useSession(api.login(user: username, password: entered, changingPassword: changingPassword)) }
    }

    private func signOut() {
        guard let api else { return }
        run {
            try await api.logout()
            account = nil
            tasks = []
            next = ""
            username = ""
        }
    }

    private func search() { run { try await loadTasks(reset: true) } }

    private func loadTasks(reset: Bool) async throws {
        guard let api else { return }
        if reset {
            tasks = []
            next = ""
            loadedQuery = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }
        var parameters = ["q": loadedQuery]
        if !next.isEmpty { parameters["before"] = next }
        let page = try await api.get(ReceiptTaskPage.self, action: "org_receipt_targets", query: parameters)
        tasks.append(contentsOf: page.items)
        next = page.next
    }

    private func open(_ row: ReceiptTask) { run { try await openTask(id: row.id, category: row.category) } }

    private func openTask(id: String, category: String) async throws {
        guard let api else { return }
        let details = try await api.get(JSONObject.self, action: "org_item", query: ["id": id])
        let current = NativeTask(details.record("item"))
        guard (current.isActive || current.isDone) && !current.checks.isEmpty else {
            throw NativeFailure("Esta tarefa não tem subtarefas disponíveis. Volte à busca e escolha outra.")
        }
        task = current
        self.category = category
    }

    private func upload(_ destination: ReceiptDestination) {
        guard let api, let receipt else { return }
        run {
            do {
                uploadUnconfirmed = true
                _ = try await api.post(action: "org_attach_receipt", body: [
                    "itemId": .string(destination.task.id), "checkId": .string(destination.check.id),
                    "revision": .number(Double(destination.task.revision)), "name": .string(receipt.name),
                    "type": .string(receipt.type), "base64": .string(receipt.data.base64EncodedString())
                ])
                uploadUnconfirmed = false
                attached = destination
                installment = NativeInstallmentDraft(destination.task, checkID: destination.check.id)
            } catch {
                if let failure = error as? NativeFailure, (400..<500).contains(failure.status), failure.details?.flag("operationPending") != true {
                    uploadUnconfirmed = false
                }
                throw error
            }
        }
    }

    private func complete(_ destination: ReceiptDestination) {
        guard let api else { return }
        run {
            let fields = try destination.completing(with: installment)
            _ = try await api.post(action: "org_save_item", body: fields)
            finish()
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        issue = nil
        Task {
            defer { working = false }
            do { try await operation() }
            catch {
                if let failure = error as? NativeFailure, [401, 419, 428].contains(failure.status), attached == nil {
                    api?.clearSession()
                    account = nil
                    selection = nil
                    task = nil
                    uploadUnconfirmed = false
                }
                issue = error.localizedDescription
            }
        }
    }

    private func finish() {
        if attached != nil { context.completeRequest(returningItems: nil) }
        else { context.cancelRequest(withError: CocoaError(.userCancelled)) }
    }
}
