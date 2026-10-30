import Foundation

@main struct SyncTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
    @MainActor static func main() async throws {
        let base = NativeTask(["id": .string("1"), "listId": .string("1"), "title": .string("Carro"), "body": .string("Notas"), "revision": .number(1), "cycleNumber": .number(1), "status": .string("todo"), "checklist": .array([
            .object(["id": .string("a"), "text": .string("Parcela 1"), "done": .bool(false), "amountCents": .number(100000), "paidAmountCents": .null, "completedCount": .number(0)])])])
        var local = base; local.fields["title"] = .string("Meu carro")
        var remote = base; remote.fields["body"] = .string("Notas atualizadas na web"); remote.fields["revision"] = .number(2)
        let merged = NativeTaskMerge(local: local, base: base, remote: remote)
        check(merged.conflicts.isEmpty && merged.task.revision == 2 && merged.task.title == "Meu carro" && merged.task.fields.text("body") == "Notas atualizadas na web", "Stale drafts adopt the latest revision and retain disjoint edits")
        var overlap = remote; overlap.fields["title"] = .string("Carro na web")
        let conflict = NativeTaskMerge(local: local, base: base, remote: overlap)
        check(conflict.conflicts.count == 1 && conflict.task.title == local.title, "Same-field edits remain in the draft for explicit review")
        check(conflict.conflicts[0].takingRemote(in: conflict.task).title == overlap.title, "Choosing the account value resolves only that field")
        let legacy = NativeTaskMerge(local: local, base: nil, remote: remote)
        check(!legacy.conflicts.isEmpty && legacy.task.revision == 2 && legacy.task.title == local.title, "Legacy drafts with no ancestor require a review instead of silently overwriting")

        var remoteAdded = remote
        var serverChecks = remoteAdded.checks.map(\.fields)
        serverChecks[0]["done"] = .bool(true); serverChecks[0]["paidAmountCents"] = .number(65000); serverChecks[0]["completedCount"] = .number(1)
        serverChecks.append(["id": .string("b"), "text": .string("Nova na web"), "done": .bool(false)])
        remoteAdded.fields["checklist"] = .array(serverChecks.map(JSONValue.object))
        var typed = base; var typedChecks = typed.checks.map(\.fields); typedChecks[0]["text"] = .string("Nome no iPhone")
        typed.fields["checklist"] = .array(typedChecks.map(JSONValue.object))
        let duringWrite = NativeTaskMerge(local: typed, base: base, remote: remoteAdded)
        check(duringWrite.conflicts.isEmpty && duringWrite.task.checks.count == 2 && duringWrite.task.checks[0].title == "Nome no iPhone" && duringWrite.task.checks[0].done && duringWrite.task.checks[0].fields.integer("paidAmountCents") == 65000 && duringWrite.task.checks[0].fields.integer("completedCount") == 1, "Typing cannot remove remote additions, payments or history metadata")
        var payment = base; var paidChecks = payment.checks.map(\.fields); paidChecks[0]["done"] = .bool(true); paidChecks[0]["paidAmountCents"] = .number(60000)
        payment.fields["checklist"] = .array(paidChecks.map(JSONValue.object))
        let competingPayment = NativeTaskMerge(local: payment, base: base, remote: remoteAdded)
        check(competingPayment.conflicts.contains { $0.key == "paidAmountCents" }, "Competing payments cannot be merged silently")
        var newCycle = remote; newCycle.fields["cycleNumber"] = .number(2)
        let stalePayment = NativeTaskMerge(local: payment, base: base, remote: newCycle)
        check(!stalePayment.conflicts.isEmpty && stalePayment.task.fields.integer("cycleNumber") == 2, "A stale payment cannot be applied to another monthly cycle automatically")
        var deleted = remote; deleted.fields["checklist"] = .array([])
        check(!NativeTaskMerge(local: typed, base: base, remote: deleted).conflicts.isEmpty, "Editing a remotely deleted subtask needs review")
        check(NativeTaskMerge(local: base, base: base, remote: deleted).task.checks.isEmpty, "Unchanged drafts follow remote deletion")
        var localDeleted = base; localDeleted.fields["checklist"] = .array([])
        check(!NativeTaskMerge(local: localDeleted, base: base, remote: remoteAdded).conflicts.isEmpty, "Local deletion cannot erase a new remote payment without review")

        var writes = 0
        do {
            _ = try await NativeTaskSync.save(local, base: base, write: { _ in writes += 1; throw NativeFailure("Conflict", status: 409) }, read: { remote })
            fatalError("Stale local content was replayed over server data")
        } catch {
            check(writes == 1 && (error as? NativeTaskSaveIssue)?.remote == remote, "Even disjoint stale edits must yield to the server without a second POST")
        }
        writes = 0
        do {
            _ = try await NativeTaskSync.save(local, base: base, write: { _ in writes += 1; throw NativeFailure("Conflict", status: 409) }, read: { overlap })
            fatalError("Overlapping stale edit was accepted")
        } catch { check(writes == 1 && (error as? NativeTaskSaveIssue)?.remote == overlap, "Server version is returned for display without a local draft or replay") }
        writes = 0
        var persistedPayment = payment; persistedPayment.fields["revision"] = .number(2)
        let acknowledged = try await NativeTaskSync.save(payment, base: base, write: { _ in writes += 1; throw URLError(.timedOut) }, read: { persistedPayment })
        check(writes == 1 && acknowledged.canonical == persistedPayment, "A timed-out payment already persisted is acknowledged without a second POST")
        writes = 0
        do {
            _ = try await NativeTaskSync.save(payment, base: base, write: { _ in writes += 1; throw URLError(.timedOut) }, read: { base })
            fatalError("Unconfirmed payment accepted")
        } catch { check(writes == 1, "An ambiguous payment is never replayed automatically") }
        writes = 0
        do {
            _ = try await NativeTaskSync.save(payment, base: base, write: { _ in writes += 1; throw NativeFailure("Conflict", status: 409) }, read: { remoteAdded })
            fatalError("Conflicting payment replayed")
        } catch { check(writes == 1, "Another device's payment requires review") }
        print("Task sync: server authority, no stale-write replay, payment readback, history and cycle protection passed.")
    }
}
