import Foundation

enum StatePersistenceError: LocalizedError {
    case symbolicLink(URL)

    var errorDescription: String? {
        switch self {
        case .symbolicLink(let url):
            "拒绝读写符号链接：\(url.path)"
        }
    }
}

struct JSONStatePersistence {
    let fileURL: URL
    private let saveQueue = DispatchQueue(label: "app.bosspilot.desktop.state-save", qos: .utility)

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func live() -> JSONStatePersistence {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JSONStatePersistence(fileURL: base.appendingPathComponent("BossPilot/state.json"))
    }

    func load() throws -> AppSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try removeLegacyBackupIfPresent()
            return AppSnapshot()
        }
        try rejectSymbolicLink(fileURL)
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(AppSnapshot.self, from: data)
        try removeLegacyBackupIfPresent()
        return snapshot
    }

    func save(_ snapshot: AppSnapshot) throws {
        try saveQueue.sync { try write(snapshot) }
    }

    func saveInBackground(
        _ snapshot: AppSnapshot,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        saveQueue.async {
            do {
                try write(snapshot)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // 普通保存和安全账本共用写入顺序，避免旧界面快照覆盖已提交记录。
    private func write(_ snapshot: AppSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try rejectSymbolicLink(directory)
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try removeLegacyBackupIfPresent()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try rejectSymbolicLink(fileURL)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw StatePersistenceError.symbolicLink(url)
        }
    }

    private func removeLegacyBackupIfPresent() throws {
        let directory = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try rejectSymbolicLink(directory)
        let backupURL = directory.appendingPathComponent("state.backup.json")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
    }
}
