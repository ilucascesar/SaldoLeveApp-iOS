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
    static let names = ["elegant": "Sofisticado", "cards": "Cartões", "timeline": "Linha do tempo", "minimal": "Simplificado"]
    static let summaries = ["elegant": "Resumo com progresso, grupos por situação e detalhes de data e valor.", "cards": "Cada subtarefa em um cartão. Ideal para listas longas.", "timeline": "Subtarefas ligadas por uma linha, separadas por mês.", "minimal": "Lista enxuta, somente o essencial."]
    static let icons = ["elegant": "sparkles.rectangle.stack", "cards": "rectangle.stack", "timeline": "point.topleft.down.curvedto.point.bottomright.up", "minimal": "list.bullet"]
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
            return checks.isEmpty ? [] : [NativeTaskDetailGroup(id: "all", title: "", ids: checks.map(\.id))]
        }
    }
}

struct NativeTaskProgressHeader: View {
    let done: Int
    let total: Int
    var style = "elegant"
    var amount: String? = nil
    private var ratio: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var body: some View {
        if style == "minimal" {
            HStack(spacing: 10) {
                ProgressView(value: ratio).tint(nativeBlue)
                Text("\(done)/\(total)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if let amount { Text(amount).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(.vertical, 4)
        } else {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(nativeBlue.opacity(0.12), lineWidth: 5)
                    Circle().trim(from: 0, to: ratio).stroke(nativeBlue, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int((ratio * 100).rounded()))%").font(.system(size: 11, weight: .bold, design: .rounded))
                }.frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(total > 0 && done == total ? "Tudo concluído" : "\(total - done) \(total - done == 1 ? "pendente" : "pendentes")").font(.system(size: 16, weight: .semibold))
                    Text("\(done) de \(total) subtarefas concluídas").font(.system(size: 12)).foregroundStyle(.secondary)
                    if let amount { Text(amount).font(.system(size: 12, weight: .semibold)).foregroundStyle(nativeBlue).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.padding(14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(style == "cards" ? nativeBlue.opacity(0.09) : nativeBlue.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(nativeBlue.opacity(style == "elegant" ? 0.12 : 0), lineWidth: 1))
        }
    }
}

struct NativeTaskDetailGroupHeader: View {
    let group: NativeTaskDetailGroup
    let collapsed: Bool
    var toggle: () -> Void = {}
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold))
                Text(group.title).font(.system(size: 13, weight: .semibold))
                Text("\(group.ids.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }.textCase(nil).foregroundStyle(group.done ? Color.secondary : Color.primary).padding(.vertical, 2).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(group.title + ", \(group.ids.count) subtarefas").accessibilityHint(collapsed ? "Mostrar" : "Recolher")
    }
}

struct NativeTaskDetailRowChrome: ViewModifier {
    let style: String
    let done: Bool
    let first: Bool
    let last: Bool
    @ViewBuilder func body(content: Content) -> some View {
        switch style {
        case "cards":
            content.padding(.horizontal, 8)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(done ? Color.secondary.opacity(0.07) : nativeBlue.opacity(0.06))
                        .overlay(alignment: .leading) { Capsule().fill(done ? Color.secondary.opacity(0.35) : nativeBlue).frame(width: 3).padding(.vertical, 12) }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                )
        case "timeline":
            content
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(ZStack(alignment: .topLeading) { nativePaper; NativeTimelineLine(first: first, last: last) })
        case "minimal":
            content.listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10)).listRowBackground(nativePaper)
        default:
            content
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(nativePaper)
        }
    }
}

// The check button is 26 points wide and starts at the 16-point row inset, so
// its center sits at x = 29. The line stops at the first/last circle.
struct NativeTimelineLine: View {
    let first: Bool
    let last: Bool
    var body: some View {
        GeometryReader { proxy in
            let top: CGFloat = first ? 28 : 0
            let bottom: CGFloat = last ? 28 : proxy.size.height
            Rectangle().fill(nativeBlue.opacity(0.25)).frame(width: 2, height: max(0, bottom - top)).offset(x: 28, y: top)
        }
    }
}
