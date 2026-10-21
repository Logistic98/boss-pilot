import SwiftUI

struct SystemSettingsView: View {
    @AppStorage("configurationSelection") private var selectedSection = "automation"
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var bossAutomation: BossAutomationController

    static func normalizedSection(_ value: String) -> String {
        value == "codex" || value == "privacy" ? "codex" : "automation"
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "系统设置",
                subtitle: "管理运行与智能引擎。",
                systemImage: "bolt.horizontal.circle"
            ) {
                StatusPill(
                    title: statusTitle,
                    systemImage: statusIcon,
                    color: statusColor
                )
            }
            Divider()
            Picker("设置类别", selection: Binding(
                get: { Self.normalizedSection(selectedSection) },
                set: { selectedSection = $0 }
            )) {
                Text("运行设置").tag("automation")
                Text("智能引擎").tag("codex")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            Divider()
            if Self.normalizedSection(selectedSection) == "codex" {
                CodexSettingsTab()
            } else {
                AutomationSettingsTab()
            }
        }
        .onAppear { selectedSection = Self.normalizedSection(selectedSection) }
    }

    private var statusTitle: String {
        if hasManualVerificationChallenge { return "需要本人验证" }
        if bossAutomation.isWorkerRunning { return "运行中" }
        if bossAutomation.isCycleRunning { return "同步中" }
        return "已停止"
    }

    private var statusIcon: String {
        if hasManualVerificationChallenge { return "person.badge.shield.checkmark" }
        if bossAutomation.isWorkerRunning { return "play.fill" }
        if bossAutomation.isCycleRunning { return "arrow.triangle.2.circlepath" }
        return "pause.fill"
    }

    private var statusColor: Color {
        if hasManualVerificationChallenge { return .orange }
        if bossAutomation.isWorkerRunning { return .green }
        if bossAutomation.isCycleRunning { return BossPilotTheme.accent }
        return .secondary
    }

    private var hasManualVerificationChallenge: Bool {
        store.snapshot.accounts.contains {
            $0.status == .active && $0.manualVerificationChallenge != nil
        }
    }
}
