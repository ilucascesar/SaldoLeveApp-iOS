import Foundation

// Only user-editable fields participate. Revision, cycle and payment-history
// metadata always come from the server when acknowledging a save.
struct NativeTaskConflict: Identifiable {
    var id: String { (checkID ?? "task") + ":" + (key ?? "record") }
    let checkID: String?
    let key: String?
    let label: String
    let remote: JSONValue?

    func localValue(in task: NativeTask) -> JSONValue? {
        guard let checkID else { return key.flatMap { task.fields[$0] } }
        let check = task.checks.first { $0.id == checkID }
        return key.flatMap { check?.fields[$0] } ?? (key == nil ? check.map { .object($0.fields) } : nil)
    }
    func takingRemote(in task: NativeTask) -> NativeTask {
        var result = task
        guard let checkID else { if let key { result.fields[key] = remote }; return result }
        var checks = task.checks.map(\.fields)
        if let key, let index = checks.firstIndex(where: { $0.text("id") == checkID }) { checks[index][key] = remote }
        else if key == nil {
            checks.removeAll { $0.text("id") == checkID }
            if let remote, case .object(let value) = remote { checks.append(value) }
        }
        result.fields["checklist"] = .array(checks.map(JSONValue.object)); return result
    }
    static func display(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "Sem valor / removido" }
        switch value {
        case .string(let text): return text.isEmpty ? "Em branco" : text
        case .bool(let flag): return flag ? "Sim" : "Não"
        case .number: return value.string
        case .object(let fields): return fields.text("text").isEmpty ? String(describing: fields) : fields.text("text")
        case .array(let values): return values.map { display($0) }.joined(separator: ", ")
        case .null: return "Sem valor"
        }
    }
}

struct NativeTaskMerge {
    var task: NativeTask
    var conflicts: [NativeTaskConflict] = []
    static let taskKeys = ["kind", "title", "body", "status", "dueAt", "startAt", "sortOrder", "assignedTo", "tags", "pinned", "important", "urgent", "timezone", "section", "repeat", "reminderOffsets", "overdueMinutes", "dateRemindersEnabled", "moneyMode", "amountCents", "variableAmount", "weekendAdvance", "pausedUntil"]
    static let checkKeys = ["text", "done", "remindAt", "repeatMonthly", "amountCents", "paidAmountCents", "variableAmount", "pausedUntil"]
    private static let moneyKeys: Set<String> = ["done", "amountCents", "paidAmountCents"]
    private static func equal(_ a: JSONValue?, _ b: JSONValue?) -> Bool { (a ?? .null) == (b ?? .null) }

    init(local: NativeTask, base: NativeTask?, remote: NativeTask) {
        task = remote
        let cycleChanged = base.map { !Self.equal($0.fields["cycleNumber"], remote.fields["cycleNumber"]) } ?? false
        func overlay(_ local: JSONObject, _ old: JSONObject?, _ remote: JSONObject, keys: [String], checkID: String?, label: String, cycle: Bool) -> JSONObject {
            var result = remote
            let remoteMoneyChanged = old.map { previous in
                Self.moneyKeys.contains { !Self.equal(previous[$0], remote[$0]) } ||
                ["completedCount", "lastCompletedAt"].contains { !Self.equal(previous[$0], remote[$0]) }
            } ?? false
            for key in keys {
                if let old, Self.equal(local[key], old[key]) { continue }
                if Self.equal(local[key], remote[key]) { continue }
                // A monthly rollover or another payment cannot be combined
                // silently with a stale financial/date operation.
                let sensitive = cycle && ["status", "dueAt", "remindAt", "amountCents", "paidAmountCents", "done"].contains(key)
                let coupled = checkID != nil && Self.moneyKeys.contains(key) && remoteMoneyChanged
                if old == nil || !Self.equal(remote[key], old?[key]) || sensitive || coupled {
                    conflicts.append(.init(checkID: checkID, key: key, label: label + " · " + Self.label(key), remote: remote[key]))
                }
                result[key] = local[key]
            }
            // Keep invalid-entry flags until the user fixes the field.
            for (key, value) in local where key.hasPrefix("_native") { result[key] = value }
            return result
        }
        task.fields = overlay(local.fields, base?.fields, remote.fields, keys: Self.taskKeys, checkID: nil, label: "Tarefa", cycle: cycleChanged)
        if let base, remote.status != base.status, ["trashed", "archived"].contains(remote.status), local != base,
           !conflicts.contains(where: { $0.checkID == nil && $0.key == "status" }) {
            conflicts.append(.init(checkID: nil, key: "status", label: "Tarefa · Situação", remote: remote.fields["status"]))
            task.fields["status"] = local.fields["status"]
        }
        let localChecks = Dictionary(local.checks.map { ($0.id, $0.fields) }, uniquingKeysWith: { _, last in last })
        let oldChecks = base.map { Dictionary($0.checks.map { ($0.id, $0.fields) }, uniquingKeysWith: { _, last in last }) }
        let remoteChecks = Dictionary(remote.checks.map { ($0.id, $0.fields) }, uniquingKeysWith: { _, last in last })
        var checks = remoteChecks
        for id in Set(localChecks.keys).union(oldChecks?.keys.map { $0 } ?? []).sorted() {
            let localCheck = localChecks[id], old = oldChecks?[id], server = remoteChecks[id]
            let label = localCheck?.text("text") ?? old?.text("text") ?? "Subtarefa"
            if oldChecks == nil {
                if let localCheck, let server { checks[id] = overlay(localCheck, nil, server, keys: Self.checkKeys, checkID: id, label: label, cycle: false) }
                else if localCheck != server {
                    conflicts.append(.init(checkID: id, key: nil, label: label, remote: server.map(JSONValue.object)))
                    checks[id] = localCheck
                }
            } else if let localCheck, let old, let server {
                checks[id] = overlay(localCheck, old, server, keys: Self.checkKeys, checkID: id, label: label, cycle: cycleChanged)
            } else if localCheck == old { /* An unchanged local record follows the server, including deletion. */ }
            else if server == old { checks[id] = localCheck }
            else if localCheck != server {
                conflicts.append(.init(checkID: id, key: nil, label: label, remote: server.map(JSONValue.object)))
                checks[id] = localCheck
            }
        }
        // Preserve remote additions; local order wins only when actually edited.
        let oldOrder = base?.checks.map(\.id) ?? []
        let localOrder = local.checks.map(\.id)
        let localReordered = localOrder.filter { oldOrder.contains($0) } != oldOrder.filter { localOrder.contains($0) }
        var order = localReordered ? localOrder : remote.checks.map(\.id)
        for id in localOrder + remote.checks.map(\.id) where !order.contains(id) { order.append(id) }
        task.fields["checklist"] = .array(order.compactMap { checks[$0].map(JSONValue.object) })
    }
    private static func label(_ key: String) -> String {
        ["title": "Título", "body": "Descrição", "text": "Texto", "done": "Concluída / paga", "status": "Situação", "amountCents": "Valor original", "paidAmountCents": "Valor pago", "dueAt": "Data", "remindAt": "Data", "repeat": "Repetição" ][key] ?? key
    }
}

struct NativeTaskSaveReceipt { let submitted: NativeTask; let canonical: NativeTask }
struct NativeTaskSaveIssue: Error { let underlying: Error; let remote: NativeTask? }

enum NativeTaskSync {
    // Read back ambiguous writes; a server rejection is never automatically replayed.
    @MainActor static func save(_ task: NativeTask, base: NativeTask?, write: (NativeTask) async throws -> NativeTask, read: () async throws -> NativeTask) async throws -> NativeTaskSaveReceipt {
        do { return .init(submitted: task, canonical: try await write(task)) }
        catch {
            if (error as? NativeFailure)?.status == 499 { throw error }
            guard !task.id.isEmpty else { throw NativeTaskSaveIssue(underlying: error, remote: nil) }
            let latest = try? await read()
            if let latest, NativeTaskMerge(local: task, base: base, remote: latest).task == latest {
                return .init(submitted: task, canonical: latest)
            }
            // Never replay a stale write or merge a recovered local draft over
            // newer server data. The caller must display the server version.
            throw NativeTaskSaveIssue(underlying: error, remote: latest)
        }
    }
}
