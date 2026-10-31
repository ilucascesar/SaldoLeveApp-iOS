import SwiftUI
import UIKit

extension Color {
    init(nativeHex: String) {
        let hex = nativeHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(hex, radix: 16) ?? 0x1f6feb
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
let nativeCanvas = Color(uiColor: .systemGroupedBackground)
let nativePaper = Color(uiColor: .secondarySystemGroupedBackground)

struct NativeChip: View {
    let title: String
    var icon = ""
    var active = false
    var color = nativeBlue
    var body: some View {
        HStack(spacing: 6) { if !icon.isEmpty { Image(systemName: icon).foregroundStyle(icon == "circle.fill" ? color : active ? color : Color(uiColor: .secondaryLabel)) }; Text(title).lineLimit(1) }
            .font(.system(size: 13, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 9)
            .foregroundStyle(active ? color : Color.secondary)
            .background(active ? color.opacity(0.09) : Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}
enum NativeDateLabel {
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        var day: String
        if calendar.isDate(date, inSameDayAs: now) { day = "Hoje" }
        else if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!) { day = "Amanhã" }
        else if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) { day = "Ontem" }
        else { day = date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "pt_BR"))) }
        if calendar.component(.hour, from: date) != 0 || calendar.component(.minute, from: date) != 0 { day += ", " + date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))) }
        return day
    }
}
struct NativeDateChip: View {
    @Binding var fields: JSONObject
    var key = "dueAt"
    var compact = false
    var enabled = true
    @State private var picking = false
    var body: some View {
        Button { picking = true } label: {
            if compact {
                Group {
                    if let date = NativeDate.parse(fields.text(key)) { Text(NativeDateLabel.text(date)).font(.system(size: 12)) }
                    else { Image(systemName: "calendar").font(.system(size: 16)) }
                }.foregroundStyle(NativeDate.parse(fields.text(key)).map { $0 < Date() } == true ? Color.orange : Color.secondary)
                    .frame(minWidth: 36, minHeight: 44).contentShape(Rectangle())
            } else {
                NativeChip(title: NativeDate.parse(fields.text(key)).map { NativeDateLabel.text($0) } ?? "Data", icon: "calendar", active: !fields.text(key).isEmpty)
            }
        }.buttonStyle(.borderless).disabled(!enabled)
            .sheet(isPresented: $picking) { NativeDateSheet(fields: $fields, key: key) }
    }
}
struct NativeDateSheet: View {
    @Binding var fields: JSONObject
    var key = "dueAt"
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var timed: Bool
    init(fields: Binding<JSONObject>, key: String = "dueAt") {
        _fields = fields; self.key = key
        let current = NativeDate.parse(fields.wrappedValue.text(key)) ?? NativeDate.quarter(Date())
        _date = State(initialValue: current)
        _timed = State(initialValue: Calendar.current.component(.hour, from: current) != 0 || Calendar.current.component(.minute, from: current) != 0)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                DatePicker("Data", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                Toggle("Definir horário", isOn: $timed).padding(.horizontal, 12)
                if timed { NativeQuarterClock(date: $date).frame(height: 100) }
                Spacer(minLength: 4)
                Button("Remover data", role: .destructive) { fields[key] = .null; dismiss() }.padding(12)
            }.padding(16).navigationTitle("Data e horário").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Aplicar") {
                        fields[key] = .string(NativeDate.iso(timed ? NativeDate.quarter(date) : Calendar.current.startOfDay(for: date))); dismiss()
                    }.bold() }
                }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
struct NativeQuarterClock: UIViewRepresentable {
    @Binding var date: Date
    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker(); picker.datePickerMode = .time; picker.preferredDatePickerStyle = .wheels
        picker.minuteInterval = 15; picker.locale = Locale(identifier: "pt_BR")
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }
    func updateUIView(_ picker: UIDatePicker, context: Context) { context.coordinator.parent = self; picker.setDate(date, animated: false) }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var parent: NativeQuarterClock
        init(_ parent: NativeQuarterClock) { self.parent = parent }
        @objc func changed(_ picker: UIDatePicker) { parent.date = picker.date }
    }
}
struct NativeReminderOptions: View {
    @Binding var fields: JSONObject
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Avisar pelas datas pendentes", isOn: flag("dateRemindersEnabled", fallback: true))
                    Toggle("Repetição mensal", isOn: Binding(get: { fields["repeat"]?.object.text("frequency") == "monthly" }, set: { fields["repeat"] = .object(["frequency": .string($0 ? "monthly" : "none"), "interval": .number(1)]) }))
                    Toggle("Antecipar fim de semana para sexta", isOn: flag("weekendAdvance"))
                } footer: { Text("Cada pendência avisa 2 dias antes, 1 dia antes e após o vencimento. Ao concluir todas, a repetição mensal guarda o histórico e abre o próximo mês.") }
                Section("Avisos após o vencimento") {
                    Picker("Reavisar", selection: Binding(get: { max(60, fields.integer("overdueMinutes")) }, set: { fields["overdueMinutes"] = .number(Double($0)) })) {
                        ForEach([60, 120, 240, 360, 480], id: \.self) { Text("A cada \($0 / 60) hora(s)").tag($0) }
                    }.pickerStyle(.inline).labelsHidden()
                }
            }.navigationTitle("Avisos e repetição").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Pronto") { dismiss() }.bold() }
        }.presentationDetents([.large])
    }
    private func flag(_ key: String, fallback: Bool = false) -> Binding<Bool> { Binding(get: { fields[key]?.bool ?? fallback }, set: { fields[key] = .bool($0) }) }
}
struct NativeMoneyOptions: View {
    @Binding var fields: JSONObject
    var isCheck = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if !isCheck {
                    Picker("Tipo", selection: Binding(get: { fields["moneyMode"]?.string ?? "normal" }, set: { fields["moneyMode"] = .string($0) })) {
                        Text("Normal").tag("normal"); Text("A pagar").tag("pay"); Text("A receber").tag("receive")
                    }.pickerStyle(.segmented)
                }
                if isCheck || ["pay", "receive"].contains(fields.text("moneyMode")) {
                    Section("Valor") { NativeMoneyField(fields: $fields); Toggle("Valor variável", isOn: Binding(get: { fields.flag("variableAmount") }, set: { fields["variableAmount"] = .bool($0) })) }
                }
            }.navigationTitle("Valores").navigationBarTitleDisplayMode(.inline).toolbar { Button("Pronto") { dismiss() }.disabled(fields.flag("_nativeInvalidAmount")) }
        }.presentationDetents([.medium, .large])
    }
}

struct NativeDateField: View {
    @Binding var fields: JSONObject
    let key: String
    let title: String
    private var enabled: Binding<Bool> {
        Binding(get: { NativeDate.parse(fields.text(key)) != nil }, set: { value in
            fields[key] = value ? .string(NativeDate.iso(NativeDate.quarter(Date().addingTimeInterval(3600)))) : .null
        })
    }
    var body: some View {
        Toggle(title, isOn: enabled)
        if enabled.wrappedValue {
            DatePicker("Data e hora", selection: Binding(get: { NativeDate.parse(fields.text(key)) ?? Date() }, set: {
                fields[key] = .string(NativeDate.iso(NativeDate.quarter($0)))
            }), displayedComponents: [.date, .hourAndMinute])
        }
    }
}
struct NativeMoneyField: View {
    @Binding var fields: JSONObject
    private var amount: Binding<String> {
        Binding(get: {
            if let raw = fields["_nativeAmountText"], case .string(let text) = raw { return text }
            guard let cents = fields["amountCents"]?.number else { return "" }
            return String(format: "%.2f", cents / 100).replacingOccurrences(of: ".", with: ",")
        }, set: { text in
            fields["_nativeAmountText"] = .string(text)
            let parsed = NativeDate.cents(text)
            let valid = text.trimmingCharacters(in: .whitespaces).isEmpty || parsed != nil
            fields["_nativeInvalidAmount"] = .bool(!valid)
            if valid { fields["amountCents"] = parsed.map { .number(Double($0)) } ?? .null }
        })
    }
    var body: some View {
        TextField("Valor em R$", text: amount).keyboardType(.decimalPad)
        if fields.flag("_nativeInvalidAmount") { Text("Informe um valor válido em reais.").foregroundStyle(.red).font(.caption) }
    }
}
struct NativeCheckEditor: View {
    @Binding var fields: JSONObject
    let money: Bool
    let editable: Bool
    private func flag(_ key: String, fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { fields[key]?.bool ?? fallback }, set: { fields[key] = .bool($0) })
    }
    var body: some View {
        Form {
            Section {
                TextField("Nome da subtarefa", text: Binding(get: { fields.text("text") }, set: { fields["text"] = .string($0) }), axis: .vertical)
                Toggle(money ? "Paga / recebida" : "Concluída", isOn: flag("done"))
            }
            Section("Prazo") {
                NativeDateField(fields: $fields, key: "remindAt", title: "Data e horário")
                Toggle("Repetir no próximo ciclo mensal", isOn: flag("repeatMonthly", fallback: true))
            }
            if money {
                Section("Valor") {
                    NativeMoneyField(fields: $fields)
                    Toggle("Valor variável", isOn: flag("variableAmount"))
                }
            }
            Text("As alterações ainda não estão no servidor. Volte à tarefa e toque em Salvar para confirmar.").font(.footnote).foregroundStyle(.secondary)
        }.disabled(!editable).navigationTitle("Subtarefa").navigationBarTitleDisplayMode(.inline)
    }
}

struct NativeInlineCheckRow: View {
    @Binding var fields: JSONObject
    let money: Bool
    let editable: Bool
    var saving = false
    var monthly = false
    var canTransfer = false
    var layoutStyle = "elegant"
    var showMetadata = true
    var payment: () -> Void = {}
    var values: () -> Void = {}
    var pause: (Int, Bool) -> Void = { _, _ in }
    var transfer: () -> Void = {}
    var attach: () -> Void
    var remove: () -> Void
    @State private var amount = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                if money && !fields.flag("done") { payment() }
                else { fields["done"] = .bool(!fields.flag("done")) }
            } label: { Image(systemName: fields.flag("done") ? "checkmark.circle.fill" : "circle").font(.system(size: layoutStyle == "minimal" ? 19 : 21, weight: .light)).foregroundStyle(fields.flag("done") ? Color.secondary.opacity(0.6) : nativeBlue).background(Circle().fill(layoutStyle == "timeline" ? nativePaper : Color.clear).frame(width: 22, height: 22)).frame(width: 26, height: layoutStyle == "minimal" ? 36 : 44) }.disabled(!editable || saving).accessibilityLabel(fields.flag("done") ? "Reabrir subtarefa" : money ? "Registrar pagamento" : "Concluir subtarefa")
            VStack(alignment: .leading, spacing: layoutStyle == "minimal" ? 0 : 5) {
                TextField("Nome da subtarefa", text: Binding(get: { fields.text("text") }, set: { fields["text"] = .string($0) }), axis: .vertical).font(.system(size: layoutStyle == "minimal" ? 14 : 16, weight: layoutStyle == "cards" ? .medium : .regular)).strikethrough(fields.flag("done")).foregroundStyle(fields.flag("done") ? Color.secondary : Color.primary).lineLimit(1...8).frame(minHeight: layoutStyle == "minimal" ? 36 : 44).disabled(!editable)
                if showMetadata {
                    HStack(spacing: 8) {
                        NativeDateChip(fields: $fields, key: "remindAt", compact: true, enabled: editable && !saving)
                        if money { Button { if fields.flag("done") { values() } else { payment() } } label: { Text("Original: " + NativeDate.money(fields["amountCents"]?.number)).font(.system(size: 12, weight: .medium)).foregroundStyle(nativeBlue).lineLimit(1).minimumScaleFactor(0.8) }.disabled(!editable) }
                    }.padding(.bottom, 5)
                }
                if let until = NativeDate.parse(fields.text("pausedUntil")), until > Date() { Text("Pausada até " + until.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "pt_BR")))).font(.system(size: 11)).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if !showMetadata { Button("Data e horário") { date = true } }
                Button { attach() } label: { Label("Anexos e comprovantes", systemImage: "paperclip") }
                if money { if !fields.flag("done") { Button("Pagar / antecipar") { payment() } }; Button(fields.flag("done") ? "Valores original e pago" : "Alterar valor original") { if fields.flag("done") { values() } else { amount = true } } }
                Toggle("Repetir no próximo ciclo mensal", isOn: Binding(get: { fields["repeatMonthly"]?.bool ?? true }, set: { fields["repeatMonthly"] = .bool($0) }))
                if monthly && !fields.flag("done") {
                    if NativeDate.parse(fields.text("pausedUntil")).map({ $0 > Date() }) == true { Button("Retomar cobrança") { pause(0, true) } }
                    else { Menu("Pausar cobrança") { ForEach([1, 2, 3, 6, 12], id: \.self) { months in Button("\(months) mês(es)") { pause(months, false) } } } }
                }
                if canTransfer { Button("Transferir para outra tarefa") { transfer() } }
                Button("Remover subtarefa", role: .destructive) { remove() }
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 44) }.disabled(!editable || saving).accessibilityLabel("Mais opções da subtarefa")
        }.buttonStyle(.borderless).padding(.vertical, layoutStyle == "minimal" ? 0 : 6)
            .sheet(isPresented: $amount) { NativeMoneyOptions(fields: $fields, isCheck: true) }
            .sheet(isPresented: $date) { NavigationStack { Form { NativeDateField(fields: $fields, key: "remindAt", title: "Data e horário") }.navigationTitle("Subtarefa").toolbar { Button("Pronto") { date = false } } } }
    }
    @State private var date = false
}
