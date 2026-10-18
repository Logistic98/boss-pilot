import Foundation

enum JobStage: String, Codable, CaseIterable {
    case discovered
    case rejected
    case recommended
    case greetingDrafted
    case contacted
    case resumeRequested
    case resumeSent
    case closed

    var title: String {
        switch self {
        case .discovered: "待评估"
        case .rejected: "不匹配"
        case .recommended: "推荐"
        case .greetingDrafted: "已尝试开聊"
        case .contacted: "已沟通"
        case .resumeRequested: "对方接受简历"
        case .resumeSent: "简历已发送"
        case .closed: "已结束"
        }
    }

    /// “已开聊”仅包含确认出站或后续会话状态；开聊尝试记录只用于防重。
    var countsAsOpenedChat: Bool {
        switch self {
        case .contacted, .resumeRequested, .resumeSent:
            true
        case .discovered, .rejected, .recommended, .greetingDrafted, .closed:
            false
        }
    }

    /// 成功交换单独归入“已交换”，此前的沟通状态归入“已开聊”。
    var belongsToContactedCategory: Bool {
        countsAsOpenedChat && self != .resumeSent
    }
}

enum AssessmentConfidence: String, Codable, CaseIterable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }
}

struct JobAssessment: Codable, Hashable {
    var score: Int
    var recommendation: String
    var confidence: AssessmentConfidence
    var reasons: [String]
    var risks: [String]
    var greeting: String
    var assessedAt: Date
    var provider: String

    func passesQualityGate(minimumScore: Int) -> Bool {
        score >= minimumScore && (recommendation == "推荐" || recommendation == "可尝试")
    }
}

struct JobListing: Identifiable, Codable, Hashable {
    var id: String
    var accountID: UUID
    var title: String
    var company: String
    var location: String
    var salary: String
    var experience: String
    var education: String
    var description: String
    var url: String
    var capturedAt: Date
    var stage: JobStage
    var assessment: JobAssessment?
    var remoteJobID: String?
    var securityID: String?
    var listID: String?
    var recruiterName: String?
    var recruiterTitle: String?
    var industry: String?
    var companySize: String?
    var financingStage: String?
    var tags: [String]?
    var benefits: [String]?
    /// 同账号详情读取成功后设置，空描述也缓存；推荐仍须有完整描述，列表摘要不能替代。
    var detailFetchedAt: Date?

    init(
        id: String,
        accountID: UUID,
        title: String,
        company: String,
        location: String = "",
        salary: String = "",
        experience: String = "",
        education: String = "",
        description: String = "",
        url: String = ""
    ) {
        self.id = id
        self.accountID = accountID
        self.title = title
        self.company = company
        self.location = location
        self.salary = salary
        self.experience = experience
        self.education = education
        self.description = description
        self.url = url
        self.capturedAt = Date()
        self.stage = .discovered
        self.remoteJobID = nil
        self.securityID = nil
        self.listID = nil
        self.recruiterName = nil
        self.recruiterTitle = nil
        self.industry = nil
        self.companySize = nil
        self.financingStage = nil
        self.tags = nil
        self.benefits = nil
        self.detailFetchedAt = nil
    }

    var hasCachedDetail: Bool { detailFetchedAt != nil }

    var hasAuthoritativeDescription: Bool {
        detailFetchedAt != nil && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var recruiterDisplayLabel: String {
        [recruiterName, recruiterTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var displayLocation: String {
        BossCityResolver.displayText(for: location)
    }

    var displayIndustry: String { BossIndustryResolver.displayText(for: industry) }

    var evidenceText: String {
        [
            title, company, displayLocation, salary, experience, education,
            recruiterName, recruiterTitle, displayIndustry, companySize, financingStage,
            tags?.joined(separator: " "), benefits?.joined(separator: " "), description
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
