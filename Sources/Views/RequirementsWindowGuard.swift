import AppKit
import SwiftUI

@MainActor
enum UnsavedRequirementsGuard {
    static func confirm(using store: AppStore, window: NSWindow? = nil) async -> Bool {
        guard store.hasUnsavedRequirementsChanges else { return !store.isSavingRequirements }
        guard !store.isShowingRequirementsPrompt, !store.isSavingRequirements else { return false }
        store.isShowingRequirementsPrompt = true
        defer { store.isShowingRequirementsPrompt = false }

        let alert = NSAlert()
        alert.messageText = "保存对“求职偏好”的修改？"
        alert.informativeText = "未保存的修改将丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window = window ?? NSApp.mainWindow ?? NSApp.keyWindow, window.attachedSheet == nil {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            // 已有弹窗或无可用窗口时不离开，避免未保存内容丢失。
            return false
        }
        switch response {
        case .alertFirstButtonReturn:
            return await store.saveRequirementsChanges()
        case .alertSecondButtonReturn:
            store.discardRequirementsChanges()
            return true
        default:
            return false
        }
    }
}

/// 保留 SwiftUI 窗口代理，并在关闭前检查未保存内容。
struct RequirementsWindowGuard: NSViewRepresentable {
    let store: AppStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return view
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    static func dismantleNSView(_ view: WindowProbe, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class WindowProbe: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let store: AppStore
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(store: AppStore) { self.store = store }

        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            detach()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if window?.delegate === self { window?.delegate = previousDelegate }
            previousDelegate = nil
            window = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard previousDelegate?.windowShouldClose?(sender) ?? true else { return false }
            guard store.hasUnsavedRequirementsChanges || store.isSavingRequirements else { return true }
            Task { @MainActor in
                if await UnsavedRequirementsGuard.confirm(using: store, window: sender) {
                    sender.close()
                }
            }
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate?.responds(to: selector) == true ? previousDelegate : super.forwardingTarget(for: selector)
        }
    }
}
