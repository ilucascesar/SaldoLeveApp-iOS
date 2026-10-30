import SwiftUI
import UserNotifications

struct NativeNotificationSettings: View {
    @ObservedObject var store: NativeStore
    @AppStorage("nativeLocalReminders") private var enabled = false
    @State private var preferences = NativeNotificationPreferences.read()
    @State private var status = "Verificando…"
    @State private var pending = 0
    @State private var requesting = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            Section {
                Toggle("Notificações neste iPhone", isOn: Binding(get: { enabled }, set: setEnabled)).disabled(requesting)
                LabeledContent("Permissão do iOS", value: status)
                Button("Abrir ajustes de notificações do iPhone") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            } footer: { Text("A permissão, os banners, a tela bloqueada e o modo Foco são controlados pelo iOS. O aplicativo respeita essas escolhas.") }
            Section("Quais avisos receber") {
                Toggle("Tarefas", isOn: $preferences.tasks)
                Toggle("Subtarefas", isOn: $preferences.subtasks).disabled(!preferences.tasks)
                Toggle("Lembretes de despesas", isOn: $preferences.expenses)
                Toggle("Dois dias antes", isOn: $preferences.twoDaysBefore)
                Toggle("Um dia antes", isOn: $preferences.oneDayBefore)
                Toggle("No vencimento", isOn: $preferences.atDueTime)
                Toggle("Reavisar pendências", isOn: $preferences.repeatOverdue)
                Text("Os reavisos usam o intervalo de cada tarefa. As opções gerais não ativam avisos desabilitados no editor da tarefa.").font(.footnote).foregroundStyle(.secondary)
                if let issue = store.expenseReminderIssue { Text(issue).font(.footnote).foregroundStyle(.orange) }
            }.disabled(!enabled)
            Section {
                Toggle("Ativar horário de silêncio", isOn: $preferences.quietEnabled)
                if preferences.quietEnabled {
                    DatePicker("Início", selection: time(\.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("Fim", selection: time(\.quietEnd), displayedComponents: .hourAndMinute)
                    Picker("Fuso do silêncio", selection: $preferences.timezone) {
                        Text("Brasília").tag("America/Sao_Paulo")
                        if TimeZone.current.identifier != "America/Sao_Paulo" { Text("Este iPhone (\(TimeZone.current.identifier))").tag(TimeZone.current.identifier) }
                    }
                    if preferences.quietStart == preferences.quietEnd { Text("Horários iguais deixam o silêncio desativado.").font(.footnote).foregroundStyle(.orange) }
                }
            } header: { Text("Silêncio opcional") } footer: {
                Text(preferences.quietEnabled ? "Os avisos dentro desse período são adiados para o fim do silêncio. Avisos da mesma pendência são agrupados nesse horário." : "O SaldoLeve pode avisar em qualquer horário. O modo silencioso e o Foco do iPhone continuam valendo.")
            }
            Section("Apresentação") {
                Toggle("Som", isOn: $preferences.sound)
                Toggle("Contador no ícone", isOn: $preferences.badge)
                Text("O contador mostra tarefas pendentes cujo prazo já chegou. Ele é recalculado ao sincronizar e nos avisos programados.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Mostrar título e detalhes", isOn: $preferences.showDetails)
                Toggle("Banner com o app aberto", isOn: $preferences.showWhileOpen)
            }
            Section {
                LabeledContent("Avisos programados", value: "\(pending) de até 60")
                Button("Recalcular avisos agora") { store.reminders.update(store.snapshot); Task { try? await Task.sleep(nanoseconds: 400_000_000); await reload() } }.disabled(!enabled)
                Button("Testar aviso em 5 segundos") { Task { do { try await store.reminders.test() } catch { store.report(error) } } }.disabled(!enabled)
            } footer: { Text("Abra e sincronize para atualizar os lembretes após mudanças no site. O iOS entrega os avisos já programados com o app fechado. Não há atualização contínua nem notificações remotas de alterações na conta.") }
        }.navigationTitle("Notificações").navigationBarTitleDisplayMode(.inline)
            .task { await reload() }
            .onChange(of: preferences) { value in value.save(); store.reminders.update(store.snapshot) }
            .onChange(of: scenePhase) { value in if value == .active { Task { await reload() } } }
    }
    private func setEnabled(_ value: Bool) {
        if !value { store.reminders.clear(); pending = 0; return }
        requesting = true
        Task {
            defer { requesting = false }
            do { let granted = try await store.reminders.enable(store.snapshot); if !granted { store.message = "Notificações bloqueadas pelo iOS. Use Abrir ajustes de notificações para permitir." } }
            catch { store.report(error) }
            await reload()
        }
    }
    private func reload() async {
        let settings = await store.reminders.permission()
        switch settings.authorizationStatus {
        case .notDetermined: status = "Ainda não solicitada"
        case .denied: status = "Bloqueada"
        case .authorized: status = "Permitida"
        case .provisional: status = "Entrega silenciosa"
        case .ephemeral: status = "Temporária"
        @unknown default: status = "Desconhecida"
        }
        pending = await store.reminders.pendingCount()
    }
    private func time(_ key: WritableKeyPath<NativeNotificationPreferences, Int>) -> Binding<Date> {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: preferences.timezone) ?? .current
        return Binding(get: { calendar.date(bySettingHour: preferences[keyPath: key] / 60, minute: preferences[keyPath: key] % 60, second: 0, of: Date()) ?? Date() }, set: { preferences[keyPath: key] = calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) })
    }
}
