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
    var presentation = NativeCheckPresentation()
    var payment: () -> Void = {}
    var values: () -> Void = {}
    var pause: (Int, Bool) -> Void = { _, _ in }
    var transfer: () -> Void = {}
    var attach: () -> Void
    var remove: () -> Void
    @State private var amount = false
    @State private var date = false
    private var p: NativeCheckPresentation { presentation }
    private var done: Bool { fields.flag("done") }
    private var dueDate: Date? { NativeDate.parse(fields.text("remindAt")) }
    var body: some View {
        Group {
            switch p.style {
            case "cards": cardRow
            case "timeline": timelineRow
            case "ledger": ledgerRow
            case "minimal": minimalRow
            default: elegantRow
            }
        }.buttonStyle(.borderless)
            .sheet(isPresented: $amount) { NativeMoneyOptions(fields: $fields, isCheck: true) }
            .sheet(isPresented: $date) { NativeDateSheet(fields: $fields, key: "remindAt") }
    }

    // MARK: Styles
    private var elegantRow: some View {
        HStack(alignment: .top, spacing: 10) {
            check(size: p.compact ? 19 : 22, height: p.compact ? 34 : 40)
            VStack(alignment: .leading, spacing: p.compact ? 2 : 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    numberLabel
                    title(size: p.compact ? 15 : 16, weight: p.highlight ? .semibold : .regular, minHeight: p.compact ? 34 : 40)
                    if money && p.amounts { amountButton(size: 14, weight: .semibold) }
                }
                if (p.highlight && !done) || p.pills || p.metadata {
                    HStack(spacing: 6) {
                        if p.highlight && !done { badge("Próxima", color: nativeBlue, filled: true) }
                        if p.pills { badge(p.label(money: money), color: p.tint) }
                        if p.metadata { dateChip }
                    }.padding(.bottom, p.compact ? 2 : 4)
                }
                pausedNote
            }.frame(maxWidth: .infinity, alignment: .leading)
            menu
        }.padding(.vertical, p.compact ? 1 : 5).padding(.horizontal, p.highlight && !done ? 8 : 0)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.highlight && !done ? nativeBlue.opacity(0.07) : Color.clear))
    }
    private var cardRow: some View {
        VStack(alignment: .leading, spacing: p.compact ? 6 : 10) {
            HStack(alignment: .top, spacing: 10) {
                check(size: 22, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    if let number = p.number { Text("Nº \(number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                    title(size: 16, weight: .semibold, minHeight: 36)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if p.highlight && !done { badge("Próxima", color: nativeBlue, filled: true).padding(.top, 8) }
                else if p.pills { badge(p.label(money: money), color: p.tint).padding(.top, 8) }
                menu
            }
            if p.metadata || (money && p.amounts) {
                HStack(alignment: .bottom, spacing: 0) {
                    if p.metadata {
                        VStack(alignment: .leading, spacing: 1) { caption("Vencimento"); dateChip }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if money && p.amounts {
                        VStack(alignment: .trailing, spacing: 3) { caption(done ? (p.receive ? "Recebido" : "Pago") : "Valor"); amountButton(size: 17, weight: .bold) }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.padding(.leading, 34).padding(.trailing, 6)
            }
            pausedNote.padding(.leading, 34)
        }.padding(.vertical, p.compact ? 6 : 10).padding(.horizontal, 6)
    }
    private var timelineRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Text(dueDate.map { String(Calendar.current.component(.day, from: $0)) } ?? "–").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(done ? Color.secondary : p.tint == .secondary ? Color.primary : p.tint)
                Text(dueDate.map { $0.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "pt_BR"))).replacingOccurrences(of: ".", with: "").uppercased() } ?? "SEM").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }.frame(width: 40).padding(.top, 9)
            check(size: 20, height: 46, node: true)
            VStack(alignment: .leading, spacing: 3) {
                title(size: 15, weight: p.highlight ? .semibold : .medium, minHeight: 30)
                HStack(spacing: 6) {
                    if p.highlight && !done { badge("Próxima", color: nativeBlue, filled: true) }
                    if p.pills { badge(p.label(money: money), color: p.tint) }
                    if p.metadata, let dueDate, Calendar.current.component(.hour, from: dueDate) + Calendar.current.component(.minute, from: dueDate) > 0 {
                        Text(dueDate.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR")))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if money && p.amounts { amountButton(size: 13, weight: .semibold) }
                }
                pausedNote
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            menu
        }
    }
    private var ledgerRow: some View {
        HStack(spacing: 8) {
            Text(p.number.map { String(format: "%02d", $0) } ?? "").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            check(size: 17, height: 38)
            title(size: 14, weight: p.highlight ? .semibold : .regular, minHeight: 38).lineLimit(1...3)
            Button { date = true } label: {
                Text(dueDate.map { $0.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits).locale(Locale(identifier: "pt_BR"))) } ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(done ? Color.secondary : p.tint == .secondary ? Color.secondary : p.tint).lineLimit(1)
            }.frame(width: 66, alignment: .trailing).disabled(!editable || saving)
            if money { amountButton(size: 12, weight: .semibold, monospaced: true).frame(width: 84, alignment: .trailing) }
            menu
        }
    }
    private var minimalRow: some View {
        HStack(spacing: 8) {
            check(size: 18, height: 36)
            numberLabel
            title(size: 14, weight: .regular, minHeight: 36).lineLimit(1...3)
            if p.metadata, let dueDate { Text(dueDate.formatted(.dateTime.day().month(.twoDigits).locale(Locale(identifier: "pt_BR")))).font(.system(size: 11)).foregroundStyle(done ? Color.secondary : p.tint) }
            if money && p.amounts { amountButton(size: 12, weight: .medium) }
            menu
        }
    }

    // MARK: Parts
    private func check(size: CGFloat, height: CGFloat, node: Bool = false) -> some View {
        Button {
            if money && !done { payment() }
            else { fields["done"] = .bool(!done) }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: done ? .regular : .light))
                .foregroundStyle(done ? Color.green.opacity(0.75) : (p.state == "overdue" ? Color.red : nativeBlue))
                .background(Circle().fill(node ? nativePaper : Color.clear).frame(width: size + 2, height: size + 2))
                .frame(width: 26, height: height)
        }.disabled(!editable || saving).accessibilityLabel(done ? "Reabrir subtarefa" : money ? "Registrar pagamento" : "Concluir subtarefa")
    }
    private func title(size: CGFloat, weight: Font.Weight, minHeight: CGFloat) -> some View {
        TextField("Nome da subtarefa", text: Binding(get: { fields.text("text") }, set: { fields["text"] = .string($0) }), axis: .vertical)
            .font(.system(size: size, weight: weight)).strikethrough(done, color: .secondary)
            .foregroundStyle(done ? Color.secondary : Color.primary).lineLimit(1...8)
            .frame(minHeight: minHeight).disabled(!editable)
    }
    @ViewBuilder private var numberLabel: some View {
        if let number = p.number { Text(String(format: "%02d", number)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary) }
    }
    private var amountText: String {
        if done, let paid = fields["paidAmountCents"]?.number { return NativeDate.money(paid) }
        return fields["amountCents"]?.number.map { NativeDate.money($0) } ?? "Definir valor"
    }
    private func amountButton(size: CGFloat, weight: Font.Weight, monospaced: Bool = false) -> some View {
        Button { if done { values() } else { payment() } } label: {
            Text(amountText).font(.system(size: size, weight: weight, design: monospaced ? .monospaced : .rounded))
                .foregroundStyle(done ? Color.secondary : Color.primary).lineLimit(1).minimumScaleFactor(0.7).fixedSize(horizontal: !monospaced, vertical: false)
        }.disabled(!editable).accessibilityLabel((done ? "Valor pago " : "Valor ") + amountText)
    }
    private var dateChip: some View { NativeDateChip(fields: $fields, key: "remindAt", compact: true, enabled: editable && !saving).frame(height: 24) }
    private func badge(_ text: String, color: Color, filled: Bool = false) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).lineLimit(1)
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filled ? color : color.opacity(0.12), in: Capsule())
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .bold)).textCase(.uppercase).foregroundStyle(.secondary) }
    @ViewBuilder private var pausedNote: some View {
        if let until = NativeDate.parse(fields.text("pausedUntil")), until > Date() { Text("Pausada até " + until.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "pt_BR")))).font(.system(size: 11)).foregroundStyle(.orange) }
    }
    private var menu: some View {
        Menu {
            Button { date = true } label: { Label("Data e horário", systemImage: "calendar") }
            Button { attach() } label: { Label("Anexos e comprovantes", systemImage: "paperclip") }
            if money { if !done { Button("Pagar / antecipar") { payment() } }; Button(done ? "Valores original e pago" : "Alterar valor original") { if done { values() } else { amount = true } } }
            Toggle("Repetir no próximo ciclo mensal", isOn: Binding(get: { fields["repeatMonthly"]?.bool ?? true }, set: { fields["repeatMonthly"] = .bool($0) }))
            if monthly && !done {
                if NativeDate.parse(fields.text("pausedUntil")).map({ $0 > Date() }) == true { Button("Retomar cobrança") { pause(0, true) } }
                else { Menu("Pausar cobrança") { ForEach([1, 2, 3, 6, 12], id: \.self) { months in Button("\(months) mês(es)") { pause(months, false) } } } }
            }
            if canTransfer { Button("Transferir para outra tarefa") { transfer() } }
            Button("Remover subtarefa", role: .destructive) { remove() }
        } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 22, height: p.compact || p.style == "ledger" ? 36 : 40) }.disabled(!editable || saving).accessibilityLabel("Mais opções da subtarefa")
    }
}
