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
    static let accents = ["blue", "green", "purple", "orange", "pink", "teal", "gray"]
    static let accentNames = ["blue": "Azul", "green": "Verde", "purple": "Roxo", "orange": "Laranja", "pink": "Rosa", "teal": "Turquesa", "gray": "Cinza"]
    static func accentColor(_ name: String) -> Color { ["green": Color.green, "purple": .purple, "orange": .orange, "pink": .pink, "teal": .teal, "gray": .gray][name] ?? .blue }
    var body: some View {
        Form {
            Section {
                if #available(iOS 27.0, *) {
                    Text("SaldoLeve: Pequeno, Médio e Grande. SaldoLeve · Lista ampliada: Extra grande vertical (tela cheia, 4×6), que usa toda a altura disponível.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Pequeno, Médio e Grande estão disponíveis neste iPhone. O Extra grande vertical requer iOS 27 ou posterior.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("O tamanho é escolhido na Tela de Início. As opções abaixo mudam o conteúdo e a aparência; confira no simulador fixo acima.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Conteúdo") {
                Picker("Mostrar", selection: text("scope", fallback: "focus")) { Text("Meu dia").tag("focus"); Text("Todas as pendentes").tag("all"); Text("Só hoje").tag("today"); Text("Só atrasadas").tag("overdue"); Text("Próximas").tag("next"); Text("A pagar").tag("pay"); Text("A receber").tag("receive"); Text("Sem data").tag("undated") }
                Stepper("Até \(integer("count", fallback: 10).wrappedValue) linhas", value: integer("count", fallback: 10), in: 1...30).accessibilityIdentifier("widget-row-limit")
                Stepper("Próximas: \(integer("upcomingDays", fallback: 7).wrappedValue) dias", value: integer("upcomingDays", fallback: 7), in: 1...30)
                Toggle("Mostrar datas", isOn: flag("showDates"))
                Toggle("Mostrar nome das subtarefas", isOn: flag("showSubtasks"))
            }
            Section {
                Toggle("Separar lista em grupos", isOn: flag("groupByDate"))
                Toggle("Atrasadas antes de Hoje", isOn: flag("overdueFirst", fallback: false))
                Toggle("Quantidade ao lado do grupo", isOn: flag("groupCounts"))
                Toggle("Hoje", isOn: flag("showToday"))
                Toggle("Atrasadas", isOn: flag("showOverdue"))
                Toggle("Próximas", isOn: flag("showUpcoming"))
            } header: { Text("Grupos") } footer: { Text("Hoje, Atrasadas e Próximas controlam o filtro Meu dia; pelo menos um permanece visível. Grupos aparecem nos tamanhos Grande e Tela cheia.") }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cor de destaque")
                    HStack(spacing: 10) {
                        ForEach(Self.accents, id: \.self) { name in
                            let chosen = text("accent", fallback: "blue").wrappedValue == name
                            Button { text("accent", fallback: "blue").wrappedValue = name } label: {
                                Circle().fill(Self.accentColor(name)).frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(chosen ? 0.85 : 0), lineWidth: 2).padding(-4))
                            }.buttonStyle(.plain).accessibilityLabel(Self.accentNames[name] ?? name).accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }
                Picker("Fundo", selection: text("background", fallback: "system")) { Text("Padrão do iPhone").tag("system"); Text("Levemente colorido").tag("tinted"); Text("Na cor de destaque").tag("accent") }
                Picker("Marcador", selection: text("marker", fallback: "circle")) { Text("Círculo").tag("circle"); Text("Ponto").tag("dot"); Text("Barra").tag("bar"); Text("Nenhum").tag("none") }
                Picker("Peso do texto", selection: text("fontWeight", fallback: "medium")) { Text("Leve").tag("regular"); Text("Médio").tag("medium"); Text("Negrito").tag("semibold") }
                Stepper("Texto: \(integer("textSize", fallback: 12).wrappedValue) pt", value: integer("textSize", fallback: 12), in: 11...16)
                Toggle("Espaçamento compacto", isOn: flag("compact"))
                Toggle("Linhas separadoras", isOn: flag("separators", fallback: false))
                Toggle("Título no topo", isOn: flag("showHeader", fallback: false))
                Toggle("Horário da atualização no rodapé", isOn: flag("showFooter"))
            } header: { Text("Aparência") } footer: { Text("Sem o título, os grupos Atrasadas e Próximas já identificam a lista. Sem conexão, o rodapé sempre aparece com o horário da última consulta.") }
            Section { Button("Salvar layout dos widgets") { saveSettings() }.disabled(busy || !store.canWrite) }
            Section("Adicionar ao iPhone") {
                Text("1. Gere e copie um código de conexão abaixo.\n2. Na Tela de Início, segure uma área vazia e escolha Editar → Adicionar Widget → SaldoLeve.\n3. Escolha SaldoLeve (Pequeno, Médio ou Grande) ou SaldoLeve · Lista ampliada (tela cheia). Segure o widget → Editar Widget e cole o código em Conexão.\n4. Mantenha Usar configurações do app ativado para aplicar o layout salvo aqui.").font(.subheadline)
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
        }
        // The simulator stays docked above the options, so every change can be
        // seen without scrolling back to the top.
        .safeAreaInset(edge: .top, spacing: 0) { NativeWidgetLayoutPreview(store: store, display: display) }
        .navigationTitle("Widgets").navigationBarTitleDisplayMode(.inline).task { await reload() }
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
    private func flag(_ key: String, fallback: Bool = true) -> Binding<Bool> { Binding(get: { display[key]?.bool ?? fallback }, set: { setDisplay(key, .bool($0)) }) }
}

// Widget simulator: a Home Screen grid (4 × 6 icons) showing the area each
// size occupies and the list the current (unsaved) options would display.
// It is docked above the options, scaled down beside the size buttons, and
// can be enlarged or collapsed.
struct NativeWidgetLayoutPreview: View {
    @ObservedObject var store: NativeStore
    let display: JSONObject
    @State private var daily: [String: [NativeTask]] = [:]
    @AppStorage("nativeWidgetPreviewSize") private var size = "portrait"
    @AppStorage("nativeWidgetPreviewOpen") private var open = true
    @AppStorage("nativeWidgetPreviewZoom") private var zoom = false
    private let sizes = ["small", "medium", "large", "portrait"]
    private let names = ["small": "Pequeno", "medium": "Médio", "large": "Grande", "portrait": "Tela cheia"]
    private let spans = ["small": (2, 2), "medium": (4, 2), "large": (4, 4), "portrait": (4, 6)]
    private let cell: CGFloat = 66
    private var textSize: CGFloat { CGFloat(display["textSize"] == nil ? 12 : min(16, max(11, display.integer("textSize")))) }
    private func flag(_ key: String, _ fallback: Bool = true) -> Bool { display[key]?.bool ?? fallback }
    private func choice(_ key: String, _ fallback: String) -> String { display.text(key).isEmpty ? fallback : display.text(key) }
    private var accent: Color { NativeWidgetSettings.accentColor(choice("accent", "blue")) }
    private var states: [String] {
        let order = flag("overdueFirst", false) ? ["overdue", "today", "upcoming"] : ["today", "overdue", "upcoming"]
        let keys = ["today": "showToday", "overdue": "showOverdue", "upcoming": "showUpcoming"]
        let chosen = order.filter { flag(keys[$0] ?? "") }
        return chosen.isEmpty ? ["today"] : chosen
    }
    private var scale: CGFloat { zoom ? 0.78 : 0.56 }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Simulador", systemImage: "iphone").font(.subheadline.weight(.semibold)).foregroundStyle(nativeBlue)
                Spacer()
                if open { Button { withAnimation(.easeInOut(duration: 0.2)) { zoom.toggle() } } label: { Image(systemName: zoom ? "minus.magnifyingglass" : "plus.magnifyingglass") }.accessibilityLabel(zoom ? "Reduzir simulador" : "Ampliar simulador") }
                Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: { Image(systemName: open ? "chevron.up.circle.fill" : "chevron.down.circle.fill").font(.title3) }
                    .accessibilityLabel(open ? "Recolher simulador" : "Mostrar simulador").accessibilityIdentifier("widget-simulator-toggle")
            }
            if open {
                HStack(alignment: .top, spacing: 12) {
                    homeScreen.scaleEffect(scale, anchor: .topLeading).frame(width: cell * 4 * scale, height: cell * 6 * scale, alignment: .topLeading)
                    VStack(spacing: 6) { ForEach(sizes, id: \.self) { sizeButton($0) } }.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .task(id: store.taskIndex.revision.uuidString + "|" + String(display.integer("upcomingDays"))) {
            let snapshot = store.snapshot, days = display.integer("upcomingDays") == 0 ? 7 : display.integer("upcomingDays")
            let result = await Task.detached(priority: .userInitiated) { Dictionary(uniqueKeysWithValues: ["today", "overdue", "upcoming"].map { ($0, NativeDailyQuery.select(snapshot, state: $0, days: days)) }) }.value
            if !Task.isCancelled { daily = result }
        }
    }
    private func sizeButton(_ key: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { size = key } } label: {
            VStack(spacing: 2) { Text(names[key] ?? key).font(.system(size: 12, weight: .semibold)); Text("\(spans[key]?.0 ?? 0)×\(spans[key]?.1 ?? 0)").font(.system(size: 10)) }
                .frame(maxWidth: .infinity).padding(.vertical, 6).foregroundStyle(size == key ? Color.white : Color.primary).background(size == key ? nativeBlue : nativePaper, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityIdentifier("widget-simulator-" + key)
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
    @ViewBuilder private var surface: some View {
        switch choice("background", "system") {
        case "tinted": ZStack { Color(uiColor: .systemBackground); accent.opacity(0.10) }
        case "accent": ZStack { Color(uiColor: .systemBackground); LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing) }
        default: Color(uiColor: .systemBackground)
        }
    }
    @ViewBuilder private func marker(_ state: String, height: CGFloat) -> some View {
        let color = state == "overdue" ? Color.red : accent
        switch choice("marker", "circle") {
        case "dot": Circle().fill(color).frame(width: 6, height: 6).frame(width: 11)
        case "bar": RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: max(10, height - 8)).frame(width: 11)
        case "none": EmptyView()
        default: Circle().stroke(color, lineWidth: 1.2).frame(width: 11, height: 11)
        }
    }
    private func widget(width: CGFloat, height: CGFloat) -> some View {
        let expanded = size == "large" || size == "portrait"
        let grouped = expanded && flag("groupByDate")
        let compact = flag("compact"), showDates = flag("showDates"), header = flag("showHeader", false), footer = flag("showFooter")
        let weight: Font.Weight = ["regular": Font.Weight.regular, "semibold": .semibold][choice("fontWeight", "medium")] ?? .medium
        let rowHeight = textSize + (compact ? 7 : 10) + (showDates && !compact ? 12 : 0)
        let pool = states.flatMap { state in (daily[state] ?? []).map { (state, $0) } }
        let groupCount = grouped ? states.filter { !(daily[$0] ?? []).isEmpty }.count : 0
        let reserved = 24 + (header ? 24 : 0) + (footer ? 16 : 0) + CGFloat(groupCount * 16)
        let requested = size == "portrait" ? 30 : (display["count"] == nil ? 10 : display.integer("count"))
        let capacity = max(0, min(requested, Int((height - reserved) / rowHeight)))
        let rows = Array(pool.prefix(capacity))
        return VStack(alignment: .leading, spacing: 4) {
            if header { HStack { Image(systemName: "checklist").foregroundStyle(accent); Text("Meu dia").font(.system(size: 13, weight: .semibold)); Spacer() }.frame(height: 20) }
            if rows.isEmpty { Spacer(minLength: 0); Label("Tudo em ordem", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, entry in
                let starts = offset == 0 || rows[offset - 1].0 != entry.0
                if grouped && starts {
                    HStack(spacing: 4) {
                        Text(["today": "Hoje", "overdue": "Atrasadas", "upcoming": "Próximas"][entry.0] ?? "").font(.system(size: 10, weight: .semibold)).foregroundStyle(entry.0 == "overdue" ? Color.red : entry.0 == "today" ? accent : Color.secondary)
                        if flag("groupCounts") { Text("\((daily[entry.0] ?? []).count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                    }.frame(height: 12)
                }
                HStack(spacing: 7) {
                    marker(entry.0, height: rowHeight)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(entry.1)).font(.system(size: textSize, weight: weight)).lineLimit(1)
                        if showDates && !compact { Text(entry.1.listDate.map { NativeDateLabel.text($0) } ?? "Sem data").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    if showDates && compact { Text(entry.1.listDate.map { NativeDateLabel.text($0) } ?? "").font(.system(size: 9)).foregroundStyle(entry.0 == "overdue" ? Color.red : Color.secondary).lineLimit(1) }
                }.frame(height: rowHeight)
                    .overlay(alignment: .top) { if flag("separators", false) && !starts { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) } }
            }
            Spacer(minLength: 0)
            if footer { Text("Atualizado agora").font(.system(size: 9)).foregroundStyle(.secondary) }
        }.padding(12).frame(width: width, height: height, alignment: .topLeading)
            .background { surface.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
    }
    private func title(_ task: NativeTask) -> String {
        guard flag("showSubtasks"), let check = task.checks.first(where: { !$0.done }) else { return task.title }
        return task.title + " · " + check.title
    }
}
