import AppKit
import CoreText
import CryptoKit
import Foundation
import PDFKit

enum ResumeDeliverySourceFormat: String, Codable, CaseIterable, Sendable {
    case pdf
    case plainText
    case markdown

    static func resolve(fileExtension: String) throws -> ResumeDeliverySourceFormat {
        switch fileExtension.lowercased() {
        case "pdf": .pdf
        case "txt": .plainText
        case "md": .markdown
        default: throw ResumeDeliveryFileError.unsupportedFileExtension(fileExtension)
        }
    }
}

struct ResumeDeliverySourceSnapshot: Equatable, Sendable {
    let url: URL
    let format: ResumeDeliverySourceFormat
    let size: Int
    let modifiedAt: Date
}

struct PreparedResumeDeliveryFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let mimeType: String
    let size: Int
    let sourceModifiedAt: Date

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

struct ResumeDeliveryPDFLayout: Equatable, Sendable {
    let pageSize: CGSize
    let topMargin: CGFloat
    let rightMargin: CGFloat
    let bottomMargin: CGFloat
    let leftMargin: CGFloat
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat

    static let a4 = ResumeDeliveryPDFLayout(
        pageSize: CGSize(width: 595.28, height: 841.89),
        topMargin: 54,
        rightMargin: 54,
        bottomMargin: 54,
        leftMargin: 54,
        fontSize: 11.5,
        lineSpacing: 3,
        paragraphSpacing: 5
    )

    var printableRect: CGRect {
        CGRect(
            x: leftMargin,
            y: bottomMargin,
            width: pageSize.width - leftMargin - rightMargin,
            height: pageSize.height - topMargin - bottomMargin
        )
    }

    var isValid: Bool {
        pageSize.width > 0 &&
        pageSize.height > 0 &&
        topMargin >= 0 &&
        rightMargin >= 0 &&
        bottomMargin >= 0 &&
        leftMargin >= 0 &&
        printableRect.width > 0 &&
        printableRect.height > 0 &&
        fontSize > 0 &&
        lineSpacing >= 0 &&
        paragraphSpacing >= 0
    }
}

enum ResumeDeliveryFileError: LocalizedError, Equatable {
    case missingAttachment
    case unsupportedFileExtension(String)
    case sourceDoesNotExist(URL)
    case unsafeSource(URL)
    case emptySource(URL)
    case sourceSizeMismatch(expected: Int, actual: Int)
    case sourceChangedDuringRead(URL)
    case unreadableText
    case unreadablePDF
    case invalidPDFLayout
    case pdfRenderingFailed
    case unsafeDeliveryDirectory(URL)
    case unsafeDeliveryFile(URL)
    case deliveryWriteFailed(URL)
    case deliveryPDFTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .missingAttachment:
            "请先导入附件简历。"
        case .unsupportedFileExtension(let fileExtension):
            "不支持的简历格式：\(fileExtension.isEmpty ? "无扩展名" : fileExtension)。"
        case .sourceDoesNotExist:
            "本地简历附件已不存在，请重新导入。"
        case .unsafeSource:
            "简历附件不是可安全读取的普通文件。"
        case .emptySource:
            "简历附件为空。"
        case .sourceSizeMismatch(let expected, let actual):
            "简历附件已变更（记录 \(expected) 字节，当前 \(actual) 字节），请重新导入。"
        case .sourceChangedDuringRead:
            "读取期间简历附件发生变化，本次准备已取消。"
        case .unreadableText:
            "纯文本简历必须是非空的 UTF-8 文件。"
        case .unreadablePDF:
            "PDF 简历无法读取、已加密或没有有效页面。"
        case .invalidPDFLayout:
            "PDF 页面布局无效。"
        case .pdfRenderingFailed:
            "无法将纯文本简历生成 PDF。"
        case .unsafeDeliveryDirectory:
            "无法创建安全的简历投递目录。"
        case .unsafeDeliveryFile:
            "简历投递文件的存储位置不安全。"
        case .deliveryWriteFailed:
            "简历投递 PDF 写入或回读校验失败。"
        case .deliveryPDFTooLarge(let maximumBytes):
            "简历投递 PDF 超过 \(maximumBytes / 1_048_576) MB 上限。"
        }
    }
}

enum ResumeDeliveryFileService {
    static let deliveryMIMEType = "application/pdf"
    static let deliveryFileName = "current-resume-delivery.pdf"
    static let maximumDeliveryPDFBytes = 20 * 1_048_576

    static func prepareCurrentAttachment(
        path: String?,
        expectedSourceSize: Int? = nil,
        deliveryDirectory: URL? = nil,
        layout: ResumeDeliveryPDFLayout = .a4
    ) throws -> PreparedResumeDeliveryFile {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResumeDeliveryFileError.missingAttachment
        }
        return try prepare(
            sourceURL: URL(fileURLWithPath: path),
            expectedSourceSize: expectedSourceSize,
            deliveryDirectory: deliveryDirectory,
            layout: layout
        )
    }

    static func prepare(
        sourceURL: URL,
        expectedSourceSize: Int? = nil,
        deliveryDirectory: URL? = nil,
        layout: ResumeDeliveryPDFLayout = .a4
    ) throws -> PreparedResumeDeliveryFile {
        let sourceURL = sourceURL.standardizedFileURL
        let initialSnapshot = try validateSource(sourceURL, expectedSize: expectedSourceSize)
        let directory = try securedDeliveryDirectory(deliveryDirectory)
        let destination = directory.appendingPathComponent(deliveryFileName, isDirectory: false)

        guard sourceURL.path != destination.standardizedFileURL.path else {
            throw ResumeDeliveryFileError.unsafeSource(sourceURL)
        }

        let sourceData = try Data(contentsOf: sourceURL)
        let finalSnapshot = try validateSource(sourceURL, expectedSize: expectedSourceSize)
        guard sourceData.count == initialSnapshot.size,
              finalSnapshot.size == initialSnapshot.size,
              finalSnapshot.modifiedAt == initialSnapshot.modifiedAt else {
            throw ResumeDeliveryFileError.sourceChangedDuringRead(sourceURL)
        }

        let deliveryData: Data
        switch initialSnapshot.format {
        case .pdf:
            try validatePDF(sourceData)
            deliveryData = sourceData
        case .plainText, .markdown:
            let text = try decodeUTF8Text(sourceData)
            deliveryData = try renderPDFData(text: text, layout: layout)
        }

        guard deliveryData.count <= maximumDeliveryPDFBytes else {
            throw ResumeDeliveryFileError.deliveryPDFTooLarge(
                maximumBytes: maximumDeliveryPDFBytes
            )
        }
        try validatePDF(deliveryData)
        try writeAtomically(deliveryData, to: destination, in: directory)

        let writtenData = try Data(contentsOf: destination)
        guard writtenData == deliveryData else {
            throw ResumeDeliveryFileError.deliveryWriteFailed(destination)
        }
        guard writtenData.count <= maximumDeliveryPDFBytes else {
            throw ResumeDeliveryFileError.deliveryPDFTooLarge(
                maximumBytes: maximumDeliveryPDFBytes
            )
        }
        try validatePDF(writtenData)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard permissions == 0o600 else {
            throw ResumeDeliveryFileError.deliveryWriteFailed(destination)
        }

        return PreparedResumeDeliveryFile(
            path: destination.path,
            sha256: sha256Hex(of: writtenData),
            mimeType: deliveryMIMEType,
            size: writtenData.count,
            sourceModifiedAt: initialSnapshot.modifiedAt
        )
    }

    static func validateSource(_ sourceURL: URL, expectedSize: Int? = nil) throws -> ResumeDeliverySourceSnapshot {
        let sourceURL = sourceURL.standardizedFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ResumeDeliveryFileError.sourceDoesNotExist(sourceURL)
        }

        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw ResumeDeliveryFileError.unsafeSource(sourceURL)
        }

        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard let rawSize = values.fileSize ?? (attributes[.size] as? NSNumber)?.intValue,
              rawSize > 0 else {
            throw ResumeDeliveryFileError.emptySource(sourceURL)
        }
        if let expectedSize, expectedSize != rawSize {
            throw ResumeDeliveryFileError.sourceSizeMismatch(expected: expectedSize, actual: rawSize)
        }
        guard let modifiedAt = values.contentModificationDate ?? attributes[.modificationDate] as? Date else {
            throw ResumeDeliveryFileError.unsafeSource(sourceURL)
        }

        return ResumeDeliverySourceSnapshot(
            url: sourceURL,
            format: try ResumeDeliverySourceFormat.resolve(fileExtension: sourceURL.pathExtension),
            size: rawSize,
            modifiedAt: modifiedAt
        )
    }

    static func decodeUTF8Text(_ data: Data) throws -> String {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ResumeDeliveryFileError.unreadableText
        }
        if text.first == "\u{feff}" {
            text.removeFirst()
        }
        guard !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResumeDeliveryFileError.unreadableText
        }
        return text
    }

    static func renderPDFData(
        text: String,
        layout: ResumeDeliveryPDFLayout = .a4
    ) throws -> Data {
        guard layout.isValid else {
            throw ResumeDeliveryFileError.invalidPDFLayout
        }
        guard !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResumeDeliveryFileError.unreadableText
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = layout.lineSpacing
        paragraphStyle.paragraphSpacing = layout.paragraphSpacing
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: layout.fontSize),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraphStyle
            ]
        )

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw ResumeDeliveryFileError.pdfRenderingFailed
        }
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ResumeDeliveryFileError.pdfRenderingFailed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        var nextLocation = 0
        while nextLocation < attributedText.length {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)

            let path = CGPath(rect: layout.printableRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: nextLocation, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()

            guard visibleRange.length > 0 else {
                context.closePDF()
                throw ResumeDeliveryFileError.pdfRenderingFailed
            }
            nextLocation += visibleRange.length
        }
        context.closePDF()

        let data = output as Data
        guard !data.isEmpty else {
            throw ResumeDeliveryFileError.pdfRenderingFailed
        }
        return data
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatePDF(_ data: Data) throws {
        guard let document = PDFDocument(data: data),
              document.pageCount > 0,
              !document.isLocked else {
            throw ResumeDeliveryFileError.unreadablePDF
        }
    }

    private static func securedDeliveryDirectory(_ override: URL?) throws -> URL {
        let directory: URL
        if let override {
            directory = override.standardizedFileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("BossPilot/DeliveryAttachments", isDirectory: true)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ResumeDeliveryFileError.unsafeDeliveryDirectory(directory)
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw ResumeDeliveryFileError.unsafeDeliveryDirectory(directory)
            }
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            guard permissions == 0o700 else {
                throw ResumeDeliveryFileError.unsafeDeliveryDirectory(directory)
            }
        } catch let error as ResumeDeliveryFileError {
            throw error
        } catch {
            throw ResumeDeliveryFileError.unsafeDeliveryDirectory(directory)
        }
        return directory
    }

    private static func writeAtomically(_ data: Data, to destination: URL, in directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ResumeDeliveryFileError.unsafeDeliveryFile(destination)
            }
        }

        let temporary = directory.appendingPathComponent(".resume-delivery-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ResumeDeliveryFileError.deliveryWriteFailed(destination)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

            guard rename(temporary.path, destination.path) == 0 else {
                throw ResumeDeliveryFileError.deliveryWriteFailed(destination)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch let error as ResumeDeliveryFileError {
            throw error
        } catch {
            throw ResumeDeliveryFileError.deliveryWriteFailed(destination)
        }
    }
}
