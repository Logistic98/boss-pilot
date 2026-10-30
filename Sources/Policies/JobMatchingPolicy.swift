import Foundation

struct JobMatchingPolicy {
    struct SalaryRange: Equatable {
        let minimumK: Int
        let maximumK: Int
    }

    static func assess(
        job: JobListing,
        resume: ResumeProfile,
        preferences: JobPreferences
    ) -> JobAssessment {
        guard job.hasAuthoritativeDescription else {
            return JobAssessment(
                score: 0,
                recommendation: "待补全",
                confidence: .low,
                reasons: [],
                risks: ["尚未取得 BOSS 权威职位描述"],
                greeting: "",
                assessedAt: Date(),
                provider: "本地规则"
            )
        }
        let evidence = normalized(job.evidenceText)
        let excluded = matchingExclusions(in: job.evidenceText, preferences: preferences)
        if !excluded.isEmpty {
            return JobAssessment(
                score: 0,
                recommendation: "不建议",
                confidence: .high,
                reasons: [],
                risks: ["命中排除项：\(excluded.joined(separator: "、"))"],
                greeting: "",
                assessedAt: Date(),
                provider: "本地规则"
            )
        }

        var score = 20
        var reasons: [String] = []
        var risks: [String] = []

        let roleTerms = unique(preferences.plannedSearchQueries + resume.suggestedSearchQueries)
        if roleTerms.isEmpty {
            risks.append("尚未设置目标岗位")
        } else if let role = roleTerms.first(where: { roleTerm($0, matchesTitle: job.title) }) {
            score += 25
            reasons.append("岗位名称匹配目标方向：\(role)")
        } else {
            score -= 10
            risks.append("岗位名称未命中目标方向")
        }

        let required = JobSearchPlanningPolicy.explicitRequiredTerms(in: preferences.requirementText)
        let missingRequired = required.filter { !containsTerm($0, in: evidence) }
        if missingRequired.isEmpty, !required.isEmpty {
            score += 20
            reasons.append("满足全部必需关键词")
        } else if !missingRequired.isEmpty {
            score -= min(30, missingRequired.count * 10)
            risks.append("缺少必需关键词：\(missingRequired.joined(separator: "、"))")
        }

        let preferred = unique(
            JobSearchPlanningPolicy.explicitPreferredTerms(in: preferences.requirementText) + resume.skills
        )
        let preferredHits = preferred.filter { containsTerm($0, in: evidence) }
        if !preferredHits.isEmpty {
            score += min(25, preferredHits.count * 5)
            reasons.append("技能或偏好命中：\(preferredHits.prefix(5).joined(separator: "、"))")
        }

        let requirementCities = JobSearchPlanningPolicy.cities(in: preferences.requirementText)
        let preferredCities = requirementCities.isEmpty
            ? preferences.plannedCities.filter { $0 != "全国" }
            : requirementCities
        if !preferredCities.isEmpty {
            if let city = preferredCities.first(where: { containsTerm($0, in: normalized(job.displayLocation)) }) {
                score += 10
                reasons.append("工作地点匹配：\(city)")
            } else {
                score -= 15
                risks.append("工作地点不在偏好城市")
            }
        }

        if let desiredSalary = salaryRange(from: preferences.requirementText) {
            if let salary = salaryRange(from: job.salary) {
                let coverage = salaryCoverage(candidate: salary, desired: desiredSalary)
                if coverage >= 0.5 {
                    score += 10
                    reasons.append("薪资区间满足主要期望")
                } else if salaryRangesOverlap(candidate: salary, desired: desiredSalary) {
                    score += 5
                    reasons.append("薪资区间与期望边界相交")
                    risks.append("期望薪资位于岗位区间边界，建议沟通确认")
                } else {
                    score -= 25
                    risks.append("薪资区间与期望无重合")
                }
            } else {
                score -= 10
                risks.append("岗位薪资无法解析")
            }
        }

        let hardFailures = hardGateFailures(job: job, preferences: preferences)
        for failure in hardFailures where !risks.contains(failure) {
            risks.append(failure)
        }
        let boundedScore = min(100, max(0, score))
        let qualifies = boundedScore >= preferences.minimumMatchScore && hardFailures.isEmpty
        let confidence: AssessmentConfidence = job.description.count >= 120 ? .high : .medium

        return JobAssessment(
            score: boundedScore,
            recommendation: qualifies ? (boundedScore >= 75 ? "推荐" : "可尝试") : "不建议",
            confidence: confidence,
            reasons: reasons,
            risks: risks,
            greeting: qualifies ? personalizedGreeting(job: job, preferences: preferences) : "",
            assessedAt: Date(),
            provider: "本地规则"
        )
    }

    static func hardGateFailures(job: JobListing, preferences: JobPreferences) -> [String] {
        let evidence = normalized(job.evidenceText)
        var failures: [String] = []
        if !job.hasAuthoritativeDescription {
            failures.append("尚未取得 BOSS 权威职位描述")
        }
        let excluded = matchingExclusions(in: job.evidenceText, preferences: preferences)
        if !excluded.isEmpty {
            failures.append("命中排除项：\(excluded.joined(separator: "、"))")
        }
        let missingRequired = JobSearchPlanningPolicy.explicitRequiredTerms(in: preferences.requirementText)
            .filter { !containsTerm($0, in: evidence) }
        if !missingRequired.isEmpty {
            failures.append("缺少必需关键词：\(missingRequired.joined(separator: "、"))")
        }
        if let desiredSalary = salaryRange(from: preferences.requirementText) {
            guard let candidateSalary = salaryRange(from: job.salary) else {
                failures.append("岗位薪资不是可核验的月薪区间：\(job.salary.isEmpty ? "未标注" : job.salary)")
                return failures
            }
            if !salaryRangesOverlap(candidate: candidateSalary, desired: desiredSalary) {
                failures.append("薪资区间与期望无重合")
            }
        }
        let allowedCities = JobSearchPlanningPolicy.cities(in: preferences.requirementText)
        if !allowedCities.isEmpty,
           hasStrictLocationConstraint(preferences.requirementText),
           !allowedCities.contains(where: { containsTerm($0, in: normalized(job.displayLocation)) }) {
            failures.append("工作地点不在严格限定的城市范围")
        }
        return failures
    }

    /// 只使用列表中已有的明确证据；未知薪资、地点和缺失关键词仍需读取详情。
    static func hasDefinitiveListMismatch(job: JobListing, preferences: JobPreferences) -> Bool {
        if !matchingExclusions(in: job.evidenceText, preferences: preferences).isEmpty { return true }
        if let desiredSalary = salaryRange(from: preferences.requirementText),
           let candidateSalary = salaryRange(from: job.salary),
           !salaryRangesOverlap(candidate: candidateSalary, desired: desiredSalary) {
            return true
        }
        let allowedCities = JobSearchPlanningPolicy.cities(in: preferences.requirementText)
        let allowedCodes = allowedCities.compactMap { BossCityResolver.code(for: $0) }
        if hasStrictLocationConstraint(preferences.requirementText),
           !allowedCodes.isEmpty, allowedCodes.count == allowedCities.count,
           let candidateCode = BossCityResolver.code(for: job.displayLocation),
           BossCityResolver.name(forCode: candidateCode) != nil,
           candidateCode != BossCityResolver.code(for: "全国"),
           !allowedCodes.contains(candidateCode) {
            return true
        }
        return false
    }

    static func matchingExclusions(in text: String, preferences: JobPreferences) -> [String] {
        let evidence = normalized(text)
        // 忽略“不是27校招岗”等明确否定校招的表述。
        let recruitmentEvidence = evidence.replacingOccurrences(
            of: #"(?:非|不是|不招|不接受|不考虑)\s*(?:(?:20)?[0-9]{2}\s*届?\s*)?(?:校招|校园招聘|应届(?:毕业生|生)?|毕业生|在校生|实习(?:生)?)(?:岗位|岗)?"#,
            with: "", options: .regularExpression
        )
        return JobSearchPlanningPolicy.explicitExcludedTerms(in: preferences.requirementText)
            .filter { term in
                if let pattern = recruitmentPattern(for: term) {
                    return recruitmentEvidence.range(of: pattern, options: .regularExpression) != nil
                }
                return containsTerm(term, in: evidence)
            }
    }

    static func requiresRecruitmentEvidence(preferences: JobPreferences) -> Bool {
        JobSearchPlanningPolicy.explicitExcludedTerms(in: preferences.requirementText)
            .contains { recruitmentPattern(for: $0) != nil }
    }

    private static func recruitmentPattern(for term: String) -> String? {
        switch normalized(term) {
        case "校招", "校园招聘", "应届", "应届生", "应届毕业生", "毕业生", "在校生":
            #"校招|校园招聘|应届|毕业生|在校生|(?<![0-9])(?:20)?[0-9]{2}\s*届|(?<![a-z])(?:campus|new[\s-]+grad(?:uate)?s?)(?![a-z])"#
        case "实习", "实习生", "intern", "internship":
            #"实习|(?<![a-z])intern(?:ship)?s?(?![a-z])"#
        default:
            nil
        }
    }

    static func salaryRange(from text: String) -> SalaryRange? {
        let normalized = text
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .uppercased()
        let lowerBoundPatterns: [(String, Double)] = [
            (#"(\d{1,3}(?:\.\d+)?)\s*K\s*(?:以上|起|不低于|至少)"#, 1),
            (#"(\d{1,2}(?:\.\d+)?)\s*万\s*(?:以上|起|不低于|至少)"#, 10),
            (#"(?:以上|起|不低于|至少)\s*(\d{1,3}(?:\.\d+)?)\s*K"#, 1)
        ]
        for (pattern, multiplier) in lowerBoundPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized)
                  ),
                  let range = Range(match.range(at: 1), in: normalized),
                  let value = Double(normalized[range]) else { continue }
            let lowerBound = Int(floor(value * multiplier))
            return SalaryRange(minimumK: lowerBound, maximumK: lowerBound)
        }
        let patterns: [(String, Double)] = [
            (#"(\d{1,3}(?:\.\d+)?)\s*K?\s*[-~至到]\s*(\d{1,3}(?:\.\d+)?)\s*K"#, 1),
            (#"(\d{1,2}(?:\.\d+)?)\s*[-~至到]\s*(\d{1,2}(?:\.\d+)?)\s*万"#, 10),
            (#"(\d{4,6})\s*[-~至到]\s*(\d{4,6})\s*(?:元)?"#, 0.001)
        ]

        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized)
                  ),
                  let firstRange = Range(match.range(at: 1), in: normalized),
                  let secondRange = Range(match.range(at: 2), in: normalized),
                  let first = Double(normalized[firstRange]),
                  let second = Double(normalized[secondRange]) else { continue }
            let left = Int(floor(min(first, second) * multiplier))
            let right = Int(ceil(max(first, second) * multiplier))
            return SalaryRange(minimumK: left, maximumK: right)
        }
        return nil
    }

    private static func salaryCoverage(candidate: SalaryRange, desired: SalaryRange) -> Double {
        let desiredMinimum = desired.minimumK
        let desiredMaximum = desired.maximumK
        guard desiredMaximum >= desiredMinimum else { return 0 }
        let overlapStart = max(candidate.minimumK, desiredMinimum)
        let overlapEnd = min(candidate.maximumK, desiredMaximum)
        guard overlapEnd >= overlapStart else { return 0 }
        let desiredWidth = max(1, desiredMaximum - desiredMinimum + 1)
        return Double(overlapEnd - overlapStart + 1) / Double(desiredWidth)
    }

    private static func salaryRangesOverlap(candidate: SalaryRange, desired: SalaryRange) -> Bool {
        candidate.maximumK >= desired.minimumK && candidate.minimumK <= desired.maximumK
    }

    private static func personalizedGreeting(job: JobListing, preferences: JobPreferences) -> String {
        preferences.greetingTemplate
            .replacingOccurrences(of: "{岗位}", with: job.title)
            .replacingOccurrences(of: "{公司}", with: job.company)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func containsTerm(_ term: String, in normalizedText: String) -> Bool {
        let needle = normalized(term).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let aliases: [String: [String]] = [
            "校招": ["校园招聘", "应届", "毕业生", "campus", "new graduate"],
            "实习": ["internship", "intern"],
            "外包": ["外派", "驻场", "outsourcing"],
            "0-20人": ["0–20人", "0~20人", "少于20人"]
        ]
        if aliases[needle]?.contains(where: { normalizedText.contains($0) }) == true { return true }
        if needle.count <= 3,
           needle.unicodeScalars.allSatisfy({ $0.isASCII }),
           needle.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
           let regex = try? NSRegularExpression(
               pattern: "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: needle))(?![A-Za-z0-9])",
               options: [.caseInsensitive]
           ) {
            return regex.firstMatch(
                in: normalizedText,
                range: NSRange(normalizedText.startIndex..., in: normalizedText)
            ) != nil
        }
        return normalizedText.contains(needle)
    }

    /// 按岗位方向匹配，将“研发”和“开发”归一化；核心词至少两个字符，避免“工程师”等泛词误匹配。
    private static func roleTerm(_ term: String, matchesTitle title: String) -> Bool {
        let compactTerm = compactRoleText(term)
        let compactTitle = compactRoleText(title)
        guard !compactTerm.isEmpty, !compactTitle.isEmpty else { return false }
        if compactTitle.contains(compactTerm) { return true }

        let genericRoleWords = ["高级", "资深", "专家", "工程师", "研发", "开发", "岗位"]
        let core = genericRoleWords.reduce(compactTerm) { partial, word in
            partial.replacingOccurrences(of: word, with: "")
        }
        guard core.count >= 2 else { return false }
        return compactTitle.contains(core)
    }

    private static func compactRoleText(_ value: String) -> String {
        let folded = normalized(value).lowercased()
        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) ||
                CharacterSet(charactersIn: "\u{4E00}-\u{9FFF}").contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func hasStrictLocationConstraint(_ text: String) -> Bool {
        let compact = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "的", with: "")
        return compact.contains("其他城市不考虑") ||
            compact.contains("其他地域不考虑") ||
            compact.contains("地域严格排除") ||
            compact.contains("地点严格排除")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(trimmed)
            guard !trimmed.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}
