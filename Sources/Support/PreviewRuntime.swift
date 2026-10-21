import Foundation

struct BossPilotPreviewRuntime: Equatable {
    let stateURL: URL
    let processLockURL: URL
}

enum BossPilotLaunchMode: Equatable {
    case standard
    case uiPreview(BossPilotPreviewRuntime)

    var performsLiveRuntimeWork: Bool {
        if case .standard = self { return true }
        return false
    }

    var previewRuntime: BossPilotPreviewRuntime? {
        guard case .uiPreview(let runtime) = self else { return nil }
        return runtime
    }

    static func resolve(
        arguments: [String],
        environment: [String: String],
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> BossPilotLaunchMode {
        guard arguments.contains("--ui-preview") else { return .standard }

        let temporaryRoot = temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let requestedStateURL = environment["BOSSPILOT_PREVIEW_STATE_PATH"]
            .map { URL(fileURLWithPath: $0) }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let stateURL: URL
        if let requestedStateURL,
           isStrictDescendant(requestedStateURL, of: temporaryRoot) {
            stateURL = requestedStateURL
        } else {
            stateURL = temporaryRoot
                .appendingPathComponent("BossPilot-UI-Preview-\(processIdentifier)", isDirectory: true)
                .appendingPathComponent("state.json")
        }

        return .uiPreview(
            BossPilotPreviewRuntime(
                stateURL: stateURL,
                processLockURL: stateURL.appendingPathExtension("lock")
            )
        )
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
    }
}
