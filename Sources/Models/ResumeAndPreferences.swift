import Foundation

struct ResumeProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "当前简历"
    var sourceFileName: String?
    var attachmentPath: String?
    var attachmentSize: Int?
    var importedAt: Date?
    var text: String = ""
    var skills: [String] = []
    var targetRoles: [String] = []
    var yearsOfExperience: Int = 0
    var profileSummary: String = ""
    var suggestedSearchQueries: [String] = []
    var suggestedCities: [String] = []
    var profileGeneratedAt: Date?
    var profileProvider: String = ""

    var isReady: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasStoredAttachment: Bool {
        guard let attachmentPath else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: attachmentPath),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let actualSize = (attributes[.size] as? NSNumber)?.intValue,
              actualSize > 0 else {
            return false
        }
        return attachmentSize.map { $0 == actualSize } ?? true
    }

    var hasGeneratedProfile: Bool {
        !profileSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sourceFileName, attachmentPath, attachmentSize, importedAt
        case text, skills, targetRoles, yearsOfExperience
        case profileSummary, suggestedSearchQueries, suggestedCities
        case profileGeneratedAt, profileProvider
    }

    init(
        id: UUID = UUID(),
        name: String = "当前简历",
        sourceFileName: String? = nil,
        attachmentPath: String? = nil,
        attachmentSize: Int? = nil,
        importedAt: Date? = nil,
        text: String = "",
        skills: [String] = [],
        targetRoles: [String] = [],
        yearsOfExperience: Int = 0,
        profileSummary: String = "",
        suggestedSearchQueries: [String] = [],
        suggestedCities: [String] = [],
        profileGeneratedAt: Date? = nil,
        profileProvider: String = ""
    ) {
        self.id = id
        self.name = name
        self.sourceFileName = sourceFileName
        self.attachmentPath = attachmentPath
        self.attachmentSize = attachmentSize
        self.importedAt = importedAt
        self.text = text
        self.skills = skills
        self.targetRoles = targetRoles
        self.yearsOfExperience = yearsOfExperience
        self.profileSummary = profileSummary
        self.suggestedSearchQueries = suggestedSearchQueries
        self.suggestedCities = suggestedCities
        self.profileGeneratedAt = profileGeneratedAt
        self.profileProvider = profileProvider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "当前简历"
        sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName)
        attachmentPath = try container.decodeIfPresent(String.self, forKey: .attachmentPath)
        attachmentSize = try container.decodeIfPresent(Int.self, forKey: .attachmentSize)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        targetRoles = try container.decodeIfPresent([String].self, forKey: .targetRoles) ?? []
        yearsOfExperience = try container.decodeIfPresent(Int.self, forKey: .yearsOfExperience) ?? 0
        profileSummary = try container.decodeIfPresent(String.self, forKey: .profileSummary) ?? ""
        suggestedSearchQueries = try container.decodeIfPresent([String].self, forKey: .suggestedSearchQueries) ?? []
        suggestedCities = try container.decodeIfPresent([String].self, forKey: .suggestedCities) ?? []
        profileGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .profileGeneratedAt)
        profileProvider = try container.decodeIfPresent(String.self, forKey: .profileProvider) ?? ""
    }
}

struct JobRequirementsDraft: Equatable {
    var requirementText: String
    var greetingTemplate: String

    init(preferences: JobPreferences) {
        requirementText = preferences.requirementText
        greetingTemplate = preferences.greetingTemplate
    }
}

struct JobPreferences: Codable, Hashable {
    var requirementText: String = ""
    var plannedSearchQueries: [String] = []
    var plannedCities: [String] = []
    var planGeneratedAt: Date?
    var planProvider: String = ""

    // 保留旧结构化字段的解码，以便迁移为自然语言要求。
    var targetRoles: [String] = []
    var cities: [String] = []
    var bossCityCode: String = ""
    var requiredKeywords: [String] = []
    var preferredKeywords: [String] = []
    var excludedKeywords: [String] = []
    var minimumSalaryK: Int?
    var maximumSalaryK: Int?
    var minimumMatchScore: Int = 60
    var requireFullJobDescription: Bool = false
    var greetingTemplate: String = "您好，我对这个岗位很感兴趣，我的经历与岗位要求有较高匹配度，方便进一步沟通吗？"

    var hasSearchCriteria: Bool {
        !requirementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case requirementText, plannedSearchQueries, plannedCities, planGeneratedAt, planProvider
        case targetRoles, cities, bossCityCode, requiredKeywords, preferredKeywords, excludedKeywords
        case minimumSalaryK, maximumSalaryK, minimumMatchScore, requireFullJobDescription, greetingTemplate
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetRoles = try container.decodeIfPresent([String].self, forKey: .targetRoles) ?? []
        cities = try container.decodeIfPresent([String].self, forKey: .cities) ?? []
        bossCityCode = try container.decodeIfPresent(String.self, forKey: .bossCityCode) ?? ""
        requiredKeywords = try container.decodeIfPresent([String].self, forKey: .requiredKeywords) ?? []
        preferredKeywords = try container.decodeIfPresent([String].self, forKey: .preferredKeywords) ?? []
        excludedKeywords = try container.decodeIfPresent([String].self, forKey: .excludedKeywords) ?? []
        minimumSalaryK = try container.decodeIfPresent(Int.self, forKey: .minimumSalaryK)
        maximumSalaryK = try container.decodeIfPresent(Int.self, forKey: .maximumSalaryK)
        minimumMatchScore = min(100, max(0, try container.decodeIfPresent(Int.self, forKey: .minimumMatchScore) ?? 60))
        requireFullJobDescription = try container.decodeIfPresent(Bool.self, forKey: .requireFullJobDescription) ?? false
        greetingTemplate = try container.decodeIfPresent(String.self, forKey: .greetingTemplate)
            ?? "您好，我对这个岗位很感兴趣，我的经历与岗位要求有较高匹配度，方便进一步沟通吗？"
        plannedSearchQueries = try container.decodeIfPresent([String].self, forKey: .plannedSearchQueries) ?? []
        plannedCities = try container.decodeIfPresent([String].self, forKey: .plannedCities) ?? []
        planGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .planGeneratedAt)
        planProvider = try container.decodeIfPresent(String.self, forKey: .planProvider) ?? ""

        let storedRequirement = try container.decodeIfPresent(String.self, forKey: .requirementText) ?? ""
        requirementText = storedRequirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.legacyRequirementText(
                roles: targetRoles,
                cities: cities,
                minimumSalaryK: minimumSalaryK,
                maximumSalaryK: maximumSalaryK,
                required: requiredKeywords,
                preferred: preferredKeywords,
                excluded: excludedKeywords,
                requireFullDescription: requireFullJobDescription
            )
            : storedRequirement
    }

    private static func legacyRequirementText(
        roles: [String],
        cities: [String],
        minimumSalaryK: Int?,
        maximumSalaryK: Int?,
        required: [String],
        preferred: [String],
        excluded: [String],
        requireFullDescription: Bool
    ) -> String {
        var lines: [String] = []
        if !roles.isEmpty { lines.append("目标岗位：\(roles.joined(separator: "、"))") }
        if !cities.isEmpty { lines.append("工作地点：\(cities.joined(separator: "、"))") }
        if minimumSalaryK != nil || maximumSalaryK != nil {
            let minimum = minimumSalaryK.map { "\($0)K" } ?? "不限"
            let maximum = maximumSalaryK.map { "\($0)K" } ?? "不限"
            lines.append("期望月薪：\(minimum)-\(maximum)")
        }
        if !required.isEmpty { lines.append("必须满足：\(required.joined(separator: "、"))") }
        if !preferred.isEmpty { lines.append("优先考虑：\(preferred.joined(separator: "、"))") }
        if !excluded.isEmpty { lines.append("不考虑：\(excluded.joined(separator: "、"))") }
        if requireFullDescription { lines.append("只考虑职位描述完整的岗位") }
        return lines.joined(separator: "\n")
    }
}

struct ResumeIntelligence: Equatable {
    let profileSummary: String
    let searchQueries: [String]
    let cities: [String]
    let provider: String
}

struct JobSearchPlan: Equatable {
    let queries: [String]
    let cities: [String]
    let provider: String
}

struct CodexConfiguration: Codable, Hashable {
    var executablePath: String = ""
    var model: String = ""
    var reasoningEffort: String = "medium"
    var timeoutSeconds: Int = 120
    var enableJobAssessment: Bool = true
    var enableReplyDrafting: Bool = true
    var allowJobDataToCodex: Bool = false

    enum CodingKeys: String, CodingKey {
        case executablePath, model, reasoningEffort, timeoutSeconds
        case enableJobAssessment, enableReplyDrafting
        case allowJobDataToCodex
    }

    init() {}

    mutating func setAnalysisEnabled(_ enabled: Bool, for keyPath: WritableKeyPath<Self, Bool>) {
        // 旧版数据授权关闭时，各项分析均未获授权，首次启用只开放所选能力。
        if !allowJobDataToCodex {
            enableJobAssessment = false
            enableReplyDrafting = false
        }
        self[keyPath: keyPath] = enabled
        allowJobDataToCodex = enableJobAssessment || enableReplyDrafting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "medium"
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 120
        enableJobAssessment = try container.decodeIfPresent(Bool.self, forKey: .enableJobAssessment) ?? true
        enableReplyDrafting = try container.decodeIfPresent(Bool.self, forKey: .enableReplyDrafting) ?? true
        allowJobDataToCodex = try container.decodeIfPresent(Bool.self, forKey: .allowJobDataToCodex) ?? false
    }
}
