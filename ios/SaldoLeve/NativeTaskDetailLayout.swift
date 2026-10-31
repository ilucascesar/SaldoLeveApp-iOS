import SwiftUI

// Shared by the open task and the layout simulator, so the preview always
// matches what an opened task really shows.
struct NativeTaskDetailGroup: Identifiable {
    let id: String
    let title: String
    let ids: [String]
    var done = false
}

enum NativeTaskDetailLayout {
    static let names = ["elegant": "Sofisticado", "cards": "Cartões", "timeline": "Linha do tempo", "ledger": "Planilha", "minimal": "Simplificado"]
    static let summaries = [
        "elegant": "Valor à direita, situação colorida e a próxima pendência em destaque.",
        "cards": "Cada subtarefa em um cartão com vencimento, valor e situação.",
        "timeline": "Datas à esquerda, ligadas por uma linha e separadas por mês.",
        "ledger": "Colunas numeradas de vencimento e valor. Ideal para parcelas.",
        "minimal": "Uma linha por subtarefa, somente o essencial."]
    static let icons = ["elegant": "sparkles.rectangle.stack", "cards": "rectangle.stack", "timeline": "point.topleft.down.curvedto.point.bottomright.up", "ledger": "tablecells", "minimal": "list.bullet"]
    static let groupingNames = ["status": "Pendentes e concluídas", "date": "Por mês", "none": "Sem grupos"]

    static func groups(_ checks: [NativeCheck], grouping: String, calendar: Calendar = .current) -> [NativeTaskDetailGroup] {
        switch grouping {
        case "status":
            let pending = NativeTaskDetailGroup(id: "pending", title: "Pendentes", ids: checks.filter { !$0.done }.map(\.id))
            let done = NativeTaskDetailGroup(id: "done", title: "Concluídas", ids: checks.filter(\.done).map(\.id), done: true)
            return [pending, done].filter { !$0.ids.isEmpty }
        case "date":
            var order: [String] = []
            var buckets: [String: [String]] = [:]
            var titles: [String: String] = [:]
            for check in checks {
                var key = "undated", title = "Sem data"
                if let date = check.date {
                    let parts = calendar.dateComponents([.year, .month], from: date)
                    key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
                    title = date.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "pt_BR"))).capitalized
                }
                if buckets[key] == nil { order.append(key); titles[key] = title }
                buckets[key, default: []].append(check.id)
            }
            let sorted = order.sorted { a, b in a == "undated" ? false : (b == "undated" ? true : a < b) }
            return sorted.map { key in
                let ids = buckets[key] ?? []
                return NativeTaskDetailGroup(id: key, title: titles[key] ?? key, ids: ids, done: checks.filter { ids.contains($0.id) }.allSatisfy(\.done))
            }
        default:
            return checks.isEmpty ? [] : [NativeTaskDetailGroup(id: "all", title: "Subtarefas", ids: checks.map(\.id))]
        }
    }
}

// Everything a row needs to draw itself in the chosen style.
struct NativeCheckPresentation: Equatable {
    var style = "elegant"
    var state = "upcoming"
    var days: Int?
    var number: Int?
    var highlight = false
    var first = false
    var last = false
    var stripe = false
    var metadata = true
    var amounts = true
    var pills = true
    var compact = false
    var receive = false
    var tint: Color {
        switch state {
        case "overdue": return .red
        case "today": return .orange
        case "done": return .green
        case "nodate": return .secondary
        default: return nativeBlue
        }
    }
    func label(money: Bool) -> String {
        switch state {
        case "overdue": return "Atrasada"
        case "today": return "Hoje"
        case "done": return money ? (receive ? "Recebida" : "Paga") : "Concluída"
        case "nodate": return "Sem data"
        default:
            guard let days else { return "Prevista" }
            return days == 1 ? "Amanhã" : days < 31 ? "Em \(days) dias" : "Prevista"
        }
    }
}

// The subtask sections of an opened task. The editor and the simulator both
// use this view; only the row content (editable or not) differs.
struct NativeTaskChecklist<Row: View>: View {
    let checks: [NativeCheck]
    let money: Bool
    var receive = false
    var pendingAmount: Double? = nil
    let layout: NativeLayoutPreferences
    let collapsed: Set<String>
    var toggle: (String) -> Void = { _ in }
    let row: (NativeCheck, NativeCheckPresentation) -> Row
    var body: some View {
        let style = layout.taskDetailLayout
        let groups = NativeTaskDetailLayout.groups(checks, grouping: layout.taskDetailGrouping)
        let next = layout.taskDetailHighlightNext ? NativeCheckState.next(checks) : nil
        let numbers = Dictionary(uniqueKeysWithValues: checks.enumerated().map { ($0.element.id, $0.offset + 1) })
        let done = checks.filter(\.done).count
        ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
            Section {
                if !collapsed.contains(group.id) {
                    ForEach(Array(group.ids.enumerated()), id: \.element) { offset, id in
                        if let check = checks.first(where: { $0.id == id }) {
                            let presentation = NativeCheckPresentation(style: style, state: NativeCheckState.of(check), days: NativeCheckState.days(check), number: layout.taskDetailNumbers || style == "ledger" ? numbers[id] : nil, highlight: next == id, first: offset == 0, last: offset == group.ids.count - 1, stripe: offset % 2 == 1, metadata: layout.taskDetailMetadata, amounts: layout.taskDetailAmounts, pills: layout.taskDetailPills, compact: layout.taskDetailDensity == "compact", receive: receive)
                            row(check, presentation).modifier(NativeTaskDetailRowChrome(presentation: presentation))
                        }
                    }
                }
            } header: {
                NativeTaskDetailGroupHeader(group: group, collapsed: collapsed.contains(group.id), progress: layout.taskDetailProgress && groupIndex == 0 && checks.count > 1 ? (done, checks.count) : nil, amount: layout.taskDetailProgress && groupIndex == 0 && money ? pendingAmount.map { (receive ? "A receber " : "A pagar ") + NativeDate.money($0) } : nil, columns: style == "ledger" && !collapsed.contains(group.id), money: money) { toggle(group.id) }
            }
        }
    }
}

// Compact header: group title and count, plus (on the first group) a thin
// progress bar and the pending amount. It never pushes the list down.
struct NativeTaskDetailGroupHeader: View {
    let group: NativeTaskDetailGroup
    let collapsed: Bool
    var progress: (Int, Int)? = nil
    var amount: String? = nil
    var columns = false
    var money = false
    var toggle: () -> Void = {}
    var body: some View {
        VStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text(group.title).font(.system(size: 13, weight: .semibold))
                    Text("\(group.ids.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 1).background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer(minLength: 6)
                    if let amount { Text(amount).font(.system(size: 11, weight: .semibold)).foregroundStyle(nativeBlue).lineLimit(1).minimumScaleFactor(0.8) }
                    if let progress {
                        Capsule().fill(nativeBlue.opacity(0.14)).frame(width: 46, height: 5)
                            .overlay(alignment: .leading) { Capsule().fill(nativeBlue).frame(width: 46 * CGFloat(progress.1 == 0 ? 0 : Double(progress.0) / Double(progress.1)), height: 5) }
                        Text("\(progress.0)/\(progress.1)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.textCase(nil).foregroundStyle(group.done ? Color.secondary : Color.primary).padding(.vertical, 2).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(group.title + ", \(group.ids.count) subtarefas" + (progress.map { ", \($0.0) de \($0.1) concluídas" } ?? "")).accessibilityHint(collapsed ? "Mostrar" : "Recolher")
            if columns {
                HStack(spacing: 8) {
                    Text("Nº").frame(width: 24, alignment: .leading)
                    Text("Descrição").padding(.leading, 25).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Vencimento").frame(width: 66, alignment: .trailing)
                    if money { Text("Valor").frame(width: 84, alignment: .trailing) }
                    Color.clear.frame(width: 22, height: 1)
                }.font(.system(size: 9, weight: .bold)).textCase(.uppercase).foregroundStyle(.secondary)
            }
        }
    }
}

struct NativeTaskDetailRowChrome: ViewModifier {
    let presentation: NativeCheckPresentation
    @ViewBuilder func body(content: Content) -> some View {
        let p = presentation
        switch p.style {
        case "cards":
            content
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(alignment: .leading) { UnevenRoundedStripe().fill(p.tint.opacity(p.state == "done" ? 0.35 : 0.9)).frame(width: 4) }
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.highlight ? nativeBlue.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: p.highlight ? 1.5 : 1))
                        .shadow(color: .black.opacity(p.state == "done" ? 0 : 0.05), radius: 6, y: 2)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                )
                .opacity(p.state == "done" ? 0.72 : 1)
        case "timeline":
            content
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 10))
                .listRowSeparator(.hidden)
                .listRowBackground(ZStack(alignment: .topLeading) { nativePaper; NativeTimelineLine(first: p.first, last: p.last, color: p.tint) })
        case "ledger":
            content
                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 8))
                .listRowSeparator(.visible).listRowSeparatorTint(Color.primary.opacity(0.06))
                .listRowBackground(p.highlight ? nativeBlue.opacity(0.08) : p.stripe ? Color.primary.opacity(0.03) : nativePaper)
        case "minimal":
            content.listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 8)).listRowSeparatorTint(Color.primary.opacity(0.06)).listRowBackground(nativePaper)
        default:
            content
                .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
                .listRowSeparator(.hidden)
                .listRowBackground(nativePaper)
        }
    }
}

// The accent stripe on the left of a card, rounded like the card corners.
struct UnevenRoundedStripe: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + 10, width: rect.width, height: max(0, rect.height - 20)), cornerRadius: rect.width / 2)
    }
}

// The timeline node is centered 12 (inset) + 40 (date column) + 8 (spacing)
// + 13 (half the node) = 73 points from the leading edge.
struct NativeTimelineLine: View {
    let first: Bool
    let last: Bool
    var color: Color = nativeBlue
    var body: some View {
        GeometryReader { proxy in
            let top: CGFloat = first ? 24 : 0
            let bottom: CGFloat = last ? 24 : proxy.size.height
            Rectangle().fill(color.opacity(0.28)).frame(width: 2, height: max(0, bottom - top)).offset(x: 72, y: top)
        }
    }
}
