import Foundation

func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError(description) }
}

let address = SiteAddress("https://tools.ilucas.com.br/SaldoLeveApp/sistema.php")!
check(address.contains(URL(string: "https://tools.ilucas.com.br/SaldoLeveApp/login.php")!), "Login shares the configured HTTPS origin")
check(address.contains(URL(string: "https://tools.ilucas.com.br:443/SaldoLeveApp/api.php?api=export")!), "Default HTTPS port")
check(address.contains(URL(string: "https://TOOLS.ILUCAS.COM.BR/SaldoLeveApp/nova_senha.php")!), "Host case")
check(!address.contains(URL(string: "https://tools.ilucas.com.br.evil.test/SaldoLeveApp/sistema.php")!), "No suffix host matching")
check(!address.contains(URL(string: "http://tools.ilucas.com.br/SaldoLeveApp/sistema.php")!), "No cleartext navigation")
check(!address.contains(URL(string: "https://tools.ilucas.com.br:8443/SaldoLeveApp/sistema.php")!), "Port is part of the origin")
check(!address.contains(URL(string: "https://user:secret@tools.ilucas.com.br/SaldoLeveApp/sistema.php")!), "No URL credentials")
for invalid in ["http://example.com/sistema.php", "https://example.com/login.php", "file:///sistema.php",
                "https://user:password@example.com/sistema.php", "https://example.com/sistema.php?token=secret",
                "https://example.com/sistema.php#fragment", "", "example.com/sistema.php"] {
    check(SiteAddress(invalid) == nil, "Invalid configuration accepted: \(invalid)")
}
check(address.origin == "https://tools.ilucas.com.br", "Origin excludes the URL path")
check(SiteAddress(" HTTPS://TOOLS.ILUCAS.COM.BR:443/SaldoLeveApp/sistema.php ")?.origin == address.origin,
      "HTTPS origins must be canonicalized")
print("SiteAddress: HTTPS, origin, login, port and untrusted URL tests passed.")

let encodedTask = Data(#"{"id":"7","listId":"1","title":"Aluguel","body":"Original","status":"todo","revision":12,"dueAt":null,"moneyMode":"receive","cycleNumber":4,"dateRemindersEnabled":true,"checklist":[{"id":"c1","text":"Janeiro","done":false,"amountCents":12345,"remindAt":"2027-01-15T02:00:00Z","repeatMonthly":false,"lastCompletedAt":"2026-12-15T12:00:00Z"}],"futureMetadata":{"preserve":true}}"#.utf8)
var task = try JSONDecoder().decode(NativeTask.self, from: encodedTask)
task.fields["title"] = .string("Aluguel editado")
let roundTrip = try JSONDecoder().decode(NativeTask.self, from: JSONEncoder().encode(task))
check(roundTrip.fields["futureMetadata"] == task.fields["futureMetadata"], "Editing must preserve unknown server metadata")
check(roundTrip.fields.integer("cycleNumber") == 4 && roundTrip.revision == 12, "Editing must preserve cycle and revision")
check(roundTrip.checks[0].fields["repeatMonthly"] == .bool(false), "Monthly exceptions must be preserved")
let integerJSON = String(data: try JSONEncoder().encode(task), encoding: .utf8)!
check(integerJSON.contains("\"amountCents\":12345") && !integerJSON.contains("12345.0"), "PHP requires integer cents, not floating point JSON")
check(NativeDate.cents("1.234,56") == 123456, "Brazilian money conversion")
check(NativeDate.cents("0,01") == 1 && NativeDate.cents("999999999,99") == 99999999999, "Money bounds and cent precision")
check(NativeDate.cents("12abc") == nil && NativeDate.cents("-1") == nil && NativeDate.cents("1,234") == nil, "Malformed money must not be silently accepted")
let captureKey = NativeTask.draft(categoryID: "1").fields.text("captureKey")
check(captureKey.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil, "Native capture keys must match PHP idempotency contract")
check(NativeDate.quarter(NativeDate.parse("2027-01-01T12:07:13Z")!) == NativeDate.parse("2027-01-01T12:15:00Z"), "Quarter-hour rounding")

var snapshot = NativeSnapshot()
snapshot.configured = true
snapshot.lists = [NativeCategory(["id": .string("1"), "name": .string("Casa"), "archived": .bool(false), "canEdit": .bool(true)])]
snapshot.items = [task]
let now = NativeDate.parse("2027-01-10T12:00:00Z")!
let reminders = NativeReminderPlan.build(snapshot, now: now)
check(!reminders.isEmpty && reminders.allSatisfy { $0.taskID == "7" }, "Subtask reminders must open the parent task")
check(reminders.allSatisfy { $0.body.contains("Janeiro") }, "Independent subtask text")
var brazil = Calendar(identifier: .gregorian); brazil.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
check(reminders.allSatisfy { (6..<23).contains(brazil.component(.hour, from: $0.date)) }, "All local alerts must respect quiet hours")
check(Set(reminders.map(\.date)).count == reminders.count, "Night repeats must not pile up at 06:00")
check(NativeReminderPlan.build(snapshot, now: now, limit: 2).count == 2, "Local notification queue is bounded")
snapshot.items[0].fields["status"] = .string("done")
check(NativeReminderPlan.build(snapshot, now: now).isEmpty, "Completed tasks cancel local reminders")
snapshot.items = [task]; snapshot.items[0].fields["dateRemindersEnabled"] = .bool(false)
check(NativeReminderPlan.build(snapshot, now: now).isEmpty, "Disabled task reminders must remain disabled")
snapshot.items = [task]; snapshot.lists[0].fields["archived"] = .bool(true)
check(NativeReminderPlan.build(snapshot, now: now).isEmpty, "Archived categories never notify")
print("Native task models: metadata, money, capture idempotency, dates and local reminder tests passed.")

// Match the web's exact-day filters and ordering without losing archived lists.
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
let reference = NativeDate.parse("2027-01-10T12:00:00Z")!
func sample(_ id: String, _ due: String?, status: String = "todo") -> NativeTask {
    var value = NativeTask.draft(categoryID: "1"); value.fields["id"] = .string(id); value.fields["title"] = .string("Tarefa " + id); value.fields["status"] = .string(status)
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
check(layout.tabOrder == ["tasks", "dashboard", "expenses"] && layout.startPage == "tasks", "Stored layouts must keep three valid, unique destinations")
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
check(birthdayPlans.count == 2 && birthdayPlans.allSatisfy { $0.date > yearEnd }, "Each reminder offset gets the next future occurrence, including across years")
let platformDefaults = try JSONDecoder().decode(NativePlatformSnapshot.self, from: Data("{}".utf8))
check(platformDefaults.birthdays.isEmpty && platformDefaults.revision == 0, "Optional platform fields decode safely")
print("Birthdays: optional age, leap policies, next year, future alerts and decoding passed.")
