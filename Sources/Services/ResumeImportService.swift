import Foundation
import PDFKit

enum ResumeImportError: LocalizedError {
    case unsupportedFile
    case unreadablePDF
    case emptyDocument
    case unsafeAttachmentLocation

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "仅支持 PDF 或纯文本简历。"
        case .unreadablePDF: "无法读取该 PDF。"
        case .emptyDocument: "文件中没有可提取的文本，请使用可搜索的 PDF 或纯文本简历。"
        case .unsafeAttachmentLocation: "无法创建安全的本地简历附件目录。"
        }
    }
}

struct ResumeImportResult: Sendable {
    let fileName: String
    let text: String
    let attachmentPath: String?
    let attachmentSize: Int?
    let inferredSkills: [String]
    let inferredYearsOfExperience: Int

    init(
        fileName: String,
        text: String,
        attachmentPath: String? = nil,
        attachmentSize: Int? = nil,
        inferredSkills: [String] = [],
        inferredYearsOfExperience: Int = 0
    ) {
        self.fileName = fileName
        self.text = text
        self.attachmentPath = attachmentPath
        self.attachmentSize = attachmentSize
        self.inferredSkills = inferredSkills
        self.inferredYearsOfExperience = inferredYearsOfExperience
    }
}

actor ResumeImportService {
    static let shared = ResumeImportService()

    // 附件写入串行执行，文本提取在后台处理。
    func importFile(from url: URL, storageDirectory: URL? = nil) throws -> ResumeImportResult {
        try Task.checkCancellation()
        return try Self.importAttachment(from: url, storageDirectory: storageDirectory)
    }

    static func extract(from url: URL) throws -> ResumeImportResult {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let normalized = try extractText(from: data, fileExtension: url.pathExtension.lowercased())
        let insight = inferProfile(from: normalized)
        return ResumeImportResult(
            fileName: url.lastPathComponent,
            text: normalized,
            attachmentSize: data.count,
            inferredSkills: insight.skills,
            inferredYearsOfExperience: insight.yearsOfExperience
        )
    }

    static func importAttachment(from url: URL, storageDirectory: URL? = nil) throws -> ResumeImportResult {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        let normalized = try extractText(from: data, fileExtension: ext)
        let destination = try attachmentDirectory(storageDirectory).appendingPathComponent("current-resume.\(ext)")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        for oldExtension in ["pdf", "txt", "md"] where oldExtension != ext {
            let stale = destination.deletingLastPathComponent().appendingPathComponent("current-resume.\(oldExtension)")
            if FileManager.default.fileExists(atPath: stale.path) {
                try? FileManager.default.removeItem(at: stale)
            }
        }

        let insight = inferProfile(from: normalized)
        return ResumeImportResult(
            fileName: url.lastPathComponent,
            text: normalized,
            attachmentPath: destination.path,
            attachmentSize: data.count,
            inferredSkills: insight.skills,
            inferredYearsOfExperience: insight.yearsOfExperience
        )
    }

    private static func extractText(from data: Data, fileExtension ext: String) throws -> String {
        let text: String
        if ext == "pdf" {
            guard let document = PDFDocument(data: data) else { throw ResumeImportError.unreadablePDF }
            text = document.string ?? ""
        } else if ext == "txt" || ext == "md" {
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw ResumeImportError.emptyDocument
            }
            text = decoded
        } else {
            throw ResumeImportError.unsupportedFile
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ResumeImportError.emptyDocument }
        return normalized
    }

    private static func attachmentDirectory(_ override: URL?) throws -> URL {
        let directory: URL
        if let override {
            directory = override
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("BossPilot/Attachments", isDirectory: true)
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ResumeImportError.unsafeAttachmentLocation
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private static func inferProfile(from text: String) -> (skills: [String], yearsOfExperience: Int) {
        let catalog = [
            "Java", "Kotlin", "Python", "Go", "Golang", "Swift", "Objective-C", "C++", "C#",
            "JavaScript", "TypeScript", "Vue", "React", "Spring", "Spring Boot", "Spring Cloud",
            "MySQL", "PostgreSQL", "Redis", "MongoDB", "Elasticsearch", "Kafka", "RabbitMQ",
            "Docker", "Kubernetes", "Linux", "AWS", "Azure", "GCP", "阿里云", "微服务",
            "大模型", "LLM", "Agent", "RAG", "LangChain", "PyTorch", "TensorFlow"
        ]
        let skills = catalog.filter { text.range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
        let pattern = #"(?<!\d)([1-9]|[12]\d|30)\s*年(?:以上|左右|工作|开发|项目|经验)?"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let years = regex?.matches(in: text, range: range).compactMap { match -> Int? in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[valueRange])
        }.max() ?? 0
        return (skills, years)
    }
}
