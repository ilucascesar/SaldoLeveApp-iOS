import SwiftUI

@main
struct SaldoLeveApp: App {
    // Receives the app icon quick actions (Nova tarefa, Suspender avisos).
    @UIApplicationDelegateAdaptor(NativeAppDelegate.self) private var delegate
    var body: some Scene { WindowGroup { NativeRootView() } }
}
