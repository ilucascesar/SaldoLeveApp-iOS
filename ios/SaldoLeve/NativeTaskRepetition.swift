import SwiftUI

struct NativeTaskRepetition: View {
    @Binding var fields: JSONObject
    @Environment(\.dismiss) private var dismiss
    @State private var choice = "none"
    @State private var frequency = "monthly"
    @State private var interval = 1
    @State private var initialized = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach([("none","Não repetir"),("1","A cada mês"),("6","A cada 6 meses"),("12","A cada 12 meses"),("custom","Outro")],id:\.0) { value, title in
                        Button { choice = value } label: {
                            HStack { Label(title,systemImage:value == "none" ? "repeat.circle" : "repeat"); Spacer(); if choice == value { Image(systemName:"checkmark").foregroundStyle(nativeBlue) } }.foregroundStyle(.primary)
                        }
                    }
                } footer: { Text("Ao concluir a tarefa e suas subtarefas pendentes, o histórico é mantido e as datas avançam pelo intervalo escolhido. Você pode desmarcar subtarefas que não devem voltar no próximo ciclo.") }
                if choice == "custom" {
                    Section("Personalizar") {
                        Stepper("A cada \(interval)",value:$interval,in:1...365)
                        Picker("Período",selection:$frequency) {
                            Text("Dia(s)").tag("daily");Text("Semana(s)").tag("weekly");Text("Mês(es)").tag("monthly");Text("Ano(s)").tag("yearly")
                        }
                    }
                }
            }.navigationTitle("Repetir tarefa").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Aplicar") {
                    fields["repeat"] = .object(["frequency":.string(choice == "none" ? "none" : choice == "custom" ? frequency : "monthly"),"interval":.number(Double(Int(choice) ?? (choice == "custom" ? interval : 1)))])
                    dismiss()
                }.bold() }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                let value = fields.record("repeat"); frequency = value.text("frequency").isEmpty ? "none" : value.text("frequency"); interval = max(1,value.integer("interval"))
                choice = frequency == "none" ? "none" : frequency == "monthly" && [1,6,12].contains(interval) ? String(interval) : "custom"
                if frequency == "none" { frequency = "monthly" }
            }
        }.presentationDetents([.medium,.large])
    }
}
