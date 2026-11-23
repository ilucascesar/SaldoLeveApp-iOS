import SwiftUI
import UserNotifications

// Opções de adiar escolhidas pelo usuário (até 5). Aparecem ao segurar ou
// arrastar um aviso para baixo. Ficam neste iPhone, como as demais
// preferências de aviso; a identificação da ação carrega a regra completa,
// então um aviso antigo continua funcionando mesmo depois de a lista mudar.
struct NativeSnoozeOption: Codable, Equatable, Identifiable {
    enum Unit: String, Codable, CaseIterable {
        case minutes, hours, days
        var label: String { self == .minutes ? "Minutos" : self == .hours ? "Horas" : "Dias" }
        var limit: Int { self == .minutes ? 720 : self == .hours ? 168 : 365 }
    }
    static let maximum = 5
    static let defaultMinuteOfDay = 8 * 60
    var id = UUID().uuidString
    var amount = 1
    var unit: Unit = .days
    var minuteOfDay = NativeSnoozeOption.defaultMinuteOfDay

    var count: Int { min(max(amount, 1), unit.limit) }
    var minute: Int { min(max(minuteOfDay, 0), 1439) }
    private var clock: String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    var title: String {
        switch unit {
        case .minutes: return "Lembrar em \(count) min"
        case .hours: return count == 1 ? "Lembrar em 1 hora" : "Lembrar em \(count) horas"
        case .days: return (count == 1 ? "Lembrar amanhã" : count == 2 ? "Lembrar depois de amanhã" : "Lembrar em \(count) dias") + " às " + clock
        }
    }
    var actionID: String { "sl.action.snooze|\(unit.rawValue)|\(count)|\(minute)" }
    static func parse(action: String) -> NativeSnoozeOption? {
        let parts = action.split(separator: "|").map(String.init)
        guard parts.count == 4, parts[0] == "sl.action.snooze", let unit = Unit(rawValue: parts[1]), let amount = Int(parts[2]), let minute = Int(parts[3]) else { return nil }
        return NativeSnoozeOption(amount: amount, unit: unit, minuteOfDay: minute)
    }
    func fireDate(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch unit {
        case .minutes: return now.addingTimeInterval(Double(count) * 60)
        case .hours: return now.addingTimeInterval(Double(count) * 3600)
        case .days:
            let day = calendar.date(byAdding: .day, value: count, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(Double(count) * 86400)
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
        }
    }
}

enum NativeSnoozeStore {
    static let storageKey = "nativeSnoozeOptionsV1"
    static var defaults: [NativeSnoozeOption] {
        [NativeSnoozeOption(amount: 2, unit: .hours), NativeSnoozeOption(amount: 4, unit: .hours), NativeSnoozeOption(amount: 6, unit: .hours),
         NativeSnoozeOption(amount: 8, unit: .hours), NativeSnoozeOption(amount: 1, unit: .days)]
    }
    static func read(_ store: UserDefaults = .standard) -> [NativeSnoozeOption] {
        guard let data = store.data(forKey: storageKey), let list = try? JSONDecoder().decode([NativeSnoozeOption].self, from: data) else { return defaults }
        return clean(list)
    }
    static func save(_ list: [NativeSnoozeOption], _ store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(clean(list)) { store.set(data, forKey: storageKey) }
        NativeReminderActions.register(UNUserNotificationCenter.current())
    }
    // No máximo 5 e sem regras repetidas (o iOS exige ações distintas).
    static func clean(_ list: [NativeSnoozeOption]) -> [NativeSnoozeOption] {
        var seen = Set<String>()
        return Array(list.filter { seen.insert($0.actionID).inserted }.prefix(NativeSnoozeOption.maximum))
    }
}

struct NativeSnoozeSettings: View {
    @State private var options = NativeSnoozeStore.read()
    var body: some View {
        Form {
            Section {
                ForEach($options) { $option in
                    NavigationLink { NativeSnoozeEditor(option: $option) } label: { Text(option.title) }
                }
                .onDelete { options.remove(atOffsets: $0) }
                .onMove { options.move(fromOffsets: $0, toOffset: $1) }
                if options.count < NativeSnoozeOption.maximum {
                    Button { options.append(NativeSnoozeOption()) } label: { Label("Adicionar opção", systemImage: "plus.circle") }
                }
            } header: { Text("Opções de adiar (\(options.count) de \(NativeSnoozeOption.maximum))") } footer: {
                Text("Aparecem ao segurar ou arrastar um aviso para baixo, depois de Marcar como feito. Escolha quantos minutos, horas ou dias quiser: por exemplo amanhã, depois de amanhã, 10 dias ou 20 dias. O iOS pode mostrar só as primeiras opções em alguns avisos, por isso coloque as favoritas no topo (toque em Editar para reordenar). Deslize para apagar.")
            }
            Section {
                Button("Restaurar padrão") { options = NativeSnoozeStore.defaults }
            }
        }
        .navigationTitle("Opções de adiar").navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onChange(of: options) { value in NativeSnoozeStore.save(value) }
    }
}

private struct NativeSnoozeEditor: View {
    @Binding var option: NativeSnoozeOption
    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: option.minute / 60, minute: option.minute % 60, second: 0, of: Date()) ?? Date() },
                set: { option.minuteOfDay = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) })
    }
    var body: some View {
        Form {
            Section {
                Stepper(value: $option.amount, in: 1...option.unit.limit) { LabeledContent("Quantidade", value: "\(option.count)") }
                Picker("Unidade", selection: $option.unit) { ForEach(NativeSnoozeOption.Unit.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                if option.unit == .days { DatePicker("Horário do lembrete", selection: time, displayedComponents: .hourAndMinute) }
            } footer: {
                Text(option.unit == .days ? "1 dia = amanhã, 2 dias = depois de amanhã. O aviso volta no horário escolhido." : "O aviso volta depois desse tempo, a partir do momento em que você tocar.")
            }
            Section("Como vai aparecer") { Text(option.title) }
        }
        .navigationTitle("Opção de adiar").navigationBarTitleDisplayMode(.inline)
        .onChange(of: option.unit) { value in option.amount = min(option.amount, value.limit) }
    }
}
