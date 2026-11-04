import SwiftUI

struct NativeTaskMoneyTotals {
    let nominal: Double, paid: Double, discount: Double, remaining: Double
    let paidCount: Int, unknown: Int
    init(_ task: NativeTask) {
        let checks = task.checks
        var nominalTotal: Double = 0, paidTotal: Double = 0, discountTotal: Double = 0, pendingTotal: Double = 0
        for check in checks {
            let value: Double = check.fields["amountCents"]?.number ?? 0
            let actual: Double = check.fields["paidAmountCents"]?.number ?? value
            nominalTotal += value
            if check.done { paidTotal += actual; discountTotal += max(0, value - actual) }
            else { pendingTotal += value }
        }
        nominal = nominalTotal; paid = paidTotal; discount = discountTotal; remaining = pendingTotal
        paidCount = checks.filter(\.done).count
        unknown = checks.filter { $0.fields["amountCents"]?.number == nil }.count
    }
}
struct NativeTaskMoneySummary: View {
    let task: NativeTask
    var body: some View {
        let totals = NativeTaskMoneyTotals(task)
        Section("Valores desta tarefa") {
            LabeledContent("Total nominal", value: NativeDate.money(totals.nominal))
            LabeledContent("Pago efetivamente", value: NativeDate.money(totals.paid))
            LabeledContent("Descontos registrados", value: NativeDate.money(totals.discount))
            LabeledContent("Saldo nominal restante", value: NativeDate.money(totals.remaining))
            LabeledContent("Parcelas pagas", value: "\(totals.paidCount) de \(task.checks.count)")
            if totals.unknown > 0 { Text("\(totals.unknown) parcelas ainda sem valor; os totais são parciais.").font(.footnote).foregroundStyle(.orange) }
            Text("O saldo nominal não é uma cotação de quitação. Registre a oferta do banco ao antecipar. Este resumo considera os valores presentes nesta tarefa; o histórico mantém os pagamentos de ciclos anteriores.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
struct NativeInstallmentGenerator: View {
    @Binding var task: NativeTask
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Parcela"
    @State private var total = 60
    @State private var first = 1
    @State private var amount = ""
    @State private var amountMode = "parcel"
    @State private var due = NativeDate.quarter(Date().addingTimeInterval(86400))
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Parcelas com fim definido") {
                    TextField("Nome das parcelas", text: $name)
                    Stepper("Total do contrato: \(total)", value: $total, in: 2...100).onChange(of: total) { first = min(first, $0) }
                    Stepper("Primeira a gerar: \(first)", value: $first, in: 1...total)
                    DatePicker("Vencimento da primeira", selection: $due)
                    Picker("Valor informado", selection: $amountMode) { Text("Por parcela").tag("parcel"); Text("Total do contrato").tag("total") }
                    TextField("Valor (R$)", text: $amount).keyboardType(.decimalPad)
                }
                Section {
                    Text("Serão criadas \(total - first + 1) subtarefas, de \(first)/\(total) até \(total)/\(total), com vencimento mensal. Você poderá pagar qualquer uma, inclusive a última, sem alterar as demais.")
                    Text("A tarefa ficará sem repetição automática. Os centavos do valor total serão ajustados na última parcela. Para datas no fim do mês, o gerador usa o último dia dos meses mais curtos.").font(.footnote).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }.navigationTitle("Gerar parcelas").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Gerar") { generate() }.disabled(task.checks.count + total - first + 1 > 100) } }
        }
    }
    private func generate() {
        do {
            guard let value = NativeDate.cents(amount), value > 0 else { throw NativeFailure("Informe o valor total ou por parcela.") }
            let parcel = amountMode == "parcel" ? value : value / total
            let last = amountMode == "parcel" ? value : value - parcel * (total - 1)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: task.fields.text("timezone")) ?? .current
            let anchor = calendar.component(.day, from: due)
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: due))!
            var checks = task.checks.map { JSONValue.object($0.fields) }
            for number in first...total {
                let month = calendar.date(byAdding: .month, value: number - first, to: start)!
                let lastDay = calendar.range(of: .day, in: .month, for: month)!.count
                let day = calendar.date(bySetting: .day, value: min(anchor, lastDay), of: month)!
                let date = calendar.date(bySettingHour: calendar.component(.hour, from: due), minute: calendar.component(.minute, from: due), second: 0, of: day)!
                checks.append(.object(["id": .string(UUID().uuidString), "text": .string("\(name) \(number)/\(total)"), "done": .bool(false), "repeatMonthly": .bool(false), "remindAt": .string(NativeDate.iso(date)), "amountCents": .number(Double(number == total ? last : parcel)), "installmentNumber": .number(Double(number))]))
            }
            task.fields["checklist"] = .array(checks); task.fields["repeat"] = .object(["frequency": .string("none"), "interval": .number(1)])
            if !task.isMoney { task.fields["moneyMode"] = .string("pay") }
            if task.title.isEmpty { task.fields["title"] = .string(name + " (\(total)x)") }
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
struct NativeInstallmentPayment: View {
    @Binding var task: NativeTask
    var initialCheckID: String? = nil
    let commit: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NativeInstallmentDraft()
    @State private var initialized = false
    @State private var issue: String?
    @State private var confirming = false
    @State private var working = false
    private var pending: [NativeCheck] { task.checks.filter { !$0.done && !$0.paused } }
    private var valid: Bool { (try? draft.applying(to: task)) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Informe o valor original da parcela e quanto você pagou. O desconto é calculado automaticamente.").font(.subheadline)
                    HStack { Button("Próxima e última") { draft.selected = []; if let first = pending.first { draft.selected.insert(first.id) }; if let last = pending.last { draft.selected.insert(last.id) } }; Spacer(); Button("Limpar seleção") { draft.selected = [] } }.font(.subheadline)
                }
                ForEach(pending.filter { draft.selected.contains($0.id) }) { check in
                    Section(check.title) {
                        LabeledContent("Valor original da parcela") {
                            TextField("R$ 0,00", text: Binding(get: { draft.originals[check.id] ?? "" }, set: { draft.setOriginal($0, id: check.id) }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth: 80)
                                .accessibilityLabel("Valor original da parcela").accessibilityIdentifier("installment-original-" + check.id)
                        }
                        LabeledContent(task.moneyMode == "receive" ? "Valor recebido" : "Valor pago") {
                            TextField("R$ 0,00", text: Binding(get: { draft.paid[check.id] ?? "" }, set: { draft.setPaid($0, id: check.id) }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth: 80)
                                .accessibilityLabel(task.moneyMode == "receive" ? "Valor recebido" : "Valor pago").accessibilityIdentifier("installment-pa…14482 tokens truncated…atus"] = .string(status)
    value.fields["dueAt"] = due.map(JSONValue.string) ?? .null; return value
}
var collection = NativeSnapshot(); collection.configured = true
collection.lists = [NativeCategory(["id": .string("1"), "name": .string("Casa"), "archived": .bool(false), "canEdit": .bool(true)])]
collection.items = [sample("1", "2027-01-09T09:00:00Z"), sample("2", "2027-01-10T00:00:00Z"), sample("3", "2027-01-11T09:00:00Z"), sample("4", nil), sample("5", "2027-01-10T00:00:00Z", status: "done")]
check(NativeTaskQuery.select(collection, scope: .today, now: reference, calendar: cal).map(\.id) == ["2"], "Today must not silently include yesterday")
check(NativeTaskQuery.select(collection, scope: .overdue, now: reference, calendar: cal).map(\.id) == ["1"], "All-day tasks become overdue only on the following day")
check(NativeTaskQuery.select(collection, scope: .tomorrow, now: reference, calendar: cal).map(\.id) == ["3"], "Tomorrow must match the website")
check(NativeTaskQuery.select(collection, scope: .today, includeDone: true, now: reference, calendar: cal).map(\.id) == ["2", "5"], "Completed rows must remain available below pending tasks")
let grouped = NativeTaskQuery.groups(NativeTaskQuery.select(collection, scope: .all, now: reference, calendar: cal), scope: .all, sort: .due, now: reference, calendar: cal)
check(grouped.map(\.id) == ["overdue", "today", "tomorrow", "nodate"], "Groups must follow the same date hierarchy as the web")
collection.lists[0].fields["archived"] = .bool(true)
check(NativeTaskQuery.select(collection, scope: .all, now: reference, calendar: cal).isEmpty && NativeTaskQuery.select(collection, scope: .archived, now: reference, calendar: cal).count == 5, "Archived-category tasks must be visible only in the archive")
let parsed = NativeQuickCapture.parse("Revisar orçamento amanhã às 9h #casa ~Casa", categoryID: "0", categories: collection.lists, now: reference, calendar: cal)
check(parsed.title == "Revisar orçamento" && parsed.categoryID == "1" && parsed.tags == ["casa"] && parsed.listDate == NativeDate.parse("2027-01-11T09:00:00Z"), "Quick capture must preserve the intended date, tag and category")
let submitted = task
var local = submitted; var changed = local.checks[0].fields; changed["text"] = .string("Nome digitado durante o envio"); local.fields["checklist"] = .array([.object(changed)])
var canonical = submitted; var nextCycle = canonical.checks[0].fields; nextCycle["done"] = .bool(false); nextCycle["remindAt"] = .string("2027-02-15T02:00:00Z"); canonical.fields["checklist"] = .array([.object(nextCycle)]); canonical.fields["revision"] = .number(13)
let merged = local.rebased(after: submitted, server: canonical)
check(merged.revision == 13 && merged.checks[0].title == "Nome digitado durante o envio" && merged.checks[0].date == NativeDate.parse("2027-02-15T02:00:00Z"), "Autosave must retain typing without rolling back the server's monthly cycle")
let table = try NativeTableImport.parse("Internet\t1.234,56\t15/01/2027\nRevisar contrato", categoryID: "1")
check(table.count == 2 && table[0].pendingAmount == 123456 && table[1].moneyMode == "normal", "Table imports must use integer cents and preserve plain tasks")
do { _ = try NativeTableImport.parse("Internet\tabc\t31/02/2027", categoryID: "1"); fatalError("Malformed table was accepted") } catch { }
print("Web parity: filters, archive, groups, quick capture, autosave rebase and table import tests passed.")

var filterData = NativeSnapshot()
filterData.lists = [NativeCategory(["id": .string("1"), "name": .string("Teste"), "archived": .bool(false)])]
func filterTask(_ id: String, _ name: String, _ created: String, _ due: String?) -> NativeTask {
    var value = sample(id, due); value.fields["title"] = .string(name); value.fields["createdAt"] = .string(created); value.fields["updatedAt"] = .string(created); return value
}
filterData.items = [filterTask("901", "Zebra", "2027-01-01T10:00:00Z", "2027-01-10T23:59:59Z"), filterTask("902", "Arvore", "2027-01-09T10:00:00Z", "2027-01-11T00:00:00Z"), filterTask("903", "Casa", "2027-01-05T10:00:00Z", nil)]
check(NativeTaskQuery.select(filterData, scope: .all, sort: .created).map(\.id) == ["902","903","901"], "Newest tasks sort by creation rather than last update")
check(NativeTaskQuery.select(filterData, scope: .all, sort: .oldest).map(\.id) == ["901","903","902"], "Oldest creation dates come first")
check(NativeTaskQuery.select(filterData, scope: .all, sort: .title).map(\.id) == ["902","903","901"] && NativeTaskQuery.select(filterData, scope: .all, sort: .titleDescending).map(\.id) == ["901","903","902"], "Alphabetical task ordering works in both directions")
let exactDay = NativeTaskDateFilter(period: "custom", field: "due", from: "2027-01-10", to: "2027-01-10")
check(NativeTaskQuery.select(filterData, scope: .all, now: reference, calendar: cal, dateFilter: exactDay).map(\.id) == ["901"], "Custom periods include the last second of the final day and exclude undated tasks")
let addedDays = NativeTaskDateFilter(period: "custom", field: "created", from: "2027-01-09", to: "2027-01-10")
check(NativeTaskQuery.select(filterData, scope: .all, now: reference, calendar: cal, dateFilter: addedDays).map(\.id) == ["902"], "Creation-date periods are independent from task deadlines")
check(NativeTaskDateFilter(period: "last7", field: "created").matches(filterData.items[2], now: reference, calendar: cal), "Rolling periods use the current date")
check(!NativeTaskDateFilter(period: "custom", from: "2027-01-11", to: "2027-01-10").valid && NativeTaskDateFilter.date("2027-02-30") == nil, "Reversed ranges and invalid dates cannot become defaults")
let filterDefaults = UserDefaults(suiteName: "SaldoLeve.TaskFilterTests")!
filterDefaults.removePersistentDomain(forName: "SaldoLeve.TaskFilterTests")
var filterLayout = NativeLayoutPreferences(); filterLayout.taskDefaultScope = "today"; filterLayout.taskDefaultSort = NativeTaskSort.created.rawValue; filterLayout.taskDateFilter = addedDays; filterLayout.save(filterDefaults)
let reopenedFilters = NativeLayoutPreferences.read(filterDefaults)
check(reopenedFilters.taskDefaultSort == NativeTaskSort.created.rawValue && reopenedFilters.taskDateFilter == addedDays && reopenedFilters.taskDefaultScope == "all", "Saved ordering and period survive reopening while the initial tab stays Everything")
filterDefaults.removePersistentDomain(forName: "SaldoLeve.TaskFilterTests")
print("Task filters: newest/oldest, alphabetical order, inclusive periods, date-field choice, rolling dates and persisted defaults passed.")

var notificationPreferences = NativeNotificationPreferences()
let night = NativeDate.parse("2027-01-15T02:30:00Z")! // 23:30 in Brasília
check(notificationPreferences.deliveryDate(night) == NativeDate.parse("2027-01-15T09:00:00Z"), "Quiet time crosses midnight and postpones to 06:00 Brasília")
notificationPreferences.quietEnabled = false
check(notificationPreferences.deliveryDate(night) == night, "Quiet time must be optional")
notificationPreferences.quietEnabled = true; notificationPreferences.quietStart = 12 * 60; notificationPreferences.quietEnd = 14 * 60
check(notificationPreferences.deliveryDate(NativeDate.parse("2027-01-15T16:00:00Z")!) == NativeDate.parse("2027-01-15T17:00:00Z"), "Daytime quiet windows must also work")
notificationPreferences.quietEnd = notificationPreferences.quietStart
check(notificationPreferences.deliveryDate(night) == night, "Equal quiet times must not silence the entire day")
notificationPreferences.tasks = false
snapshot.lists[0].fields["archived"] = .bool(false)
check(NativeReminderPlan.build(snapshot, now: now, preferences: notificationPreferences).isEmpty, "Global task opt out must clear alarms")
notificationPreferences = NativeNotificationPreferences(); notificationPreferences.twoDaysBefore = false; notificationPreferences.oneDayBefore = false; notificationPreferences.repeatOverdue = false
snapshot.items = [task]
let dueOnly = NativeReminderPlan.build(snapshot, now: now, preferences: notificationPreferences)
check(dueOnly.count == 1, "Due-only settings must not schedule advance alerts or repeated alarms")
notificationPreferences.quietEnabled = false
let unsilenced = NativeReminderPlan.build(snapshot, now: now, preferences: notificationPreferences)
check(unsilenced.first?.date == task.checks.first?.date, "Disabling quiet time restores the original due time")
notificationPreferences.subtasks = false
check(NativeReminderPlan.build(snapshot, now: now, preferences: notificationPreferences).isEmpty, "Subtask opt out must not silently switch to parent alarms")
print("Notification preferences: optional quiet time, daytime windows, boundaries, opt outs and due-only scheduling passed.")

let financeJSON = Data(#"{"user":{"activeMonth":"2027-01"},"expenses":[{"id":"4","name":"Cartão","percent":50}],"transactions":[{"id":"8","expenseId":"4","amount":100,"type":"installment"}],"payments":[{"expenseId":"4","month":"2027-01"}],"calc":{"months":{"2027-01":{"expenses":{"4":{"integral":33.34,"considered":16.67}}}},"tx":{"8":{"from":"2027-01","to":"2027-03","activeValue":33.34}},"active":{"paymentChanges":{"4":{"difference":10}}}}}"#.utf8)
let financial = try JSONDecoder().decode(NativeFinanceSnapshot.self, from: financeJSON)
check(financial.transactions("4", activeOnly: true).count == 1, "Native finance must use server periods, not a nonexistent active flag")
check(financial.expenseCalculation("4").decimal("considered") == 16.67 && financial.isPending("4"), "Shared totals and changed payments must come from server calculations")
let percentageSplit = try NativeFinanceFormat.shares(["1":"33,34","2":"33,33","3":"33,33"], ids:["1","2","3"])
check(percentageSplit.decimal("1") == 33.34, "Share validation must preserve hundredths of a percent")
do { _ = try NativeFinanceFormat.shares(["1":"50","2":"49,99"], ids:["1","2"]); fatalError("Incomplete share split accepted") } catch { }
check(NativeFinanceFormat.date("2027-02-31") == nil, "Finance dates must be strict")
let widgetRoundTrip = try JSONDecoder().decode(SaldoWidgetFeed.self, from: JSONEncoder().encode(SaldoWidgetFeed.sample))
check(widgetRoundTrip.items[0].deepLink.absoluteString.contains("saldoleve://tasks?id=1"), "Widgets must open the native task without putting credentials into URLs")
print("Finance and widget models: periods, pending changes, server totals, share precision, dates and native links passed.")

let layoutDefaults = UserDefaults(suiteName: "SaldoLeve.LayoutTests")!
layoutDefaults.removePersistentDomain(forName: "SaldoLeve.LayoutTests")
layoutDefaults.set(Data(#"{"layoutRevision":2,"tabOrder":["tasks","tasks","invalid"],"startPage":"invalid","textScale":3,"dashboardOrder":["pending"],"dashboardHidden":["totals","invalid"]}"#.utf8), forKey: NativeLayoutPreferences.key)
var layout = NativeLayoutPreferences.read(layoutDefaults)
check(layout.tabOrder == ["tasks", "dashboard"] && layout.startPage == "tasks", "Stored layouts keep the two merged tabs: Despesas and Agenda")
var mergedTabs = NativeLayoutPreferences(); mergedTabs.tabOrder = ["expenses", "tasks", "dashboard"]; mergedTabs.startPage = "expenses"; mergedTabs.taskDetailLayout = "invalid"; mergedTabs.normalize()
check(mergedTabs.tabOrder == ["dashboard", "tasks"] && mergedTabs.startPage == "dashboard" && mergedTabs.taskDetailLayout == "elegant", "The old Despesas tab migrates into the merged Despesas tab without duplicates")
var detailPreset = NativeLayoutPreferences(); detailPreset.applyTaskDetailPreset("minimal")
check(detailPreset.taskDetailLayout == "minimal" && detailPreset.taskDetailGrouping == "none" && !detailPreset.taskDetailProgress && !detailPreset.taskDetailMetadata, "A task detail style applies its recommended options")
detailPreset.taskDetailMetadata = true; detailPreset.save(layoutDefaults)
check(NativeLayoutPreferences.read(layoutDefaults).taskDetailLayout == "minimal" && NativeLayoutPreferences.read(layoutDefaults).taskDetailMetadata, "Personalized task detail options persist on top of the chosen style")
detailPreset.applyTaskDetailPreset("unknown")
check(detailPreset.taskDetailLayout == "minimal", "Unknown task detail styles are ignored")
check(layout.textScale == 1.3 && layout.cardShowActions && layout.visibleDashboard.first == "pending" && !layout.visibleDashboard.contains("totals"), "Partial settings migrate with defaults, bounded fonts and preserved section visibility")
layout.cardColumns = 2; layout.taskQuickCapture = false; layout.save(layoutDefaults)
check(NativeLayoutPreferences.read(layoutDefaults).cardColumns == 2 && !NativeLayoutPreferences.read(layoutDefaults).taskQuickCapture, "Layout choices persist across relaunches")
layoutDefaults.removePersistentDomain(forName: "SaldoLeve.LayoutTests")
let balanced = SaldoWidgetSelection.items(SaldoWidgetFeed.sample.items, limit: 3, grouped: true, states: ["today", "overdue", "upcoming"], focus: true)
check(balanced.map(\.state) == ["today", "overdue", "upcoming"], "A grouped widget reserves room for all three selected groups")
let hidden = SaldoWidgetSelection.items(SaldoWidgetFeed.sample.items, limit: 14, grouped: true, states: ["today"], focus: true)
check(hidden.count == 1 && hidden[0].state == "today", "Hidden widget groups cannot leak into the daily list")
check(SaldoWidgetSelection.items(SaldoWidgetFeed.sample.items, limit: 0, grouped: true, states: ["today"], focus: true).isEmpty, "Zero available rows cannot overflow a widget")
print("Layout migration, persisted preferences, widget group visibility and balanced list selection passed.")
let largeRows = SaldoWidgetLayout.capacity(height: 330, rowHeight: 19, showSubtotals: true, groupCount: 3, requested: 30)
let portraitRows = SaldoWidgetLayout.capacity(height: 650, rowHeight: 19, showSubtotals: true, groupCount: 3, requested: 30)
check(portraitRows > largeRows && portraitRows > 14, "The portrait widget uses its extra height for more list rows")
check(SaldoWidgetLayout.capacity(height: 650, rowHeight: 19, showSubtotals: true, groupCount: 3, requested: 10) == 10, "A taller widget preserves the user's chosen row limit")
check(SaldoWidgetLayout.capacity(height: 50, rowHeight: 19, showSubtotals: true, groupCount: 3, requested: 30) == 0, "A small usable area cannot force an overflowing row")
check(SaldoWidgetLayout.capacity(height: 10_000, rowHeight: 19, showSubtotals: false, groupCount: 0, requested: 999) == 30, "Widget lists stay bounded even on a very large surface")
check(SaldoWidgetLayout.capacity(height: 650, rowHeight: 34, showSubtotals: true, groupCount: 3, requested: 30) < portraitRows, "Larger text, dates and amounts reduce the number of rows that fit")
let manyWidgetItems = (0..<40).map { index in SaldoWidgetItem(id: String(index), itemId: String(index), title: "Task \(index)", subtitle: nil, dueAt: nil, dueDay: nil, state: ["today", "overdue", "upcoming"][index % 3], dueLabel: "Hoje", amountLabel: nil) }
let portraitSelection = SaldoWidgetSelection.items(manyWidgetItems, limit: portraitRows, grouped: true, states: ["today", "overdue", "upcoming"], focus: true)
check(portraitSelection.count == portraitRows && Set(portraitSelection.map(\.state)).count == 3, "A tall populated widget fills its rows while preserving all selected groups")
print("Widget portrait layout: adaptive height, requested limits, overflow protection and balanced long lists passed.")

collection.lists[0].fields["archived"] = .bool(false)
collection.items[1].fields["dueAt"] = .string("2027-01-10T03:00:00Z")
collection.items[1].fields["timezone"] = .string("America/Sao_Paulo")
check(NativeDailyQuery.select(collection, state: "today", now: reference).map(\.id) == ["2"], "Daily focus keeps an all-day task in Today until the end of its day")
check(NativeDailyQuery.select(collection, state: "upcoming", days: 1, now: reference).map(\.id) == ["3"], "Daily focus excludes today and undated tasks from upcoming")
var groupedTask = sample("6", nil)
groupedTask.fields["timezone"] = .string("America/Sao_Paulo")
groupedTask.fields["checklist"] = .array([
    .object(["id": .string("a"), "text": .string("Parcela A"), "done": .bool(false), "remindAt": .string("2027-01-11T09:00:00Z")]),
    .object(["id": .string("b"), "text": .string("Parcela B"), "done": .bool(false), "remindAt": .string("2027-01-11T10:00:00Z")])])
collection.items.append(groupedTask)
check(NativeDailyQuery.select(collection, state: "upcoming", days: 1, now: reference).map(\.id) == ["3", "6"], "Subtasks in the same group count as one task in daily focus")
collection.items[collection.items.count - 1].fields["pausedUntil"] = .string("2027-01-12T00:00:00Z")
check(NativeDailyQuery.select(collection, state: "upcoming", now: reference).map(\.id) == ["3"], "Paused tasks do not inflate daily subtotals")
print("Daily focus: day boundaries, upcoming horizon, unique task counts and pauses passed.")

layoutDefaults.set(Data(#"{"cardColumns":1,"taskDefaultScope":"today","expenseDefaultFilter":"active","dashboardExpenseLimit":3,"dashboardHidden":["expenses"]}"#.utf8), forKey: NativeLayoutPreferences.key)
let migratedLayout = NativeLayoutPreferences.read(layoutDefaults)
check(migratedLayout.cardColumns == 3 && migratedLayout.taskDefaultScope == "all" && migratedLayout.expenseDefaultFilter == "all" && migratedLayout.dashboardExpenseLimit == 0 && migratedLayout.dashboardHidden.isEmpty, "Existing installs migrate once to three columns and unfiltered defaults")
var fourColumns = migratedLayout; fourColumns.cardColumns = 4; fourColumns.save(layoutDefaults)
check(NativeLayoutPreferences.read(layoutDefaults).cardColumns == 4, "Four-column preferences survive relaunch and are not reset by migration")
layoutDefaults.removePersistentDomain(forName: "SaldoLeve.LayoutTests")
check(NativeExpenseOrder.moving("3", before: "1", in: ["1", "2", "3"]) == ["3", "1", "2"], "Dragging a card changes visual order without dropping any expense")
check(NativeExpenseOrder.moving("unknown", before: "1", in: ["1", "2"]) == nil, "External drag data cannot insert an unknown expense")
let index = NativeTaskIndex(collection, userID: "", now: reference, calendar: cal)
for scope in TaskScope.allCases { check((index.scopes[scope.key] ?? 0) == NativeTaskQuery.select(collection, scope: scope, now: reference, calendar: cal).count, "Indexed counts must match the original scope: " + scope.key) }
let nextDay = NativeDate.parse("2027-01-11T09:00:00Z")!
let expectedDayCount = collection.items.filter { $0.isActive && NativeTaskIndex.dates($0).contains { cal.isDate($0, inSameDayAs: nextDay) } }.count
check(index.count(day: nextDay, calendar: cal) == expectedDayCount, "Calendar counts tasks once per day, even with several subtasks on that day")
let selectedDay = NativeTaskQuery.select(collection, scope: .all, includeDone: true, now: reference, calendar: cal, day: nextDay)
check(selectedDay.map(\.id) == ["3", "6"], "Filtering a calendar day before sorting preserves the selected tasks")
print("Three/four-column migration, unfiltered defaults, drag order and indexed/calendar parity passed.")

var loan = NativeTask.draft(categoryID: "1"); loan.fields["moneyMode"] = .string("pay")
loan.fields["checklist"] = .array(["a", "b", "c"].map { .object(["id": .string($0), "text": .string("Parcela " + $0), "done": .bool(false), "amountCents": .number(100000), "repeatMonthly": .bool(false), "note": .string("Preservar")]) })
var paymentDraft = NativeInstallmentDraft(loan)
check(paymentDraft.selected == ["a"], "The payment screen opens with both fields available on the next pending installment")
paymentDraft.setPaid("650,00", id: "a"); paymentDraft.setOriginal("1200,00", id: "a")
check(paymentDraft.paid["a"] == "650,00" && paymentDraft.discount("a") == 55000, "Editing original value must preserve an explicitly entered payment and recalculate discount")
let registered = try paymentDraft.applying(to: loan)
check(registered.checks[0].fields["amountCents"]?.number == 120000 && registered.checks[0].fields["paidAmountCents"]?.number == 65000 && registered.checks[0].done, "Both original and actual amounts must be submitted and retained")
check(!registered.checks[1].done && registered.checks[0].fields.text("note") == "Preservar" && !loan.checks[0].done, "Preparation is atomic and preserves metadata and unselected installments")
var invalidDraft = paymentDraft; invalidDraft.setPaid("1200,01", id: "a")
do { _ = try invalidDraft.applying(to: loan); fatalError("Payment above original was accepted") } catch { }
invalidDraft.setOriginal("", id: "a")
do { _ = try invalidDraft.applying(to: loan); fatalError("Empty original value was accepted") } catch { }
var futureDraft = NativeInstallmentDraft(loan, checkID: "c")
futureDraft.setPaid("0,00", id: "c")
let futurePayment = try futureDraft.applying(to: loan)
check(futurePayment.checks[2].done, "The last installment can be selected independently, including a fully discounted settlement")
print("Installment entry: two editable amounts, exact discounts, selected-only updates, metadata, cancellation and validation passed.")
var sixty = loan
sixty.fields["checklist"] = .array((1...60).map { number in .object(["id": .string("parcel-\(number)"), "text": .string("Parcela \(number)/60"), "done": .bool(false), "amountCents": .number(100000), "remindAt": .string("2030-01-15T12:00:00Z")]) })
var fiftySeven = NativeInstallmentDraft(sixty, checkID: "parcel-57")
check(fiftySeven.selected == ["parcel-57"], "Opening installment 57 selects its identity, never the earliest due date")
fiftySeven.setPaid("650,00", id: "parcel-57")
let paidFiftySeven = try fiftySeven.applying(to: sixty)
check(paidFiftySeven.checks.filter(\.done).map(\.id) == ["parcel-57"], "Only installment 57 out of 60 is completed")
check(paidFiftySeven.checks[56].fields["paidAmountCents"]?.number == 65000 && !paidFiftySeven.checks[0].done, "The entered value belongs to installment 57 and the first stays pending")
check(NativeInstallmentDraft(sixty, checkID: "removed").selected.isEmpty, "An obsolete explicit selection cannot fall back to another installment")
check(NativeInstallmentDraft(paidFiftySeven, checkID: "parcel-57").selected.isEmpty, "An already paid installment cannot silently select another pending one")
print("Exact installment identity: 57 of 60, paid amount, untouched siblings and stale selection passed.")

let legacyCache = Data(#"{"user":{"id":"1","name":"Lucas","login":"lucas"},"snapshot":{"configured":true,"items":[{"id":"1","title":"Título no servidor","revision":7}]},"drafts":{"1":{"id":"1","title":"Rascunho antigo","revision":2}},"draftBases":{"1":{"id":"1","title":"Antigo","revision":1}},"syncedAt":null}"#.utf8)
let serverCache = try JSONDecoder().decode(NativeLocalData.self, from: legacyCache)
check(serverCache.snapshot.items.first?.title == "Título no servidor", "A legacy local draft cannot replace cached server data")
let rewrittenCache = try JSONSerialization.jsonObject(with: JSONEncoder().encode(serverCache)) as! [String: Any]
check(rewrittenCache["drafts"] == nil && rewrittenCache["draftBases"] == nil, "Legacy drafts and draft ancestors are never written back to the device")
print("Server-only cache: legacy drafts ignored and permanently removed on rewrite passed.")

var leapBirthday = NativeBirthday.fresh()
leapBirthday.fields.merge(["name": .string("Ana"), "month": .number(2), "day": .number(29)]) { _, n in n }
check(leapBirthday.year == nil && leapBirthday.age(at: reference) == nil, "Birthday without year never invents age")
check(leapBirthday.calendar.component(.day, from: leapBirthday.occurrence(year: 2027)!) == 28, "February 29 defaults to February 28 in non leap years")
leapBirthday.fields["leapPolicy"] = .string("mar01")
check(leapBirthday.calendar.component(.month, from: leapBirthday.occurrence(year: 2027)!) == 3, "February 29 may be observed March 1")
leapBirthday.fields["leapPolicy"] = .string("leapOnly")
check(leapBirthday.occurrence(year: 2027) == nil && leapBirthday.occurrence(year: 2028) != nil, "Leap only policy skips non leap years")
var newYearBirthday = NativeBirthday.fresh()
newYearBirthday.fields.merge(["id": .string("1"), "name": .string("Virada"), "daysBefore": .array([.number(7), .number(0)])]) { _, n in n }
let yearEnd = NativeDate.parse("2026-12-30T12:00:00Z")!
check(newYearBirthday.calendar.component(.year, from: newYearBirthday.nextDate(now: yearEnd)!) == 2027, "Next birthday crosses calendar years")
let birthdayPlans = NativeBirthdayPlan.build([newYearBirthday], now: yearEnd, preferences: NativeNotificationPreferences())
check(birthdayPlans.filter { !$0.id.contains("-repeat-") }.count == 2 && birthdayPlans.allSatisfy { $0.date > yearEnd }, "Each reminder offset gets the next future occurrence, including across years")
check(birthdayPlans.contains { $0.id.contains("-repeat-") }, "A pending birthday keeps reminding after its time, like an overdue task")
let birthdayNow = NativeDate.parse("2027-01-02T15:00:00Z")!
check(newYearBirthday.isLate(now: birthdayNow) && !newYearBirthday.isCompleted(now: birthdayNow), "A birthday from yesterday stays open until marked as done")
let doneBirthday = newYearBirthday.settingCompleted(true, now: birthdayNow)
check(doneBirthday.completedYears == [2027] && doneBirthday.isCompleted(now: birthdayNow) && doneBirthday.currentOccurrence(now: birthdayNow) == newYearBirthday.currentOccurrence(now: birthdayNow), "Marking a birthday as done keeps it in the same place of the list")
check(!NativeBirthdayPlan.build([doneBirthday], now: birthdayNow, preferences: NativeNotificationPreferences()).contains { $0.id.contains("-repeat-") }, "A completed birthday stops its persistent alerts")
check(!doneBirthday.settingCompleted(false, now: birthdayNow).isCompleted(now: birthdayNow), "A completed birthday can be reopened")
var quietBirthday = newYearBirthday; quietBirthday.fields["persistent"] = .bool(false)
check(!NativeBirthdayPlan.build([quietBirthday], now: yearEnd, preferences: NativeNotificationPreferences()).contains { $0.id.contains("-repeat-") }, "Persistent birthday alerts can be turned off per person")
check(!newYearBirthday.isLate(now: NativeDate.parse("2027-01-05T15:00:00Z")!), "After two days the checkbox moves to the next year")
let platformDefaults = try JSONDecoder().decode(NativePlatformSnapshot.self, from: Data("{}".utf8))
check(platformDefaults.birthdays.isEmpty && platformDefaults.revision == 0, "Optional platform fields decode safely")
print("Birthdays: optional age, leap policies, next year, future alerts, completion, persistence and decoding passed.")

var spokenCalendar = Calendar(identifier: .gregorian); spokenCalendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
let spokenNow = NativeDate.parse("2027-01-10T15:07:00Z")!
let inTwoHours = NativeSpokenReminder.parse("me avise de tirar o lixo daqui 2 horas", now: spokenNow, calendar: spokenCalendar)
check(inTwoHours.title == "Tirar o lixo" && inTwoHours.due == NativeDate.parse("2027-01-10T17:15:00Z"), "Siri: 'daqui 2 horas' creates the task two hours later, on a quarter hour")
check(NativeSpokenReminder.parse("comprar pão daqui 2h", now: spokenNow, calendar: spokenCalendar).due == NativeDate.parse("2027-01-10T17:15:00Z"), "Siri: '2h' is understood")
let halfHour = NativeSpokenReminder.parse("pagar a luz em meia hora", now: spokenNow, calendar: spokenCalendar)
check(halfHour.title == "Pagar a luz" && halfHour.due == NativeDate.parse("2027-01-10T15:45:00Z"), "Siri: 'meia hora' is understood")
let tomorrowNine = NativeSpokenReminder.parse("ligar para o João amanhã às 9", now: spokenNow, calendar: spokenCalendar)
check(tomorrowNine.title == "Ligar para o João" && tomorrowNine.due == NativeDate.parse("2027-01-11T12:00:00Z"), "Siri: 'amanhã às 9' uses tomorrow at 09:00")
check(NativeSpokenReminder.parse("revisar contrato", now: spokenNow, calendar: spokenCalendar).due == nil, "Siri: without a time the task has no date")
check(NativeSpokenReminder.parse("criar tarefa comprar pão", now: spokenNow, calendar: spokenCalendar).title == "Comprar pão", "Siri: 'criar tarefa' is not part of the title")
check(NativeSpokenReminder.parse("adicionar lembrete de pagar a luz", now: spokenNow, calendar: spokenCalendar).title == "Pagar a luz", "Siri: 'adicionar lembrete' is not part of the title")
check(NativeSpokenReminder.parse("de tirar o lixo daqui 2 horas", now: spokenNow, calendar: spokenCalendar).title == "Tirar o lixo", "Siri: the answer to 'me lembre' drops the leading 'de'")
print("Siri phrases: relative hours, half hours, tomorrow at a time and plain titles passed.")

let pauseEnd = NativeDate.parse("2027-01-10T12:00:00Z")!
let held = NativeAlertPause.filter([
    PlannedReminder(id: "a", taskID: "1", title: "", body: "", date: NativeDate.parse("2027-01-10T10:00:00Z")!),
    PlannedReminder(id: "b", taskID: "1", title: "", body: "", date: NativeDate.parse("2027-01-10T11:00:00Z")!),
    PlannedReminder(id: "c", taskID: "2", title: "", body: "", date: NativeDate.parse("2027-01-10T10:30:00Z")!),
    PlannedReminder(id: "d", taskID: "2", title: "", body: "", date: NativeDate.parse("2027-01-10T13:00:00Z")!)], until: pauseEnd)
check(held.map(\.id) == ["a", "d"] && held[0].date == pauseEnd, "Paused alerts are held: one alert per item when the pause ends, later alerts kept")
check(NativeAlertPause.filter(held, until: nil) == held, "Without a pause nothing changes")
print("Alert pause: held alerts, one reminder at the end and later alerts passed.")

var ledger = NativeLayoutPreferences(); ledger.applyTaskDetailPreset("ledger")
check(ledger.taskDetailLayout == "ledger" && ledger.taskDetailNumbers && ledger.taskDetailDensity == "compact" && ledger.taskDetailGrouping == "none", "The ledger style numbers subtasks in compact columns")
var badDensity = NativeLayoutPreferences(); badDensity.taskDetailDensity = "huge"; badDensity.normalize()
check(badDensity.taskDetailDensity == "regular", "Unknown task detail density falls back to regular")
let pendingCheck = NativeCheck(["id": .string("x"), "text": .string("Parcela"), "done": .bool(false), "remindAt": .string("2027-01-09T12:00:00Z")])
check(NativeCheckState.of(pendingCheck, now: spokenNow, calendar: spokenCalendar) == "overdue", "A past subtask is overdue")
check(NativeCheckState.next([pendingCheck, NativeCheck(["id": .string("y"), "text": .string("Outra"), "done": .bool(true)])]) == "x", "The next pending subtask is highlighted")
print("Opened task styles: ledger preset, density and subtask situations passed.")

let oldDisplay = try JSONDecoder().decode(SaldoWidgetDisplay.self, from: Data(#"{"scope":"all","count":5}"#.utf8))
check(oldDisplay.count == 5 && !oldDisplay.showHeader && oldDisplay.accent == "blue" && oldDisplay.showFooter, "Older widget settings decode with the new appearance defaults")
var overdueFirst = SaldoWidgetDisplay(); overdueFirst.overdueFirst = true
check(overdueFirst.states == ["overdue", "today", "upcoming"], "Atrasadas can come before Hoje")
check(SaldoWidgetLayout.capacity(height: 330, rowHeight: 19, showSubtotals: false, groupCount: 2, requested: 30, header: false) > SaldoWidgetLayout.capacity(height: 330, rowHeight: 19, showSubtotals: false, groupCount: 2, requested: 30), "Without the title the widget fits more rows")
print("Widget appearance: tolerant decoding, group order and title space passed.")

var market = sample("31", nil); market.fields["locationReminder"] = .object(["placeId": .string("p1"), "trigger": .string("arrive")])
var milk = sample("32", nil); milk.fields["locationReminder"] = .object(["placeId": .string("p1"), "trigger": .string("arrive")])
var door = sample("33", nil); door.fields["locationReminder"] = .object(["placeId": .string("p1"), "trigger": .string("leave")])
var unknownPlace = sample("34", nil); unknownPlace.fields["locationReminder"] = .object(["placeId": .string("missing"), "trigger": .string("arrive")])
var emptyList = sample("35", nil); emptyList.fields["locationReminder"] = .object(["placeId": .string("p1"), "trigger": .string("arrive")])
var boughtList = sample("36", nil); boughtList.fields["locationReminder"] = .object(["placeId": .string("p1"), "trigger": .string("arrive")])
boughtList.fields["checklist"] = .array([.object(["id": .string("b1"), "text": .string("Café"), "done": .bool(true)])])
func withList(_ task: NativeTask, _ item: String) -> NativeTask {
    var copy = task
    copy.fields["checklist"] = .array([.object(["id": .string("i" + task.id), "text": .string(item), "done": .bool(false)]), .object(["id": .string("d" + task.id), "text": .string("Feito"), "done": .bool(true)])])
    return copy
}
market = withList(market, "Arroz"); milk = withList(milk, "Leite"); door = withList(door, "Chave"); unknownPlace = withList(unknownPlace, "Pão")
var placeSnapshot = NativeSnapshot(); placeSnapshot.items = [market, milk, door, unknownPlace, emptyList, boughtList]
let placeGroups = NativeLocationReminder.groups(placeSnapshot, places: [NativePlace(["id": .string("p1"), "name": .string("Mercado"), "latitude": .number(-23.55), "longitude": .number(-46.63), "radius": .number(50)])])
check(placeGroups.count == 2 && placeGroups[0].taskIDs == ["31", "32"] && placeGroups[0].trigger == "arrive" && placeGroups[0].place.radius == 100, "Tasks for the same place and direction share one grouped alert")
check(placeGroups[0].items == [["Arroz"], ["Leite"]], "Only pending subtasks are listed; tasks without pending subtasks do not warn")
check(placeGroups[0].summary.contains("Arroz") && !placeGroups[0].summary.contains("Feito"), "The location alert shows the pending items")
check(NativePlace.list(["places": .array([.object(["id": .string("z"), "name": .string("Sem coordenadas")])])]).isEmpty, "Places without coordinates are ignored")
print("Location reminders: grouped alerts, unknown places and invalid coordinates passed.")
