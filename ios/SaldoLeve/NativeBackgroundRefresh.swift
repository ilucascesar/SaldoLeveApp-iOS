import BackgroundTasks
import UIKit

@MainActor
enum NativeBackgroundRefresh {
    static let identifier = "br.com.ilucascesar.saldoleve.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await run(refresh) }
        }
        schedule()
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func run(_ task: BGAppRefreshTask) async {
        schedule()
        let job = Task { @MainActor in
            let store = NativeStore.shared
            await store.ensureStarted()
            guard !Task.isCancelled, store.user != nil else { return false }
            await store.refresh()
            guard !Task.isCancelled else { return false }
            await store.refreshExpenseReminders()
            await store.refreshGeneralReminders()
            return !store.offline && !Task.isCancelled
        }
        task.expirationHandler = { job.cancel() }
        let success = await job.value
        task.setTaskCompleted(success: success)
    }
}
