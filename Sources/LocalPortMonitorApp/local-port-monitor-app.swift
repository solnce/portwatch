import SwiftUI
import PortMonitorCore

@main
@MainActor
struct LocalPortMonitorApp: App {
    @StateObject private var store: PortMonitorStore

    init() {
        let scanner = CoalescingPortScanner(scanner: LsofPortScanner())
        let store = PortMonitorStore(
            scanner: scanner,
            stopper: SafeProcessStopper()
        )
        _store = StateObject(wrappedValue: store)
        store.startMonitoring()
    }

    var body: some Scene {
        MenuBarExtra {
            PortMenuView(store: store)
        } label: {
            Label("\(store.ownedPortCount)", systemImage: store.errorMessage == nil ? "network" : "network.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
