import Foundation

enum NativeTaskCopy {
    static func make(_ source: NativeTask) -> NativeTask {
        var result = source
        for key in ["id", "revision", "createdAt", "updatedAt", "completedAt", "cycleAnchorDays", "lastCompletedAt", "lastCompletedDueAt"] { result.fields.removeValue(forKey: key) }
        result.fields["id"] = .string(""); result.fields["revision"] = .number(0)
        result.fields["captureKey"] = .string(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        result.fields["title"] = .string(String((source.title + " (cópia)").prefix(200)))
        result.fields["status"] = .string("todo"); result.fields["cycleNumber"] = .number(0); result.fields["pausedUntil"] = .null
        result.fields["checklist"] = .array(source.checks.map { check in
            var fields = check.fields
            for key in ["completedCount", "lastCompletedAt", "lastCompletedDueAt"] { fields.removeValue(forKey: key) }
            fields["id"] = .string(UUID().uuidString); fields["done"] = .bool(false); fields["paidAmountCents"] = .null; fields["pausedUntil"] = .null
            return .object(fields)
        })
        return result
    }
}

struct NativeParticipantPayment: Identifiable {
    let fields: JSONObject
    var id: String { fields.text("id") }
    var name: String { fields.text("name") }
    var shortName: String { name.split(separator: " ").first.map(String.init) ?? name }
    var paid: Bool { fields.integer("dueCents") > 0 && fields.integer("pendingCents") == 0 }
    var partial: Bool { !paid && fields.integer("paidCents") > 0 }
    var label: String { fields.integer("dueCents") == 0 ? "Sem valor" : paid ? "Pago" : partial ? "Parcial" : "Pendente" }
}

struct NativeExpenseCardPayment {
    let total: Int, pending: Int, paid: Int
    let complete: Bool
    let participants: [NativeParticipantPayment]
    var fraction: Double { total > 0 ? max(0, min(1, Double(total - pending) / Double(total))) : 0 }
    var settledCount: Int { participants.filter(\.paid).count }
    var peopleCount: Int { participants.filter { $0.fields.integer("dueCents") > 0 }.count }
    init(_ data: NativeFinanceSnapshot, id: String) {
        let progress = data.active.record("paymentProgress").record(id)
        total = max(0, Int((data.expenseCalculation(id).decimal("integral") * 100).rounded()))
        let changed = data.active.record("paymentChanges").record(id).decimal("difference") > 0.004
        pending = progress.isEmpty ? (data.paid(id) && !changed ? 0 : total) : max(0, progress.integer("pendingCents"))
        paid = progress.isEmpty ? max(0, total - pending) : max(0, progress.integer("paidCents"))
        complete = total > 0 && pending == 0 && !changed && (progress.isEmpty ? data.paid(id) : progress.flag("complete"))
        participants = progress.objects("participants").map(NativeParticipantPayment.init)
    }
}

enum NativeStandaloneReminderPlan {
    static func build(_ records: [JSONObject], now: Date, preferences: NativeNotificationPreferences) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for record in records where record.text("status") == "active" {
            guard var date = NativeDate.parse(record.text("scheduledAt")) else { continue }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: record.text("timezone")) ?? TimeZone(identifier: "America/Sao_Paulo")!
            let anchor = calendar.component(.day, from: date), month = calendar.component(.month, from: date)
            let hour = calendar.component(.hour, from: date), minute = calendar.component(.minute, from: date), second = calendar.component(.second, from: date)
            var added = 0, seen = Set<Date>()
            for _ in 0..<2000 {
                let fire = preferences.deliveryDate(date)
                if fire > now, seen.insert(fire).inserted {
                    result.append(.init(id: "sl-task-general-\(record.text("id"))-\(added)", taskID: "reminder:" + record.text("id"), title: record.text("title"), body: record.text("body"), date: fire)); added += 1
                }
                if added == 8 || record.text("recurrence") == "once" { break }
                let repeatKind = record.text("recurrence")
                guard ["daily", "weekly", "monthly", "yearly"].contains(repeatKind) else { break }
                var next: Date
                if repeatKind == "monthly" || repeatKind == "yearly" {
                    var parts = calendar.dateComponents([.year, .month], from: date)
                    parts.day = 1; parts.hour = 12
                    guard let base = calendar.date(from: parts), let advanced = calendar.date(byAdding: repeatKind == "yearly" ? .year : .month, value: 1, to: base) else { break }
                    parts = calendar.dateComponents([.year, .month], from: advanced)
                    if repeatKind == "yearly" { parts.month = month }
                    parts.day = 1; parts.hour = 12
                    guard let first = calendar.date(from: parts), let range = calendar.range(of: .day, in: .month, for: first) else { break }
                    parts.day = min(anchor, range.count); parts.hour = hour; parts.minute = minute; parts.second = second
                    guard let occurrence = calendar.date(from: parts) else { break }
                    next = occurrence
                } else {
                    guard let occurrence = calendar.date(byAdding: repeatKind == "weekly" ? .weekOfYear : .day, value: 1, to: date) else { break }
                    next = occurrence
                }
                date = next
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}
