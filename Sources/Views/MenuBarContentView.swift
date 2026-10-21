import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    private var pendingCount: Int {
        let accountIDs = Set(store.statisticsAccounts.map(\.id))
        return store.snapshot.pendingActions.filter { accountIDs.contains($0.accountID) && $0.status.requiresAttention }.count
    }

    var body: some View {
        Button("打开 BossPilot") {
            openWindow(id: BossPilotSceneID.main)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Text("需要你确认：\(pendingCount)")

        Button("退出 BossPilot") {
            NSApp.terminate(nil)
        }
    }
}
