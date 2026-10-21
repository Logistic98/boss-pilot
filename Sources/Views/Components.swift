import AppKit
import SwiftUI

enum BossPilotTheme {
    static let accent = Color(red: 0.10, green: 0.38, blue: 0.96)
    static let success = Color(red: 0.12, green: 0.68, blue: 0.39)
    static let cornerRadius: CGFloat = 14
}

struct WorkspacePageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(BossPilotTheme.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 20)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

extension WorkspacePageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, systemImage: String) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

struct StatusPill: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.11), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.18)))
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MetricCard: View {
    static let height: CGFloat = 88

    static func columns(for availableWidth: CGFloat) -> [GridItem] {
        let count = availableWidth >= 4 * 156 + 3 * 12 ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(height: Self.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius).stroke(Color.secondary.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
    }
}

struct WorkspaceEmptyState<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let actions: () -> Actions

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.actions = actions
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension WorkspaceEmptyState where Actions == EmptyView {
    init(title: String, detail: String, systemImage: String) {
        self.init(title: title, detail: detail, systemImage: systemImage) { EmptyView() }
    }
}

struct AppIssueBanner: View {
    let message: String
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    let onDismiss: () -> Void

    private var title: String {
        if message.contains("安全验证") || message.contains("异常访问") || message.contains("错误 36") {
            return "BOSS 需要你完成安全验证"
        }
        if message.contains("登录") || message.contains("会话") {
            return "账号会话需要处理"
        }
        return "本次操作没有完成"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            if let actionTitle, let onAction {
                Button(actionTitle) {
                    onAction()
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭错误提示")
            .help("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension BossManualVerificationChallenge {
    var recoveryURL: URL {
        if operation.contains("沟通") || operation.contains("打招呼") {
            return OfficialBossLinkService.chat
        }
        if operation.contains("岗位") {
            return OfficialBossLinkService.jobs
        }
        return OfficialBossLinkService.home
    }
}

struct BossManualVerificationBanner: View {
    let accountLabel: String
    let challenge: BossManualVerificationChallenge
    let isRechecking: Bool
    let openVerificationPage: () -> Void
    let recheck: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                verificationSummary
                Spacer(minLength: 16)
                actions
            }

            VStack(alignment: .leading, spacing: 12) {
                verificationSummary
                actions
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius)
                .stroke(Color.orange.opacity(0.30))
        )
        .accessibilityElement(children: .contain)
    }

    private var verificationSummary: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("BOSS 需要本人验证")
                    .font(.callout.weight(.semibold))
                Text("\(accountLabel) · \(challenge.userFacingReason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(challenge.recoveryInstruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("打开验证页", action: openVerificationPage)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .help("打开 BOSS 完成本人验证")

            Button(action: recheck) {
                if isRechecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在检查")
                    }
                } else {
                    Text("我已完成，重新检查")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRechecking)
            .help("完成验证后检查账号状态")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension View {
    func selectionHighlight(_ selected: Bool) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? BossPilotTheme.accent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? BossPilotTheme.accent.opacity(0.65) : .clear)
            }
            .listRowBackground(Color.clear)
            .background(ListSelectionAppearance())
    }

    func panelStyle() -> some View {
        padding(17)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: BossPilotTheme.cornerRadius).stroke(Color.secondary.opacity(0.14)))
    }
}

// 焦点移到其他面板或窗口后仍显示选中状态。
private struct ListSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) { view.configureTable() }

    final class SelectionView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureTable()
        }

        func configureTable() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
