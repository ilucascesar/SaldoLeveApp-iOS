import Foundation

@main struct PerformanceCheck {
    static func main() {
        var snapshot = NativeSnapshot()
        snapshot.lists = [NativeCategory(["id": .string("1"), "name": .string("Pessoal"), "archived": .bool(false), "canEdit": .bool(true)])]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        snapshot.items = (1...5000).map { id in
            let due = NativeDate.iso(start.addingTimeInterval(Double(id % 42) * 86400))
            return NativeTask(["id": .string(String(id)), "listId": .string("1"), "title": .string("Tarefa \(id)"), "status": .string("todo"), "dueAt": .string(due), "checklist": .array([])])
        }
        let clock = Date()
        let index = NativeTaskIndex(snapshot, userID: "1", now: start)
        let built = Date().timeIntervalSince(clock)
        let days = (0..<42).map { Calendar.current.startOfDay(for: start.addingTimeInterval(Double($0) * 86400)) }
        let originalStart = Date()
        let reference = days.map { day in snapshot.items.filter { task in NativeTaskIndex.dates(task).contains { Calendar.current.isDate($0, inSameDayAs: day) } }.count }
        let originalTime = Date().timeIntervalSince(originalStart)
        let indexedStart = Date()
        let actual = days.map { index.count(day: $0) }
        let indexedTime = Date().timeIntervalSince(indexedStart)
        precondition(reference == actual && actual.reduce(0,+) == 5000, "Indexed calendar changed task counts")
        let queryStart = Date()
        let tasks = NativeTaskQuery.select(snapshot, scope: .all)
        let queryTime = Date().timeIntervalSince(queryStart)
        precondition(tasks.count == 5000)
        print(String(format: "Performance with 5000 tasks: build index %.3fs; 42 calendar cells previous %.3fs, indexed %.6fs; all-task query %.3fs.", built, originalTime, indexedTime, queryTime))
    }
}
