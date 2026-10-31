import WidgetKit
import SwiftUI
import AppIntents
import CryptoKit

enum SaldoWidgetContent: String, AppEnum {
    case list, summary, agenda
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Conteúdo"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.list: "Lista de tarefas", .summary: "Lista e subtotais", .agenda: "Agenda por data"]
}
enum SaldoWidgetScope: String, AppEnum {
    case focus, all, today, overdue, next, pay, receive, undated
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Filtro"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.focus: "Hoje, atrasadas e próximas", .all: "Todas as pendentes", .today: "Hoje", .overdue: "Atrasadas", .next: "Próximos dias", .pay: "A pagar", .receive: "A receber", .undated: "Sem data"]
    var label: String { switch self { case .focus: return "Meu dia"; case .all: return "Pendências"; case .today: return "Hoje"; case .overdue: return "Atrasadas"; case .next: return "Próximos dias"; case .pay: return "A pagar"; case .receive: return "A receber"; case .undated: return "Sem data" } }
}
enum SaldoWidgetColor: String, AppEnum {
    case blue, green, purple, orange
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Cor"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.blue: "Azul", .green: "Verde", .purple: "Roxo", .orange: "Laranja"]
    var color: Color { switch self { case .blue: return .blue; case .green: return .green; case .purple: return .purple; case .orange: return .orange } }
}
struct SaldoWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configurar SaldoLeve"
    static var description = IntentDescription("Escolha o conteúdo e conecte este widget à sua conta.")
    @Parameter(title: "Conexão", default: "") var connection: String
    @Parameter(title: "Conteúdo", default: .list) var content: SaldoWidgetContent
    @Parameter(title: "Usar configurações do app", default: true) var useAppSettings: Bool
    @Parameter(title: "Filtro", default: .focus) var scope: SaldoWidgetScope
    @Parameter(title: "Categoria (código opcional)", default: "") var category: String
    @Parameter(title: "Título personalizado", default: "") var customTitle: String
    @Parameter(title: "Mostrar valores", default: false) var showAmounts: Bool
    @Parameter(title: "Cor", default: .blue) var color: SaldoWidgetColor
    @Parameter(title: "Quantidade de itens (1–30)", default: 10) var count: Int
    @Parameter(title: "Espaçamento compacto", default: true) var compact: Bool
    @Parameter(title: "Tamanho do texto (11–16)", default: 12) var textSize: Int
    @Parameter(title: "Subtotais de tarefas", default: true) var showSubtotals: Bool
    @Parameter(title: "Mostrar datas", default: true) var showDates: Bool
    @Parameter(title: "Mostrar subtarefas", default: true) var showSubtasks: Bool
    @Parameter(title: "Agrupar por prazo", default: true) var groupByDate: Bool
    @Parameter(title: "Próximos dias (1–30)", default: 7) var upcomingDays: Int
}
struct SaldoWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: SaldoWidgetConfiguration
    let feed: SaldoWidgetFeed?
    var error: String? = nil
    var cached = false
}
private final class WidgetNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct SaldoWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SaldoWidgetEntry { .init(date: Date(), configuration: .init(), feed: .sample) }
    func snapshot(for configuration: SaldoWidgetConfiguration, in context: Context) async -> SaldoWidgetEntry { context.isPreview ? .init(date: Date(), configuration: configuration, feed: .sample) : await load(configuration) }
    func timeline(for configuration: SaldoWidgetConfiguration, in context: Context) async -> Timeline<SaldoWidgetEntry> {
        let entry = await load(configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
    private func load(_ configuration: SaldoWidgetConfiguration) async -> SaldoWidgetEntry {
        let token = configuration.connection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^SLW1\.[1-9][0-9]{0,17}\.[a-f0-9]{32}\.[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            return .init(date: Date(), configuration: configuration, feed: nil, error: "Gere um código em SaldoLeve → Configurações → Widgets e cole em Editar Widget → Conexão.")
        }
        let identifier = SHA256.hash(data: Data((token + "|" + configuration.scope.rawValue + "|" + configuration.category + "|" + String(configuration.useAppSettings) + "|" + String(configuration.upcomingDays)).utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(identifier + ".json")
        do {
            guard let configURL = Bundle.main.url(forResource: "config", withExtension: "json"),
                  let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: configURL))["serverURL"],
                  let server = URL(string: raw), server.scheme == "https", server.user == nil, server.password == nil else { throw URLError(.badURL) }
            var url = URLComponents(url: server.deletingLastPathComponent().appendingPathComponent("widget-api.php"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "scope", value: configuration.useAppSettings ? "settings" : configuration.scope.rawValue), URLQueryItem(name: "listId", value: configuration.category.trimmingCharacters(in: .whitespacesAndNewlines)), URLQueryItem(name: "days", value: String(min(30, max(1, configuration.upcomingDays))))]
            var request = URLRequest(url: url.url!); request.timeoutInterval = 12
            request.setValue(token, forHTTPHeaderField: "X-SaldoLeve-Widget"); request.setValue("3", forHTTPHeaderField: "X-SaldoLeve-Widget-Version")
            let setup = URLSessionConfiguration.ephemeral; setup.httpCookieStorage = nil; setup.urlCache = nil; setup.httpShouldSetCookies = false
            let session = URLSession(configuration: setup, delegate: WidgetNoRedirect(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (bytes, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [401, 403].contains(status) { try? FileManager.default.removeItem(at: cache); return .init(date: Date(), configuration: configuration, feed: nil, error: "Conexão expirada ou revogada. Gere outro código no aplicativo.") }
            guard status == 200, bytes.count <= 512_000 else { throw URLError(.badServerResponse) }
            let envelope = try JSONDecoder().decode(SaldoWidgetEnvelope.self, from: bytes)
            guard envelope.ok, let feed = envelope.data else { throw URLError(.cannotParseResponse) }
            try? JSONEncoder().encode(feed).write(to: cache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return .init(date: Date(), configuration: configuration, feed: feed)
        } catch {
            if let bytes = try? Data(contentsOf: cache), let feed = try? JSONDecoder().decode(SaldoWidgetFeed.self, from: bytes), let generated = ISO8601DateFormatter().date(from: feed.generatedAt), Date().timeIntervalSince(generated) >= 0, Date().timeIntervalSince(generated) <= 86400 {
                return .init(date: Date(), configuration: configuration, feed: feed, error: "Sem atualização", cached: true)
            }
            try? FileManager.default.removeItem(at: cache)
            return .init(date: Date(), configuration: configuration, feed: nil, error: "Não foi possível atualizar. Confira a conexão e a API na HostGator.")
        }
    }
}
struct SaldoWidgetView: View {
    let entry: SaldoWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var accent: Color { entry.configuration.color.color }
    private var display: SaldoWidgetDisplay {
        if entry.configuration.useAppSettings, let saved = entry.feed?.display { return saved }
        var value = SaldoWidgetDisplay()
        value.scope = entry.configuration.scope.rawValue; value.count = min(SaldoWidgetDisplay.maximumRows, max(1, entry.configuration.count))
        value.textSize = min(16, max(11, entry.configuration.textSize)); value.compact = entry.configuration.compact
        value.showSubtotals = entry.configuration.showSubtotals; value.showDates = entry.configuration.showDates
        value.showSubtasks = entry.configuration.showSubtasks; value.groupByDate = entry.configuration.groupByDate
        return value
    }
    private var title: String { let name = entry.configuration.customTitle.trimmingCharacters(in: .whitespacesAndNewlines); return name.isEmpty ? (SaldoWidgetScope(rawValue: display.scope)?.label ?? "Meu dia") : String(name.prefix(40)) }
    private var ordered: [SaldoWidgetItem] { let items = entry.feed?.items ?? []; return entry.configuration.content == .agenda ? items.sorted { ($0.dueAt ?? "9999") < ($1.dueAt ?? "9999") } : items }
    private var rowHeight: CGFloat { CGFloat(display.textSize + (display.compact ? 7 : 10) + (display.showDates && !display.compact ? 12 : 0) + (entry.configuration.showAmounts ? 12 : 0)) }
    private var expanded: Bool {
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return true }
        return family == .systemLarge
    }
    // Every tap opens the app's task list (Agenda); there are no per-item links.
    static let openURL = URL(string: "saldoleve://tasks")!
    private var portrait: Bool {
        if #available(iOS 27.0, *), family == .systemExtraLargePortrait { return true }
        return false
    }
    var body: some View {
        Group {
            if family == .accessoryCircular { Image(systemName: "checklist").font(.title2).accessibilityLabel("Abrir Agenda") }
            else if family == .accessoryInline { Text("Hoje \(entry.feed?.taskCounts["today"] ?? 0) · Atrasadas \(entry.feed?.taskCounts["overdue"] ?? 0)") }
            else if family == .accessoryRectangular { lockScreen }
            else { GeometryReader { geometry in home(height: geometry.size.height) } }
        }.containerBackground(for: .widget) { Color(uiColor: .systemBackground) }.widgetURL(Self.openURL).privacySensitive()
    }
    private func home(height: CGFloat) -> some View {
        let grouped = display.groupByDate && expanded
        let groupCount = grouped ? (display.states + ["undated"]).filter { state in ordered.contains { $0.state == state } }.count : 0
        // The full-page portrait widget fills its whole height instead of
        // stopping at the row limit chosen for the smaller sizes.
        let capacity = SaldoWidgetLayout.capacity(height: Double(height), rowHeight: Double(rowHeight), showSubtotals: false, groupCount: groupCount, requested: portrait ? SaldoWidgetDisplay.maximumRows : display.count)
        let selected = SaldoWidgetSelection.items(ordered, limit: capacity, grouped: grouped, states: display.states, focus: display.scope == "focus")
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Image(systemName: "checklist").foregroundStyle(accent); Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1); Spacer(minLength: 0); if expanded { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(.secondary) } }.frame(height: 20)
            if let feed = entry.feed {
                if selected.isEmpty { Spacer(minLength: 0); Label("Tudo em ordem", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary); Spacer(minLength: 0) }
                else if grouped {
                    ForEach(display.states + ["undated"], id: \.self) { state in
                        let items = selected.filter { $0.state == state }
                        if !items.isEmpty {
                            Text(label(state)).font(.system(size: 10, weight: .semibold)).foregroundStyle(state == "overdue" ? Color.red : .secondary).frame(height: 12)
                            VStack(spacing: 0) { ForEach(items) { item in row(item) } }
                        }
                    }
                } else { VStack(spacing: 0) { ForEach(selected) { item in row(item) } } }
                Spacer(minLength: 0)
                HStack(spacing: 3) { if entry.cached { Image(systemName: "wifi.slash") }; Text(updated(feed)).lineLimit(1); Spacer(minLength: 0) }.font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 12)
            } else {
                Spacer(minLength: 0); Text(entry.error ?? "Conecte sua conta").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func label(_ state: String) -> String { ["today":"Hoje", "overdue":"Atrasadas", "upcoming":"Próximas", "undated":"Sem data"][state] ?? state }
    private func row(_ item: SaldoWidgetItem) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Circle().stroke(item.state == "overdue" ? Color.red : accent, lineWidth: 1.2).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(display.showSubtasks ? (item.subtitle.map { item.title + " · " + $0 } ?? item.title) : item.title).font(.system(size: CGFloat(display.textSize), weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if display.compact && display.showDates { Text(item.dueLabel).font(.system(size: 9)).foregroundStyle(item.state == "overdue" ? Color.red : .secondary).lineLimit(1).fixedSize() }
                }
                if !display.compact && display.showDates { Text(item.dueLabel).font(.system(size: 9)).foregroundStyle(item.state == "overdue" ? Color.red : .secondary).lineLimit(1) }
                if entry.configuration.showAmounts, let amount = item.amountLabel { Text(amount).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1) }
            }; Spacer(minLength: 0)
        }.frame(height: rowHeight).contentShape(Rectangle())
    }
    private var lockScreen: some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text("Hoje \(entry.feed?.taskCounts["today"] ?? 0) · Atrasadas \(entry.feed?.taskCounts["overdue"] ?? 0)").font(.caption); if let item = ordered.first { Text(item.subtitle ?? item.title).font(.caption).lineLimit(1) } else { Text(entry.error ?? "Tudo em ordem").font(.caption).lineLimit(2) } } }
    private func updated(_ feed: SaldoWidgetFeed) -> String { let date = ISO8601DateFormatter().date(from: feed.generatedAt); return (entry.cached ? "Consulta " : "Atualizado ") + (date?.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_BR"))) ?? "agora") + (feed.limited ? " · parcial" : "") }
}
struct SaldoLeveWidgets: Widget {
    let kind = "SaldoLeveWidgets"
    private var families: [WidgetFamily] {
        var result: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular]
        if #available(iOS 27.0, *) { result.append(.systemExtraLargePortrait) }
        return result
    }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SaldoWidgetConfiguration.self, provider: SaldoWidgetProvider()) { SaldoWidgetView(entry: $0) }
            .configurationDisplayName("SaldoLeve").description("Tarefas, pendências e agenda do seu dia.")
            .supportedFamilies(families)
    }
}

// A separate identity lets the gallery install a portrait widget without
// reusing a legacy widget instance's size/configuration metadata.
@available(iOS 27.0, *)
struct SaldoLevePortraitWidget: Widget {
    let kind = "SaldoLevePortraitWidgets"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SaldoWidgetConfiguration.self, provider: SaldoWidgetProvider()) { SaldoWidgetView(entry: $0) }
            .configurationDisplayName("SaldoLeve · Lista ampliada")
            .description("Lista vertical que ocupa uma página inteira da Tela de Início. Toque para abrir a Agenda.")
            .supportedFamilies([.systemExtraLargePortrait])
    }
}

@main
struct SaldoLeveWidgetBundle: WidgetBundle {
    var body: some Widget {
        SaldoLeveWidgets()
        if #available(iOS 27.0, *) { SaldoLevePortraitWidget() }
    }
}
