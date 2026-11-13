import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import UIKit

struct NativeRecord: Identifiable {
    let fields: JSONObject
    var id: String { fields.text("id") }
}

@MainActor
struct NativeTaskEditor: View {
    @ObservedObject var store: NativeStore
    let original: NativeTask
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var task: NativeTask
    @State private var baseline: NativeTask
    @State private var loading = true
    @State private var saved = false
    @State private var saving = false
    @State private var attachments: [NativeRecord] = []
    @State private var comments: [NativeRecord] = []
    @State private var comment = ""
    @State private var receiptTarget: NativeReceiptTarget?
    @State private var receiptPreview: URL?
    @State private var receiptIssue: String?
    @State private var loadingReceipt = false
    @State private var privacy = false
    @State private var history = false
    @State private var suggestions = false
    @State private var valuesRecord: NativeRecord?
    @State private var shared: NativeSharedFile?
    @State private var checklistShare: String?
    @State private var checklistScroll = NativeChecklistScroll()
    @State private var failure: String?
    @State private var removingCheck: String?
    @State private var pauseMenu = false
    @State private var remindersOptions = false
    @State private var locationOptions = false
    private var locationLabel: String {
        guard let reminder = NativeLocationReminder(task.fields) else { return "Local" }
        let name = NativePlace.list(store.platform.snapshot.config).first { $0.id == reminder.placeID }?.name ?? "Local"
        return (reminder.trigger == "leave" ? "Ao sair de " : "Ao chegar em ") + name
    }
    @State private var showComments = false
    @State private var reordering = false
    @State private var trashConfirm = false
    @State private var newCheck = ""
    @FocusState private var newCheckFocused: Bool
    @State private var newCheckID = UUID().uuidString
    @State private var closing = false
    @State private var saveStatus = ""
    @State private var autosave: Task<Void, Never>?
    @State private var transitionSave: Task<Void, Never>?
    @State private var syncNotice: String?
    @State private var reloading = false
    @State private var serverReady = false
    @State private var discardConfirm = false
    @State private var movingCheck: String?
    @State private var transferTarget: NativeTask?
    @State private var installmentGenerator = false
    @State private var installmentSelection: NativeInstallmentSelection?
    @State private var collapsedGroups: Set<String>
    init(store: NativeStore, original: NativeTask) {
        self.store = store; self.original = original
        let current = store.snapshot.items.first(where: { $0.id == original.id }) ?? original
        _task = State(initialValue: current)
        _baseline = State(initialValue: current)
        _serverReady = State(initialValue: !store.editorSyncEnabled)
        _collapsedGroups = State(initialValue: store.layout.forTaskCategory(current.categoryID).taskDetailExpandDone ? [] : ["done"])
    }
    private var detailLayout: NativeLayoutPreferences { store.layout.forTaskCategory(task.categoryID) }
    private var taskLocked: Bool { store.taskLocked(task.id) }
    private var editable: Bool { !taskLocked && serverReady && store.networkAvailable && !store.offline && !store.needsSync && !reloading && store.snapshot.lists.first(where: { $0.id == task.categoryID })?.canEdit == true && task.status != "trashed" }
    private var repeating: Binding<Bool> {
        Binding(get: { task.fields["repeat"]?.object.text("frequency") == "monthly" }, set: { value in
            task.fields["repeat"] = .object(["frequency": .string(value ? "monthly" : "none"), "interval": .number(1)])
        })
    }
    var body: some View {
        Group {
        if taskLocked {
            NavigationStack {
                NativeTaskGate(store: store, taskID: task.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
            }
        } else {
            editor
        }
        }
        .sheet(isPresented: $privacy) { NavigationStack { NativeTaskPrivacyEditor(store: store, task: task) } }
        .onDisappear { store.relockTasks(task.id) }
    }
    private var editor: some View {
        NavigationStack {
            synchronizedList
            .navigationTitle(task.id.isEmpty ? "Adicionar tarefa" : store.category(task)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { close() }.disabled(saving || loading) }
                ToolbarItem(placement: .confirmationAction) { if editable { Button(task.id.isEmpty ? "Adicionar" : "Salvar") { save() }.bold().disabled(saving || loading || store.working || task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { openReceipts() } label: { Image(systemName: "paperclip").frame(width: 38, height: 40) }.disabled(task.id.isEmpty || saving || loading).accessibilityLabel("Anexos e comprovantes")
                    Button { history = true } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 38, height: 40) }.disabled(task.id.isEmpty || saving || loading).accessibilityLabel("Histórico")
                    Button { Task {
                        addCheck()
                        autosave?.cancel()
                        guard newCheck.isEmpty, await commit(closing: false) else { return }
                        privacy = true
                    } } label: { Image(systemName: "lock.shield").frame(width: 38, height: 40) }
                        .accessibilityLabel("Proteção da tarefa").disabled(task.id.isEmpty || saving || loading || !editable)
                    Menu {
                        Button { exportChecklist(share: false) } label: { Label("Copiar lista de subtarefas", systemImage: "doc.on.doc") }
                        Button { exportChecklist(share: true) } label: { Label("Compartilhar lista de subtarefas", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 38, height: 40) }
                        .accessibilityLabel("Exportar lista de subtarefas").disabled(task.checks.isEmpty && newCheck.isEmpty || loading || saving)
                    Spacer()
                    Text(!serverReady || store.offline ? "Somente consulta" : saving ? "Salvando no servidor…" : task == baseline ? "" : "Ainda não salvo").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $installmentGenerator) { NativeInstallmentGenerator(task: $task) }
            .sheet(item: $installmentSelection) { selection in NativeInstallmentPayment(task: Binding(get: { task }, set: replaceTask), initialCheckID: selection.checkID, commit: { autosave?.cancel(); return await commit(closing: false) }) }
            .sheet(item: $receiptTarget) { target in
                NativeTaskReceipts(store: store, target: target, onFilesChanged: { attachments = $0 }, onAttached: { flash("Comprovante anexado") })
            }
            .quickLookPreview($receiptPreview)
            .onChange(of: receiptPreview) { [receiptPreview] next in
                if let receiptPreview, receiptPreview != next { try? FileManager.default.removeItem(at: receiptPreview.deletingLastPathComponent()) }
            }
            .alert("Comprovante", isPresented: Binding(get: { receiptIssue != nil }, set: { if !$0 { receiptIssue = nil } })) {
                Button("OK") { receiptIssue = nil }
            } message: { Text(receiptIssue ?? "") }
            .sheet(isPresented: $remindersOptions) { NativeReminderOptions(fields: $task.fields) }
            .sheet(isPresented: $locationOptions) { NativeTaskLocationSheet(fields: $task.fields, store: store) }
            .sheet(isPresented: $reordering) { reorderSheet }
            .sheet(isPresented: Binding(get: { movingCheck != nil }, set: { if !$0 { movingCheck = nil } })) { transferSheet }
            .sheet(isPresented: $suggestions) { NativeSmartSuggestions(store: store, context: "task", text: task.title, excludeID: task.id) { values in
                Task { await applySuggestions(values) }
            } }
            .sheet(item: $valuesRecord) { record in NativeCheckValues(store: store, taskID: task.id, checkID: record.id) { Task { await reload() } } }
            .sheet(isPresented: $history) { NativeHistoryView(store: store, taskID: task.id) }
            .sheet(item: $shared) { NativeShareSheet(items: [$0.url]) }
            .sheet(isPresented: Binding(get: { checklistShare != nil }, set: { if !$0 { checklistShare = nil } })) {
                if let checklistShare { NativeShareSheet(items: [checklistShare]) }
            }
            .alert("Não foi possível concluir", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("Continuar editando") { failure = nil }
                Button("Fechar sem salvar", role: .destructive) { saved = true; dismiss() }
            } message: { Text(failure ?? "") }
            .confirmationDialog("Há alterações não confirmadas no servidor. Descartar e fechar?", isPresented: $discardConfirm, titleVisibility: .visible) { Button("Descartar e fechar", role: .destructive) { saved = true; dismiss() } }
            .confirmationDialog("Mover tarefa para a lixeira?", isPresented: $trashConfirm, titleVisibility: .visible) { Button("Mover para a lixeira", role: .destructive) { task.fields["status"] = .string("trashed"); save() } }
            .confirmationDialog("Remover subtarefa ao salvar?", isPresented: Binding(get: { removingCheck != nil }, set: { if !$0 { removingCheck = nil } }), titleVisibility: .visible) { Button("Remover subtarefa", role: .destructive) { task.fields["checklist"] = .array(task.checks.filter { $0.id != removingCheck }.map { .object($0.fields) }); removingCheck = nil } }
            .confirmationDialog(task.paused ? "Retomar a cobrança?" : "Por quantos meses deseja pausar?", isPresented: $pauseMenu, titleVisibility: .visible) { if task.paused { Button("Retomar agora") { pause(months: 0, resume: true) } } else { ForEach([1, 2, 3, 6, 12], id: \.self) { months in Button("Pausar \(months) mês(es)") { pause(months: months, resume: false) } } } }
        }
    }
    private var editorList: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                if loading { ProgressView("Carregando detalhes…") }
                #if DEBUG
                if store.isPreview && store.editorSyncEnabled {
                    Text("Envios ao servidor: \(store.syncFixtureWrites)").accessibilityIdentifier("sync-write-count")
                    if ProcessInfo.processInfo.arguments.contains("--preview-sync-live") {
                        Button("Simular alteração no computador") { Task { await store.simulateServerUpdate() } }.accessibilityIdentifier("test-server-change")
                    }
                }
                #endif
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        guard !task.id.isEmpty else { return }
                        if !task.isDone, let next = task.nextPendingCheck, task.usesManualPayment(next) { openPayment(next.id); return }
                        Task { if await commit(closing: false) { await store.complete(task); await reload() } }
                    } label: { Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle").font(.system(size: 25, weight: .light)).frame(width: 30, height: 40) }.disabled(task.id.isEmpty || !editable || saving || !store.canWrite).accessibilityLabel(task.isDone ? "Reabrir tarefa" : task.completionLabel)
                    TextField("O que precisa ser feito?", text: text("title"), axis: .vertical).font(.system(size: 23, weight: .semibold)).lineLimit(1...6).disabled(!editable || loading || closing).accessibilityIdentifier("task-title")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        if !task.checks.contains(where: { $0.date != nil }) { NativeDateChip(fields: $task.fields, enabled: editable && !saving) }
                        Menu {
                            if task.id.isEmpty { ForEach(store.editableCategories) { category in Button(category.name) { task.fields["listId"] = .string(category.id) } } }
                            else {
                                ForEach(store.editableCategories.filter { entry in entry.fields.text("ownerId") == store.user?.id && store.snapshot.lists.first(where: { $0.id == task.categoryID })?.fields.text("ownerId") == store.user?.id }) { entry in Button(entry.name) { move(to: entry.id) } }
                            }
                        } label: { NativeChip(title: store.category(task), icon: "circle.fill", color: Color(nativeHex: store.snapshot.lists.first(where: { $0.id == task.categoryID })?.fields.text("color") ?? "#1f6feb")) }.disabled(!editable || saving)
                        Button { remindersOptions = true } label: { NativeChip(title: reminderLabel, icon: "alarm", active: task.fields["repeat"]?.object.text("frequency") == "monthly") }.disabled(!editable || saving)
                        Button { locationOptions = true } label: { NativeChip(title: locationLabel, icon: "location", active: NativeLocationReminder(task.fields) != nil) }.disabled(!editable || saving).accessibilityIdentifier("task-location")
                    }.padding(.vertical, 3)
                }
                TextField("Descrição ou anotações…", text: text("body"), axis: .vertical).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2...14).disabled(!editable || loading || closing)
                if let pending = task.pendingAmount { NativeTaskPendingAmount(amount: pending) }
                if let syncNotice {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(syncNotice, systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("task-sync-notice")
                        Button("Atualizar do servidor") { Task { await retrySync() } }.font(.footnote.bold()).disabled(saving || reloading || !store.networkAvailable)
                        Button("Fechar") { close() }.font(.footnote)
                    }.buttonStyle(.borderless).padding(.vertical, 6)
                }
            }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            checklistSection
            if showComments || !comments.isEmpty { commentsSection }
            Section {
                DisclosureGroup {
                    Button("Gerar parcelas ou série") { installmentGenerator = true }.disabled(!editable || saving)
                    if task.checks.contains(where: task.usesManualPayment) { Button { openPayment() } label: { Label("Pagar / antecipar parcelas", systemImage: "creditcard") }.disabled(!editable || saving || !store.canWrite) }
                    NativeDateField(fields: $task.fields, key: "startAt", title: "Início")
                    Toggle("Fixar no início", isOn: flag("pinned"))
                    TextField("Etiquetas, separadas por vírgula", text: Binding(get: { task.tags.joined(separator: ", ") }, set: { task.fields["tags"] = .array($0.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")) }) }))
                    Picker("Atribuir a", selection: text("assignedTo")) {
                        Text("Ninguém").tag("")
                        ForEach(store.snapshot.users.map(NativeRecord.init)) { Text($0.fields.text("name")).tag($0.id) }
                    }
                    if !task.id.isEmpty, task.fields["repeat"]?.object.text("frequency") == "monthly", task.isActive {
                        Button(task.paused ? "Retomar cobrança" : "Pausar cobrança") { pauseMenu = true }.disabled(!store.canWrite || task != baseline || saving)
                    }
                    if !task.id.isEmpty {
                        Button("Comentários") { showComments.toggle() }
                        Button("Duplicar tarefa") { Task { if await commit(closing: false) { await store.duplicate(task) } } }.disabled(saving || !store.canWrite)
                        ShareLink(item: ([task.title, task.fields.text("body")] + task.checks.map { ($0.done ? "☑ " : "☐ ") + $0.title }).joined(separator: "\n")) { Label("Compartilhar tarefa", systemImage: "square.and.arrow.up") }
                        Button(task.status == "archived" ? "Desarquivar tarefa" : "Arquivar tarefa") { task.fields["status"] = .string(task.status == "archived" ? "todo" : "archived"); save() }.disabled(saving)
                        Button("Mover para a lixeira", role: .destructive) { trashConfirm = true }.disabled(saving)
                    }
                } label: { Text("Mais opções").accessibilityIdentifier("task-more-options") }.font(.system(size: 14))
            }.disabled(!editable || loading || closing)
            if store.offline || !store.networkAvailable { Text("Sem conexão com o servidor. Somente consulta: não é possível editar ou salvar.").font(.footnote).foregroundStyle(.orange).listRowSeparator(.hidden) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(nativePaper).scrollDismissesKeyboard(.interactively)
        .task(id: loading) {
            guard !loading, let id = store.highlightedCheckID, task.checks.contains(where: { $0.id == id }) else { return }
            collapsedGroups = []
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        }
    }
    private var synchronizedList: some View {
        editorList
        .overlay(alignment: .bottomTrailing) {
            if !saveStatus.isEmpty {
                Label(saveStatus, systemImage: saving ? "arrow.triangle.2.circlepath" : "checkmark")
                    .font(.caption2).foregroundStyle(.secondary).padding(7)
                    .background(.regularMaterial, in: Capsule()).padding(8).allowsHitTesting(false)
                    .accessibilityIdentifier("task-save-status")
            }
        }
        .interactiveDismissDisabled(editable && (task != baseline || task.id.isEmpty && !task.title.isEmpty) || saving || !newCheck.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .task {
            if task.id.isEmpty {
                if !store.isPreview { await store.refresh() }
                serverReady = store.canWrite
            } else if store.editorSyncEnabled { await reload() }
            loading = false
            if store.paymentTaskID == task.id {
                store.paymentTaskID = nil
                if editable, let next = task.nextPendingCheck, task.usesManualPayment(next) { openPayment(next.id) }
            }
        }
        .onChange(of: task) { value in
            if !loading && !saved && editable && value != baseline { saveStatus = "Alterações ainda não salvas no servidor"; scheduleAutosave() }
        }
        .onChange(of: newCheck) { value in if !value.isEmpty { saveStatus = "Subtarefa ainda não salva no servidor" } }
        .onDisappear { autosave?.cancel() }
        .onChange(of: store.offline) { offline in if offline { connectionLost() } }
        .onChange(of: store.networkAvailable) { available in if !available { connectionLost() } }
        .onChange(of: store.syncedAt) { _ in
            guard !saving, !loading, !reloading, !task.id.isEmpty else { return }
            if let remote = store.snapshot.items.first(where: { $0.id == task.id }), !serverReady || remote != baseline {
                let pending = task != baseline || !newCheck.isEmpty
                adoptServer(remote, status: "Atualizado com os dados do servidor")
                if pending { syncNotice = "O item foi atualizado no servidor. As alterações locais ainda não confirmadas foram descartadas." }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .inactive { finishBeforeBackground() }
            else if phase == .active && !store.isPreview {
                Task { await transitionSave?.value; await retrySync() }
            }
        }
        .onChange(of: history) { open in if !open { Task { await reload() } } }
    }
    private func openPayment(_ id: String? = nil) {
        guard editable, !saving else { return }
        autosave?.cancel()
        installmentSelection = NativeInstallmentSelection(checkID: id)
    }
    private func reopenCheck(_ id: String) {
        autosave?.cancel()
        Task {
            guard await commit(closing: false) else { return }
            let itemID = task.id, revision = task.revision
            do {
                let details = try await store.api.get(JSONObject.self, action: "org_check_values", query: ["id": itemID, "checkId": id])
                guard details.record("item").integer("revision") == revision, task.revision == revision else {
                    throw NativeFailure("A tarefa mudou. Atualize antes de reabrir a subtarefa.")
                }
                let payment = details.record("payment")
                if !payment.text("id").isEmpty {
                    _ = try await store.mutate("org_history_undo", ["id": .string(payment.text("id")),
                        "revision": .number(Double(payment.integer("revision"))), "taskRevision": .number(Double(revision))])
                    await reload()
                } else {
                    let binding = checkBinding(id)
                    var fields = binding.wrappedValue
                    fields["done"] = .bool(false)
                    binding.wrappedValue = fields
                    await commit(closing: false)
                }
            } catch { store.report(error) }
        }
    }
    private func openReceipts(_ checkID: String = "") {
        guard !saving, !loading else { return }
        if !checkID.isEmpty {
            guard editable else { return }
            guard valid else { receiptIssue = "Preencha o título da tarefa e o nome da subtarefa antes de anexar."; return }
        }
        autosave?.cancel()
        Task {
            if editable { guard await commit(closing: false) else { return } }
            guard !task.id.isEmpty else { return }
            if !checkID.isEmpty && !task.checks.contains(where: { $0.id == checkID }) {
                receiptIssue = "Esta subtarefa mudou. Atualize a tarefa e confira o destino."
                return
            }
            receiptTarget = NativeReceiptTarget(task: task, checkID: checkID)
        }
    }
    private func previewReceipt(_ file: NativeRecord) {
        guard !loadingReceipt else { return }
        loadingReceipt = true
        Task {
            defer { loadingReceipt = false }
            do { receiptPreview = try await store.api.download(id: file.id, name: file.fields.text("name")) }
            catch { receiptIssue = error.localizedDescription }
        }
    }
    private var reminderLabel: String {
        (task.fields["dateRemindersEnabled"] == .bool(false) ? "Avisos desativados" : "Avisos: \(max(60, task.fields.integer("overdueMinutes")) / 60) h") + (task.fields["repeat"]?.object.text("frequency") == "monthly" ? " · Mensal" : "")
    }
    // Style, grouping and details come from Configurações → Layout → Tarefa aberta.
    @ViewBuilder private var checklistSection: some View {
        let checks = task.checks
        let legacyValues = checks.contains(where: task.usesManualPayment)
        let receipts = Dictionary(grouping: attachments.filter { nativeCurrentReceipt($0, task: task) }) { $0.fields.text("checkId") }
        NativeTaskChecklist(checks: checks, money: legacyValues, receive: task.moneyMode == "receive", layout: detailLayout, collapsed: collapsedGroups, toggle: { id in
            withAnimation(.easeInOut(duration: 0.2)) { if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) } }
        }) { check, presentation in checkRow(check, presentation: presentation, receipts: receipts[check.id] ?? [], legacyValues: legacyValues) }
        if editable {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.dashed").font(.system(size: 21, weight: .light)).foregroundStyle(.secondary).frame(width: 26)
                    TextField("Adicionar subtarefa", text: $newCheck)
                        .focused($newCheckFocused).submitLabel(.next)
                        .onSubmit(registerCheck)
                    if !newCheck.isEmpty {
                        Button(action: registerCheck) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                            .accessibilityLabel("Registrar subtarefa")
                    }
                }.frame(minHeight: 44)
                if checks.count > 1 { Button { reordering = true } label: { Label("Reordenar subtarefas", systemImage: "arrow.up.arrow.down") }.font(.system(size: 12)).padding(.vertical, 4) }
            }
        }
    }
    private func checkRow(_ check: NativeCheck, presentation: NativeCheckPresentation, receipts: [NativeRecord], legacyValues: Bool) -> some View {
        let id = check.id
        let canAttach = editable && !loading && !closing
        let recorded = (check.amount != nil || task.usesManualPayment(check)) && baseline.checks.contains { $0.id == id && $0.done }
        return VStack(alignment: .leading, spacing: 3) {
            NativeInlineCheckRow(fields: checkBinding(id), money: legacyValues, editable: canAttach, saving: saving,
                monthly: task.fields["repeat"]?.object.text("frequency") == "monthly" && !task.id.isEmpty, canTransfer: !task.id.isEmpty,
                presentation: presentation, payment: { openPayment(id) },
                values: { autosave?.cancel(); Task { if await commit(closing: false) { valuesRecord = NativeRecord(fields: ["id": .string(id)]) } } },
                pause: { months, resume in pause(months: months, resume: resume, checkID: id) }, transfer: { movingCheck = id },
                submit: registerCheck, reopen: recorded ? { reopenCheck(id) } : nil, viewReceipts: receipts.isEmpty ? nil : {
                if receipts.count == 1, let file = receipts.first { previewReceipt(file) }
                else { receiptTarget = NativeReceiptTarget(task: task, checkID: id, viewOnly: true) }
            }, receiptShortcut: canAttach, attach: { openReceipts(id) }, remove: { removingCheck = id })
            if !receipts.isEmpty || presentation.style == "ledger" && canAttach {
                HStack(spacing: 12) {
                    if let file = receipts.last {
                        Button { previewReceipt(file) } label: {
                            HStack(spacing: 6) {
                                NativeReceiptThumbnail(api: store.api, file: file, size: presentation.style == "cards" ? CGSize(width: 150, height: 106) : CGSize(width: 46, height: 46))
                                if receipts.count > 1 { Text("+\(receipts.count - 1)").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }.accessibilityLabel("Visualizar comprovante " + file.fields.text("name"))
                    }
                    if presentation.style == "ledger" && canAttach {
                        Button { openReceipts(id) } label: {
                            Label("Anexar", systemImage: "paperclip").font(.footnote.weight(.semibold))
                                .frame(minHeight: 44)
                        }.disabled(saving).accessibilityLabel("Anexar comprovante")
                    }
                }.buttonStyle(.borderless).padding(.leading, 34).padding(.bottom, 4)
            }
        }
        .id(id)
        .overlay {
            if store.highlightedCheckID == id {
                RoundedRectangle(cornerRadius: 8).stroke(nativeBlue, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .background(NativeChecklistMarker(id: id, scroll: checklistScroll))
    }
    private var reorderSheet: some View {
        NavigationStack {
            List { ForEach(task.checks) { check in Label(check.title, systemImage: check.done ? "checkmark.circle" : "circle") }.onMove { offsets, destination in var checks = task.checks; checks.move(fromOffsets: offsets, toOffset: destination); task.fields["checklist"] = .array(checks.map { .object($0.fields) }) } }
                .environment(\.editMode, .constant(.active)).navigationTitle("Reordenar subtarefas").navigationBarTitleDisplayMode(.inline).toolbar { Button("Pronto") { reordering = false } }
        }.presentationDetents([.medium, .large])
    }
    private func addCheck() {
        let value = newCheck.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }
        guard task.checks.count < 100 else { failure = "Limite de 100 subtarefas por tarefa."; return }
        var checks = task.checks.map { JSONValue.object($0.fields) }; checks.append(.object(["id": .string(newCheckID), "text": .string(String(value.prefix(300))), "done": .bool(false), "repeatMonthly": .bool(true)])); task.fields["checklist"] = .array(checks); newCheck = ""; newCheckID = UUID().uuidString
    }
    private func registerCheck() {
        guard editable else { return }
        addCheck()
        Task { @MainActor in
            await Task.yield()
            newCheckFocused = true
            if !task.id.isEmpty && !saving && valid && task != baseline {
                autosave?.cancel()
                await commit(closing: false)
            }
        }
    }
    private func text(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { task.fields[key]?.string ?? fallback }, set: { task.fields[key] = .string($0) })
    }
    private func flag(_ key: String, defaultValue: Bool = false) -> Binding<Bool> {
        Binding(get: { task.fields[key]?.bool ?? defaultValue }, set: { task.fields[key] = .bool($0) })
    }
    private func checkBinding(_ id: String) -> Binding<JSONObject> {
        Binding(get: { task.checks.first { $0.id == id }?.fields ?? [:] }, set: { next in
            var updated = task
            updated.fields["checklist"] = .array(task.checks.map { .object($0.id == id ? next : $0.fields) })
            replaceTask(updated)
        })
    }
    private func replaceTask(_ updated: NativeTask) {
        let old = task.checks
        let next = updated.checks
        let before = old.map { NativeChecklistPosition($0) }
        let after = next.map { NativeChecklistPosition($0) }
        guard before != after else { task = updated; return }
        let matching = Set(before).intersection(after).map(\.id)
        let anchor = checklistScroll.capture(staying: Set(matching))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { task = updated }
        checklistScroll.restore(anchor)
    }
    private func exportChecklist(share: Bool) {
        Task {
            guard !taskLocked else { return }
            if editable && (!newCheck.isEmpty || task != baseline) {
                addCheck()
                autosave?.cancel()
                guard newCheck.isEmpty, await commit(closing: false) else { return }
            }
            let report = (editable ? task : baseline).checklistReport
            if share { checklistShare = report }
            else { UIPasteboard.general.string = report; flash("Lista copiada") }
        }
    }
    private var valid: Bool {
        !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !task.fields.flag("_nativeInvalidAmount") &&
        !task.checks.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.fields.flag("_nativeInvalidAmount") }
    }
    private func close() {
        guard !saving else { return }
        if !editable || task == baseline && newCheck.isEmpty { dismiss(); return }
        addCheck()
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.fields["title"] = .string(String((task.checks.first?.title ?? task.fields.text("body").components(separatedBy: .newlines).first ?? "").prefix(200)))
        }
        autosave?.cancel()
        Task { if !(await commit(closing: true)) { discardConfirm = true } }
    }
    private func save() { guard editable else { return }; addCheck(); autosave?.cancel(); Task { _ = await commit(closing: true) } }
    private func finishBeforeBackground() {
        guard !store.isPreview, transitionSave == nil else { return }
        autosave?.cancel()
        guard editable else { serverReady = false; return }
        addCheck()
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = task.checks.first {
            task.fields["title"] = .string(String(first.title.prefix(200)))
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Salvar tarefa")
        transitionSave = Task {
            if task != baseline {
                if saving {
                    while saving && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                if task != baseline { _ = await commit(closing: false, background: true) }
            }
            serverReady = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            transitionSave = nil
        }
    }
    private func scheduleAutosave() {
        guard !saving else { return }
        autosave?.cancel()
        guard task != baseline, !task.id.isEmpty, valid, editable, store.canWrite, !loading, syncNotice == nil, store.editorSyncEnabled else { return }
        autosave = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            Task { _ = await commit(closing: false) }
        }
    }
    @discardableResult private func commit(closing shouldClose: Bool, background: Bool = false) async -> Bool {
        guard !saving, !reloading, editable || background && serverReady, store.canWrite else { return false }
        guard valid else { if shouldClose { failure = "Revise o título, as subtarefas e os valores." }; return false }
        if task == baseline && !task.id.isEmpty { if shouldClose { saved = true; dismiss() }; return true }
        let submitted = task
        saving = true; closing = shouldClose; saveStatus = "Salvando no servidor…"; syncNotice = nil
        var succeeded = false
        defer { saving = false; closing = false; if succeeded && task != baseline { scheduleAutosave() } }
        do {
            let receipt = try await NativeTaskSync.save(submitted, base: baseline, write: { try await store.save($0) }, read: { try await latestTask(background: background) })
            if store.offline { await store.refresh() }
            let merge = NativeTaskMerge(local: task, base: submitted, remote: receipt.canonical)
            baseline = receipt.canonical
            replaceTask(merge.conflicts.isEmpty ? merge.task : receipt.canonical)
            serverReady = !store.offline && !store.needsSync
            if task == baseline { flash("Salvo na sua conta") } else { saveStatus = "Alterações ainda não salvas no servidor" }
            succeeded = true
            if shouldClose && task == baseline { saved = true; dismiss() }
            return task == baseline
        } catch {
            if (error as? NativeFailure)?.status == 499 { saveStatus = "Confira os valores antes de salvar"; return false }
            let issue = error as? NativeTaskSaveIssue
            let reason = issue?.underlying ?? error
            if let remote = issue?.remote {
                await store.refresh()
                let current = store.snapshot.items.first(where: { $0.id == remote.id && $0.revision >= remote.revision }) ?? remote
                adoptServer(current, status: "Versão do servidor recarregada")
                syncNotice = (reason as? NativeFailure)?.status == 409
                    ? "Este item mudou no servidor. Carreguei a versão atual; as alterações não confirmadas foram descartadas."
                    : "O salvamento não foi confirmado. A tela mostra os dados que estão no servidor."
            } else {
                store.noteConnectionFailure(reason)
                replaceTask(baseline); newCheck = ""; serverReady = false
                saveStatus = "Não salvo no servidor"
                syncNotice = "Não foi possível confirmar o salvamento. Conecte-se e atualize para conferir os dados do servidor. Não foi criado rascunho neste iPhone."
            }
            return false
        }
    }
    private func latestTask(background: Bool = false) async throws -> NativeTask {
        let details: JSONObject
        if background { details = try await store.api.get(JSONObject.self, action: "org_item", query: ["id": task.id]) }
        else { details = try await store.taskDetails(task.id) }
        guard let item = details["item"], case .object(let fields) = item else { throw NativeFailure("Resposta de tarefa incompleta.") }
        return NativeTask(fields)
    }
    // Loading from the server is the normal state and shows nothing; only
    // problems stay on screen. Confirmations disappear after a moment.
    private func adoptServer(_ remote: NativeTask, status: String = "") {
        if remote != baseline { dismissEditingSheets() }
        autosave?.cancel(); baseline = remote; replaceTask(remote); newCheck = ""
        serverReady = !store.offline && !store.needsSync && store.networkAvailable
        syncNotice = nil
        if status.isEmpty { saveStatus = "" } else { flash(status) }
    }
    private func flash(_ status: String) {
        saveStatus = status
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if saveStatus == status && !saving { saveStatus = "" } }
    }
    private func dismissEditingSheets() {
        installmentSelection = nil; installmentGenerator = false; remindersOptions = false; reordering = false; movingCheck = nil
    }
    private func connectionLost() {
        dismissEditingSheets()
        autosave?.cancel(); serverReady = false
        guard !saving else { return }
        replaceTask(store.snapshot.items.first(where: { $0.id == task.id }) ?? baseline)
        baseline = task; newCheck = ""
        saveStatus = "Somente consulta"
        syncNotice = "Sem conexão com o servidor. A edição está bloqueada; alterações não confirmadas não ficam guardadas como rascunho."
    }
    private func retrySync() async {
        guard !saving, !reloading else { return }
        autosave?.cancel(); serverReady = false
        if !store.isPreview { await store.refresh() }
        guard store.canWrite else { connectionLost(); return }
        if task.id.isEmpty { task = baseline; newCheck = ""; serverReady = true; syncNotice = nil }
        else { await reload() }
    }
    private func applySuggestions(_ values: JSONObject) async {
        autosave?.cancel()
        for (key, value) in values where key != "listId" { task.fields[key] = value }
        guard let category = values["listId"]?.string, category != task.categoryID else { return }
        if task.id.isEmpty { task.fields["listId"] = .string(category); return }
        guard await commit(closing: false) else { return }
        do { _ = try await store.mutate("org_move_item", ["id": .string(task.id), "revision": .number(Double(task.revision)), "listId": .string(category)]); await reload() }
        catch { failure = error.localizedDescription }
    }
    private func move(to categoryID: String) {
        guard categoryID != task.categoryID else { return }
        Task {
            guard await commit(closing: false) else { return }
            do { _ = try await store.mutate("org_move_item", ["id": .string(task.id), "revision": .number(Double(task.revision)), "listId": .string(categoryID)]); await reload() } catch { failure = error.localizedDescription }
        }
    }
    private func reload() async {
        guard !task.id.isEmpty, store.networkAvailable, !store.offline, store.editorSyncEnabled, !reloading else { return }
        let pending = task != baseline || !newCheck.isEmpty
        reloading = true; autosave?.cancel(); serverReady = false
        defer { reloading = false }
        do {
            let details = try await store.taskDetails(task.id)
            guard let item = details["item"], case .object(let fields) = item else { throw NativeFailure("Resposta de tarefa incompleta.") }
            adoptServer(NativeTask(fields))
            if pending { syncNotice = "Versão do servidor carregada. As alterações não confirmadas foram descartadas." }
            attachments = details.objects("attachments").map(NativeRecord.init)
            comments = details.objects("comments").map(NativeRecord.init)
        } catch {
            store.noteConnectionFailure(error); task = baseline; newCheck = ""; serverReady = false
            syncNotice = "Não foi possível carregar a versão do servidor. A edição está bloqueada até atualizar."
        }
    }
    private func pause(months: Int, resume: Bool, checkID: String = "") {
        Task {
            guard await commit(closing: false) else { return }
            do {
                _ = try await store.mutate("org_pause", ["id": .string(task.id), "revision": .number(Double(task.revision)), "months": .number(Double(months)), "resume": .bool(resume), "checkId": .string(checkID)])
                await reload()
            } catch { failure = error.localizedDescription }
        }
    }

    private var transferSheet: some View {
        NavigationStack {
            List {
                Text("A subtarefa será transferida com datas, pagamentos e comprovantes. Quem tem acesso ao destino poderá ver esses registros.").font(.footnote).foregroundStyle(.secondary)
                ForEach(store.snapshot.items.filter { $0.id != task.id && $0.isActive && store.canEdit($0) }) { target in
                    Button { transferTarget = target } label: { VStack(alignment: .leading, spacing: 4) { Text(target.title); Text(store.category(target)).font(.caption).foregroundStyle(.secondary) } }
                }
            }.navigationTitle("Transferir subtarefa").navigationBarTitleDisplayMode(.inline).toolbar { Button("Cancelar") { movingCheck = nil } }
                .confirmationDialog("Transferir para \(transferTarget?.title ?? "a tarefa")?", isPresented: Binding(get: { transferTarget != nil }, set: { if !$0 { transferTarget = nil } }), titleVisibility: .visible) {
                    Button("Transferir com os registros") {
                        guard let target = transferTarget, let checkID = movingCheck else { return }
                        Task {
                            guard await commit(closing: false) else { return }
                            do {
                                let latest = store.snapshot.items.first { $0.id == target.id } ?? target
                                _ = try await store.mutate("org_move_check", ["id": .string(task.id), "revision": .number(Double(task.revision)), "checkId": .string(checkID), "targetId": .string(latest.id), "targetRevision": .number(Double(latest.revision))])
                                movingCheck = nil; transferTarget = nil; await reload()
                            } catch { failure = error.localizedDescription }
                        }
                    }
                }
        }
    }

    private var commentsSection: some View {
        Section("Comentários") {
            ForEach(comments) { value in
                VStack(alignment: .leading, spacing: 5) {
                    Text(value.fields.text("name")).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(value.fields.text("body"))
                }
            }
            if editable {
                TextField("Escrever comentário", text: $comment, axis: .vertical)
                Button("Enviar comentário") { Task {
                    do {
                        _ = try await store.mutate("org_comment", ["itemId": .string(task.id), "body": .string(comment)])
                        comment = ""; await reload()
                    } catch { failure = error.localizedDescription }
                } }.disabled(!store.canWrite || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
    }
}
