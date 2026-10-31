import SwiftUI
import UIKit

struct NativeWidgetSettings: View {
    @ObservedObject var store: NativeStore
    @State private var devices: [JSONObject] = []
    @State private var settings: JSONObject = [:]
    @State private var generated: JSONObject?
    @State private var busy = false
    @State private var issue: String?
    @State private var revoke: NativeRecord?
    private var selected: [String] { settings["listIds"]?.array.map(\.string) ?? [] }
    var body: some View {
        Form {
            Section {
                Label("Widgets do SaldoLeve", systemImage: "square.grid.2x2.fill").font(.headline)
                Text("Lista de Hoje, Atrasadas e Próximas. Tocar no widget abre a Agenda.").font(.subheadline).foregroundStyle(.secondary)
                NativeWidgetLayoutPreview(store: store, display: display)
                if #available(iOS 27.0, *) {
                    Text("Tamanhos: Pequeno, Médio, Grande e Extra grande vertical (tela cheia, 4×6). O vertical usa toda a altura disponível; o limite de linhas abaixo vale para os outros tamanhos.").font(.footnote).foregroundStyle(.secondary)
                    Text("Para instalar diretamente o maior: segure uma área vazia da Tela de Início → Editar → Adicionar Widget → SaldoLeve → SaldoLeve · Lista ampliada. Ele ocupa uma página inteira. Se um widget antigo não mudar de tamanho, adicione essa opção nova e copie o código de conexão abaixo.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Pequeno, Médio e Grande estão disponíveis neste iPhone. O Extra grande vertical requer iOS 27 ou posterior.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Tamanho na Tela de Início") {
                Text("O tamanho é escolhido na Tela de Início do iPhone. Quantidade de linhas e tamanho do texto ajustam o conteúdo dentro do widget; não mudam sua área na tela.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Layout e conteúdo do widget") {
                Picker("Mostrar", selection: text("scope", fallback: "focus")) { Text("Meu dia").tag("focus"); Text("Todas as pendentes").tag("all"); Text("Só hoje").tag("today"); Text("Só atrasadas").tag("overdue"); Text("Próximas").tag("next"); Text("A pagar").tag("pay"); Text("A receber").tag("receive"); Text("Sem data").tag("undated") }
                Stepper("Até \(integer("count", fallback: 10).wrappedValue) linhas", value: integer("count", fallback: 10), in: 1...30).accessibilityIdentifier("widget-row-limit")
                Stepper("Texto: \(integer("textSize", fallback: 12).wrappedValue) pt", value: integer("textSize", fallback: 12), in: 11...16)
                Stepper("Próximas: \(integer("upcomingDays", fallback: 7).wrappedValue) dias", value: integer("upcomingDays", fallback: 7), in: 1...30)
                Toggle("Espaçamento compacto", isOn: flag("compact"))
                Toggle("Separar lista em grupos", isOn: flag("groupByDate"))
                Toggle("Mostrar datas", isOn: flag("showDates"))
                Toggle("Mostrar nome das subtarefas", isOn: flag("showSubtasks"))
                Text("O limite de linhas se ajusta ao espaço disponível no tamanho escolhido. Confira o resultado no simulador acima antes de salvar.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Grupos de Meu dia") {
                Toggle("Hoje", isOn: flag("showToday"))
                Toggle("Atrasadas", isOn: flag("showOverdue"))
                Toggle("Próximas", isOn: flag("showUpcoming"))
                Text("Esses grupos controlam o filtro Meu dia. Pelo menos um permanece visível.").font(.footnote).foregroundStyle(.secondary)
                Button("Salvar layout dos widgets") { saveSettings() }.disabled(busy || !store.canWrite)
            }
            Section("Adicionar ao iPhone") {
                Text("1. Gere e copie um código de conexão abaixo.\n2. Na tela inicial, segure uma área vazia e escolha Editar → Adicionar Widget → SaldoLeve.\n3. Escolha o formato desejado; no iOS 27 ou posterior, Extra grande vertical é o mais alto. Segure o widget → Editar Widget e cole o código em Conexão.\n4. Mantenha Usar configurações do app ativado para aplicar o layout salvo aqui. Desative para personalizar cada widget separadamente no iOS.").font(.subheadline)
                Button("Gerar código para este iPhone") { create() }.disabled(busy || !store.canWrite)
                if let generated {
                    Button { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: generated.text("token")]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]); store.message = "Código copiado por 5 minutos. Cole em Conexão nas opções do widget." } label: { Label("Copiar código de conexão", systemImage: "doc.on.doc") }
                    Text("Este código permite consultar tarefas por até 180 dias. Você pode revogá-lo abaixo. Não inclui sua senha nem permite registrar pagamentos.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Conteúdo permitido nos widgets") {
                Toggle("Permitir exibir valores", isOn: Binding(get: { settings.flag("showAmounts") }, set: { settings["showAmounts"] = .bool($0) }))
                Picker("Prioridade", selection: Binding(get: { settings.text("priority").isEmpty ? "overdue" : settings.text("priority") }, set: { settings["priority"] = .string($0) })) { Text("Atrasadas primeiro").tag("overdue"); Text("Hoje primeiro").tag("today"); Text("Por data").tag("due") }
                Text("Nenhuma categoria marcada permite todas as suas categorias. No editor de cada widget, você pode escolher uma delas pelo código indicado.").font(.footnote).foregroundStyle(.secondary)
                ForEach(store.snapshot.lists.filter { !$0.archived }) { category in
                    Toggle("\(category.name) · código \(category.id)", isOn: Binding(get: { selected.contains(category.id) }, set: { enabled in var ids = selected.filter { $0 != category.id }; if enabled { ids.append(category.id) }; settings["listIds"] = .array(ids.compactMap { Double($0).map(JSONValue.number) }) }))
                }
                Button("Salvar preferências dos widgets") { saveSettings() }.disabled(busy || !store.canWrite)
            }
            Section("Conexões") {
                ForEach(devices.map(NativeRecord.init)) { device in
                    VStack(alignment: .leading, spacing: 6) { Text(device.fields.text("name")).font(.headline); Text(device.fields.flag("active") ? "Ativa até " + String(device.fields.text("expiresAt").prefix(10)) : "Expirada").font(.caption).foregroundStyle(.secondary); Button("Revogar conexão", role: .destructive) { revoke = device }.disabled(busy) }
                }
            }
            Section { Text("O iOS escolhe quando atualizar widgets; o pedido de atualização é a cada 30 minutos. Sem rede, eles podem mostrar a última consulta com a data de atualização. Ao sair da conta, revogue os códigos para ocultar também os widgets já conectados. Ao instalar o IPA, mantenha a extensão SaldoLeveWidgets.").font(.footnote).foregroundStyle(.secondary) }
            if let issue { Section { Text(issue).foregroundStyle(.red) } }
        }.navigationTitle("Widgets").navigationBarTitleDisplayMode(.inline).task { await reload() }
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Salvar") { saveSettings() }.disabled(busy || !store.canWrite) } }
            .confirmationDialog("Revogar esta conexão?", isPresented: Binding(get: { revoke != nil }, set: { if !$0 { revoke = nil } }), titleVisibility: .visible) { Button("Revogar conexão", role: .destructive) { if let revoke { Task { await revokeConnection(revoke.id) } }; revoke = nil } } message: { Text("Os widgets que usam esse código precisarão de uma nova conexão.") }
    }
    private func reload() async {
        if store.isPreview { settings = ["display": .object([:])]; return }
        do { let response = try await store.api.get(JSONObject.self, action: "widget_devices"); devices = response.objects("devices"); settings = try await store.api.get(JSONObject.self, action: "widget_settings"); issue = nil }
        catch { issue = "Atualize a API de widgets na HostGator. " + error.localizedDescription }
    }
    private func create() { busy = true; Task { defer { busy = false }; do { generated = try await store.api.post(action: "widget_create", body: ["name": .string("Widgets · " + UIDevice.current.name)]); await reload() } catch { issue = error.localizedDescription } } }
    private func saveSettings() { busy = true; Task { defer { busy = false }; do { settings = try await store.api.post(action: "widget_save_settings", body: settings); UserDefaults.standard.set(settings.record("display").integer("upcomingDays"), forKey: "nativeWidgetHorizon"); store.message = "Preferências salvas. Os widgets usarão esses dados na próxima atualização." } catch { issue = error.localizedDescription } } }
    private func revokeConnection(_ id: String) async { busy = true; defer { busy = false }; do { _ = try await store.api.post(action: "widget_revoke", body: ["id": .string(id)]); if generated?.text("id") == id { generated = nil }; await reload() } catch { issue = error.localizedDescription } }
    private var display: JSONObject { settings.record("display") }
    private func setDisplay(_ key: String, _ value: JSONValue) { var next = display; next[key] = value; settings["display"] = .object(next) }
    private func text(_ key: String, fallback: String) -> Binding<String> { Binding(get: { display.text(key).isEmpty ? fallback : display.text(key) }, set: { setDisplay(key, .string($0)) }) }
    private func integer(_ key: String, fallback: Int) -> Binding<Int> { Binding(get: { display[key] == nil ? fallback : display.integer(key) }, set: { setDisplay(key, .number(Double($0))) }) }
    private func flag(_ key: String) -> Binding<Bool> { Binding(get: { display[key] != .bool(false) }, set: { setDisplay(key, .bool($0)) }) }
}
// Widget simulator: a Home Screen grid (4 × 6 icons) showing the area each
// size occupies and the list the current (unsaved) options would display.
struct NativeWidgetLayoutPreview: View {
    @ObservedObject var store: NativeStore
    let display: JSONObject
    @State private var daily: [String: [NativeTask]] = [:]
    @State private var size = "portrait"
    private let sizes = ["small", "medium", "large", "portrait"]
    private let names = ["small": "Pequeno", "medium": "Médio", "large": "Grande", "portrait": "Tela cheia"]
    private let spans = ["small": (2, 2), "medium": (4, 2), "large": (4, 4), "portrait": (4, 6)]
    private let cell: CGFloat = 66
    private var textSize: CGFloat { CGFloat(display["textSize"] == nil ? 12 : min(16, max(11, display.integer("textSize")))) }
    private var compact: Bool { display["compact"] != .bool(false) }
    private var showDates: Bool { display["showDates"] != .bool(false) }
    private var states: [String] {
        let all = [("today", "showToday"), ("overdue", "showOverdue"), ("upcoming", "showUpcoming")]
        let chosen = all.filter { display[$0.1] != .bool(false) }.map { $0.0 }
        return chosen.isEmpty ? ["today"] : chosen
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Simulador do widget", systemImage: "iphone").font(.subheadline.weight(.semibold)).foregroundStyle(nativeBlue)
            HStack(spacing: 6) {
                ForEach(sizes, id: \.self) { key in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { size = key } } label: {
                        VStack(spacing: 2) { Text(names[key] ?? key).font(.system(size: 12, weight: .semibold)); Text("\(spans[key]?.0 ?? 0)×\(spans[key]?.1 ?? 0)").font(.system(size: 10)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 7).foregroundStyle(size == key ? Color.white : Color.primary).background(size == key ? nativeBlue : nativePaper, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityIdentifier("widget-simulator-" + key)
                }
            }
            homeScreen.frame(maxWidth: .infinity)
            Text("Toque no widget abre a Agenda. O tamanho é escolhido na Tela de Início; as opções abaixo mudam o conteúdo. Salve para aplicar.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
            .task(id: store.taskIndex.revision.uuidString + "|" + String(display.integer("upcomingDays"))) {
                let snapshot = store.snapshot, days = display.integer("upcomingDays") == 0 ? 7 : display.integer("upcomingDays")
                let result = await Task.detached(priority: .userInitiated) { Dictionary(uniqueKeysWithValues: ["today", "overdue", "upcoming"].map { ($0, NativeDailyQuery.select(snapshot, state: $0, days: days)) }) }.value
                if !Task.isCancelled { daily = result }
            }
    }
    private var homeScreen: some View {
        let span = spans[size] ?? (4, 4)
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [nativeBlue.opacity(0.55), Color.purple.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(row < span.1 && column < span.0 ? 0 : 0.35)).frame(width: 46, height: 46).frame(width: cell, height: cell)
                        }
                    }
                }
            }
            widget(width: CGFloat(span.0) * cell - 12, height: CGFloat(span.1) * cell - 12).padding(6)
        }.frame(width: cell * 4, height: cell * 6).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    private func widget(width: CGFloat, height: CGFloat) -> some View {
        let expanded = size == "large" || size == "portrait"
        let grouped = expanded && display["groupByDate"] != .bool(false)
        let rowHeight = textSize + (compact ? 7 : 10) + (showDates && !compact ? 12 : 0)
        let pool = states.flatMap { state in (daily[state] ?? []).map { (state, $0) } }
        let groupCount = grouped ? states.filter { !(daily[$0] ?? []).isEmpty }.count : 0
        let reserved = 44 + CGFloat(groupCount * 16)
        let requested = size == "portrait" ? 30 : (display["count"] == nil ? 10 : display.integer("count"))
        let capacity = max(0, min(requested, Int((height - reserved) / rowHeight)))
        let rows = Array(pool.prefix(capacity))
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Image(systemName: "checklist").foregroundStyle(nativeBlue); Text("Meu dia").font(.system(size: 13, weight: .semibold)); Spacer() }.frame(height: 20)
            if rows.isEmpty { Spacer(minLength: 0); Label("Tudo em ordem", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, entry in
                if grouped && (offset == 0 || rows[offset - 1].0 != entry.0) { Text(["today": "Hoje", "overdue": "Atrasadas", "upcoming": "Próximas"][entry.0] ?? "").font(.system(size: 10, weight: .semibold)).foregroundStyle(entry.0 == "overdue" ? Color.red : Color.secondary).frame(height: 12) }
                HStack(spacing: 7) {
                    Circle().stroke(entry.0 == "overdue" ? Color.red : nativeBlue, lineWidth: 1.2).frame(width: 11, height: 11)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(entry.1)).font(.system(size: textSize, weight: .medium)).lineLimit(1)
                        if showDates && !compact { Text(entry.1.listDate.map { NativeDateLabel.text($0) } ?? "Sem data").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if showDates && compact { Text(entry.1.listDate.map { NativeDateLabel.text($0) } ?? "").font(.system(size: 9)).foregroundStyle(entry.0 == "overdue" ? Color.red : Color.secondary).lineLimit(1) }
                }.frame(height: rowHeight)
            }
            Spacer(minLength: 0)
            Text("Atualizado agora").font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(12).frame(width: width, height: height, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    private func title(_ task: NativeTask) -> String {
        guard display["showSubtasks"] != .bool(false), let check = task.checks.first(where: { !$0.done }) else { return task.title }
        return task.title + " · " + check.title
    }
}
