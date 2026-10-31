import SwiftUI
import UIKit

var nativeBlue: Color {
    let colors = ["blue": "#1f6feb", "green": "#138568", "purple": "#7650c4", "rose": "#c03b6a", "amber": "#b4640b", "dark": "#3b7ef0"]
    return Color(nativeHex: colors[UserDefaults.standard.string(forKey: "nativeTheme") ?? "blue"] ?? "#1f6feb")
}

struct NativeRootView: View {
    @StateObject private var store = NativeStore.shared
    @ObservedObject private var quickActions = NativeQuickActions.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingURL: URL?
    @AppStorage("nativeAppearance") private var appearance = "system"
    private var active: Bool { scenePhase == .active }
    var body: some View {
        Group {
            if store.locked {
                VStack(spacing: 22) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(nativeBlue)
                    Text("Suas tarefas, protegidas").font(.title2.bold())
                    Button("Desbloquear") { Task { await store.unlock() } }.buttonStyle(.borderedProminent)
                }
            } else if store.loading { ProgressView("Preparando suas tarefas…") }
            else if store.user == nil { NativeLoginView(store: store) }
            else {
                NativeAppShell(store: store)
                    .sheet(item: $store.openedTask) { task in NativeTaskEditor(store: store, original: task).presentationDetents(task.id.isEmpty ? [.medium, .large] : [.large]).presentationDragIndicator(.visible) }
            }
        }
        .tint(nativeBlue).preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil).environment(\.locale, Locale(identifier: "pt_BR")).privacySensitive()
        .overlay {
            if !active {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                    .overlay { Label("SaldoLeve", systemImage: "checkmark.circle.fill").font(.title.bold()).foregroundStyle(nativeBlue) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.user != nil && (store.offline || !store.networkAvailable || store.needsSync) {
                HStack {
                    Label("Sem conexão com o servidor · somente consulta", systemImage: "wifi.slash").font(.caption)
                    Spacer()
                    Button("Atualizar") { Task { await store.refresh() } }.font(.caption.bold()).disabled(store.refreshing || !store.networkAvailable)
                }.padding(10).background(Color.orange.opacity(0.15)).accessibilityIdentifier("server-offline-banner")
            }
        }
        .task { if store.isPreview { store.loadPreview() } else { await store.ensureStarted() }; NativeQuickActions.refresh(); runQuickAction() }
        .task(id: active) {
            guard active, !store.isPreview else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                if store.user != nil && store.networkAvailable && !store.working && !store.locked { await store.refresh(); if store.section != .tasks { await store.finance.refresh() } }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "saldoleve", ["focus", "tasks"].contains(url.host ?? "") else { return }
            pendingURL = url; openWidgetDestination()
        }
        .onChange(of: store.loading) { _ in openWidgetDestination(); runQuickAction() }
        .onChange(of: store.refreshing) { _ in openWidgetDestination() }
        .onChange(of: store.locked) { _ in openWidgetDestination(); runQuickAction() }
        .onChange(of: store.user?.id) { _ in openWidgetDestination() }
        .onChange(of: quickActions.pending) { _ in runQuickAction() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { store.persist() }
            if phase == .background && UserDefaults.standard.bool(forKey: "nativeBiometrics") { store.locked = store.user != nil }
            if phase == .active {
                openWidgetDestination()
                if !store.isPreview && store.user != nil && !store.working { Task { await store.refresh(); if store.section != .tasks { await store.finance.refresh() } } }
            }
        }
        .alert("SaldoLeve", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
    private func runQuickAction() {
        guard let action = quickActions.pending, !store.loading, !store.locked else { return }
        quickActions.pending = nil
        let time: (Date) -> String = { $0.formatted(.dateTime.weekday(.wide).hour().minute().locale(Locale(identifier: "pt_BR"))) }
        switch action {
        case NativeQuickActions.pauseTwoHours, NativeQuickActions.pauseTomorrow:
            let until = action == NativeQuickActions.pauseTwoHours ? NativeAlertPause.forHours(2) : NativeAlertPause.untilTomorrow(NativeNotificationPreferences.read())
            store.reminders.pause(until: until)
            store.message = "Avisos suspensos até " + time(until) + ". Lembretes por local continuam ativos. Para retomar antes, segure o ícone do SaldoLeve ou use Configurações → Notificações."
        case NativeQuickActions.resume:
            store.reminders.pause(until: nil)
            store.message = "Avisos retomados."
        case NativeQuickActions.newTask:
            pendingURL = URL(string: "saldoleve://tasks?new=1"); openWidgetDestination()
        default: break
        }
    }
    private func openWidgetDestination() {
        guard let url = pendingURL, active, !store.loading, !store.locked, store.user != nil else { return }
        store.section = .tasks
        store.openedFinance = nil; store.menuOpen = false
        // Legacy widgets also enter the task list, never the old focus modal.
        store.taskScopeRequest = "all"
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: { $0.name == "new" }) {
            // Quick action "Nova tarefa": waits for the server before opening.
            guard !store.refreshing else { return }
            pendingURL = nil
            if store.canWrite, let category = store.editableCategories.first?.id { store.openedTask = NativeTask.draft(categoryID: category) }
            else { store.message = "Sem conexão com o servidor. Atualize antes de criar uma tarefa." }
            return
        }
        let id = items.first { $0.name == "id" }?.value
        guard let id else { pendingURL = nil; return }
        if let task = store.snapshot.items.first(where: { $0.id == id }) {
            pendingURL = nil; store.openedTask = task
        } else if !store.needsSync && !store.refreshing {
            pendingURL = nil; store.message = "Esta tarefa não está disponível na sua conta."
        }
    }
}

struct NativeLoginView: View {
    @ObservedObject var store: NativeStore
    @State private var login = ""
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 58)).foregroundStyle(nativeBlue)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.requiresPasswordChange ? "Crie sua senha" : "Seu dia,\nmais leve.").font(.system(size: 40, weight: .bold, design: .rounded))
                        Text(store.requiresPasswordChange ? "Sua conta exige uma nova senha antes de continuar." : "Tarefas, cobranças e comprovantes, sempre à mão.").foregroundStyle(.secondary)
                    }
                    VStack(spacing: 16) {
                        if !store.requiresPasswordChange {
                            TextField("Usuário do SaldoLeve", text: $login).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        SecureField(store.requiresPasswordChange ? "Nova senha" : "Senha", text: $password).textContentType(store.requiresPasswordChange ? .newPassword : .password)
                        if store.requiresPasswordChange { SecureField("Confirmar nova senha", text: $confirmation).textContentType(.newPassword) }
                    }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    Button {
                        guard !store.requiresPasswordChange || confirmation == password else { store.message = "As senhas precisam ser iguais."; return }
                        Task {
                            let wasChanging = store.requiresPasswordChange
                            await store.login(name: login, password: password)
                            if store.user != nil || (!wasChanging && store.requiresPasswordChange) { password = ""; confirmation = "" }
                        }
                    } label: {
                        HStack { Spacer(); if store.working { ProgressView().tint(.white) } else { Text(store.requiresPasswordChange ? "Salvar senha" : "Entrar").bold() }; Spacer() }.padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).disabled(store.working || password.isEmpty || (!store.requiresPasswordChange && login.isEmpty))
                    Text("Use sua conta do sistema SaldoLeve hospedado na HostGator.").font(.footnote).foregroundStyle(.secondary)
                }.padding(28).padding(.top, 44)
            }.background(Color(uiColor: .systemGroupedBackground)).scrollDismissesKeyboard(.interactively)
        }
    }
}
