import SwiftUI
import UIKit

struct NativeChecklistPosition: Hashable {
    let id: String
    let done: Bool
    let date: Date?

    init(_ check: NativeCheck) {
        id = check.id
        done = check.done
        date = check.date
    }
}

@MainActor
final class NativeChecklistScroll {
    private final class Marker {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    struct Anchor {
        let offsets: [(id: String, top: CGFloat)]
        let fallback: CGPoint
    }

    private var markers: [String: Marker] = [:]
    private weak var list: UIScrollView?
    private var ticket = 0

    func register(_ id: String, view: UIView) { markers[id] = Marker(view) }

    func capture(staying: Set<String>) -> Anchor? {
        ticket += 1
        let attached = markers.compactMapValues { $0.view?.window == nil ? nil : $0.view }
        guard let marker = attached.values.first, let scrollView = enclosingScrollView(marker),
              !scrollView.isTracking, !scrollView.isDecelerating else { return nil }
        list = scrollView
        let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size).inset(by: scrollView.adjustedContentInset)
        let offsets = attached.compactMap { id, view -> (id: String, top: CGFloat)? in
            guard staying.contains(id) else { return nil }
            let frame = view.convert(view.bounds, to: scrollView)
            guard frame.intersects(visible) else { return nil }
            return (id, frame.minY - scrollView.contentOffset.y)
        }.sorted { $0.top < $1.top }
        return Anchor(offsets: offsets, fallback: scrollView.contentOffset)
    }

    func restore(_ anchor: Anchor?) {
        guard let anchor else { return }
        let current = ticket
        // SwiftUI can reapply its own offset when the list commits the row move.
        // Restore again on the following layout pass, unless the user scrolled.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.apply(anchor, ticket: current) else { return }
            DispatchQueue.main.async { [weak self] in _ = self?.apply(anchor, ticket: current) }
        }
    }

    private func apply(_ anchor: Anchor, ticket current: Int) -> Bool {
        guard current == ticket, let list, list.window != nil, !list.isTracking, !list.isDecelerating else { return false }
        list.layoutIfNeeded()
        var target = anchor.fallback
        for (id, top) in anchor.offsets {
            guard let view = markers[id]?.view, view.window != nil, view.isDescendant(of: list) else { continue }
            target.y = view.convert(view.bounds, to: list).minY - top
            break
        }
        let minimum = -list.adjustedContentInset.top
        let maximum = max(minimum, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        target.y = min(maximum, max(minimum, target.y))
        if abs(target.y - list.contentOffset.y) > 0.5 { list.setContentOffset(target, animated: false) }
        return true
    }

    private func enclosingScrollView(_ marker: UIView) -> UIScrollView? {
        var view = marker.superview
        while let parent = view {
            if let scrollView = parent as? UIScrollView { return scrollView }
            view = parent.superview
        }
        return nil
    }
}

struct NativeChecklistMarker: UIViewRepresentable {
    let id: String
    let scroll: NativeChecklistScroll

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { scroll.register(id, view: view) }
}

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
        "elegant": "Situação colorida e vencimento junto ao nome da subtarefa.",
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
    let layout: NativeLayoutPreferences
    let collapsed: Set<String>
    var toggle: (String) -> Void = { _ in }
    let row: (NativeCheck, NativeCheckPresentation) -> Row
    var body: some View {
        let style = layout.taskDetailLayout
        let groups = NativeTaskDetailLayout.groups(checks, grouping: layout.taskDetailGrouping)
        let numbers = Dictionary(uniqueKeysWithValues: checks.enumerated().map { ($0.element.id, $0.offset + 1) })
        let done = checks.filter(\.done).count
        ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
            Section {
                if !collapsed.contains(group.id) {
                    ForEach(Array(group.ids.enumerated()), id: \.element) { offset, id in
                        if let check = checks.first(where: { $0.id == id }) {
                            let presentation = NativeCheckPresentation(style: style, state: NativeCheckState.of(check), days: NativeCheckState.days(check), number: layout.taskDetailNumbers || style == "ledger" ? numbers[id] : nil, first: offset == 0, last: offset == group.ids.count - 1, stripe: offset % 2 == 1, metadata: layout.taskDetailMetadata, amounts: layout.taskDetailAmounts, pills: layout.taskDetailPills, compact: layout.taskDetailDensity == "compact", receive: receive)
                            row(check, presentation).modifier(NativeTaskDetailRowChrome(presentation: presentation))
                        }
                    }
                }
            } header: {
                NativeTaskDetailGroupHeader(group: group, collapsed: collapsed.contains(group.id), progress: layout.taskDetailProgress && groupIndex == 0 && checks.count > 1 ? (done, checks.count) : nil, columns: style == "ledger" && !collapsed.contains(group.id), money: money) { toggle(group.id) }
            }
        }
    }
}

struct NativeTaskPendingAmount: View {
    let amount: Double
    var body: some View {
        HStack(spacing: 6) {
            Text("Total pendente").foregroundStyle(.secondary)
            Text(NativeDate.money(amount)).fontWeight(.semibold).monospacedDigit()
        }.font(.footnote).accessibilityElement(children: .combine)
            .accessibilityIdentifier("task-pending-amount")
    }
}

// The first group may also show the overall progress bar.
struct NativeTaskDetailGroupHeader: View {
    let group: NativeTaskDetailGroup
    let collapsed: Bool
    var progress: (Int, Int)? = nil
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
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
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
                .listRowBackground(p.stripe ? Color.primary.opacity(0.03) : nativePaper)
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
