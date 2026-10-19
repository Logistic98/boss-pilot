import Foundation

enum JobSearchPlanningPolicy {
    static func fallbackResumeIntelligence(resume: ResumeProfile) -> ResumeIntelligence {
        let skills = unique(resume.skills).prefix(12)
        var summaryParts: [String] = []
        if resume.yearsOfExperience > 0 {
            summaryParts.append("拥有约 \(resume.yearsOfExperience) 年相关工作经验")
        }
        if !skills.isEmpty {
            summaryParts.append("技术与能力重点包括 \(skills.joined(separator: "、"))")
        }
        let excerpt = resume.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !excerpt.isEmpty {
            summaryParts.append("简历重点：\(String(excerpt.prefix(260)))")
        }
        let queries = inferredRoleQueries(text: resume.text, skills: Array(skills))
        return ResumeIntelligence(
            profileSummary: summaryParts.joined(separator: "。") + "。",
            searchQueries: queries,
            cities: [],
            provider: "本地提取"
        )
    }

    static func fallbackSearchPlan(resume: ResumeProfile, requirementText: String) -> JobSearchPlan {
        let requirementQueries = roleQueries(in: requirementText)
        let queries = unique(requirementQueries + resume.suggestedSearchQueries + inferredRoleQueries(
            text: resume.text,
            skills: resume.skills
        ))
        let cities = cities(in: requirementText)
        return JobSearchPlan(
            queries: Array(queries.prefix(4)),
            cities: cities.isEmpty ? ["全国"] : Array(cities.prefix(4)),
            provider: "本地解析"
        )
    }

    static func normalizedSearchPlan(
        queries: [String],
        requirementText: String,
        provider: String,
        fallbackQueries: [String] = []
    ) -> JobSearchPlan {
        let sanitizedQueries = unique(queries + fallbackQueries)
            .map(BossSearchRequestPolicy.normalizedQuery)
            .filter { !$0.isEmpty }
        let extractedCities = cities(in: requirementText)
        return JobSearchPlan(
            queries: Array(sanitizedQueries.prefix(4)),
            cities: extractedCities.isEmpty ? ["全国"] : Array(extractedCities.prefix(4)),
            provider: provider
        )
    }

    static func cities(in text: String) -> [String] {
        supportedCities.compactMap { city -> (city: String, offset: Int)? in
            guard let range = text.range(of: city, options: [.caseInsensitive, .widthInsensitive]) else {
                return nil
            }
            return (city, text.distance(from: text.startIndex, to: range.lowerBound))
        }
        .sorted {
            if $0.offset == $1.offset { return $0.city < $1.city }
            return $0.offset < $1.offset
        }
        .map(\.city)
    }

    static func explicitExcludedTerms(in text: String) -> [String] {
        let markers = "不考虑|不接受|不投递|不投|不要|不考|排除|屏蔽|拒绝"
        guard let regex = try? NSRegularExpression(pattern: markers) else { return [] }
        var terms: [String] = []
        for clause in text.components(separatedBy: CharacterSet(charactersIn: "\n。；;")) {
            let matches = regex.matches(in: clause, range: NSRange(clause.startIndex..., in: clause))
            for (index, match) in matches.enumerated() {
                guard let marker = Range(match.range, in: clause) else { continue }
                let end = index + 1 < matches.count
                    ? Range(matches[index + 1].range, in: clause)!.lowerBound : clause.endIndex
                let tail = String(clause[marker.upperBound..<end])
                terms.append(contentsOf: tail.components(separatedBy: CharacterSet(charactersIn: "、,，/")))
                // 处理“模型训练的不考虑”等后置否定，保留前一条正向要求。
                let head = clause[..<marker.lowerBound].components(separatedBy: CharacterSet(charactersIn: "，,:：")).last ?? ""
                if (tail.components(separatedBy: CharacterSet(charactersIn: "，,")).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    terms.append(contentsOf: head.components(separatedBy: "、"))
                }
            }
        }
        return unique(terms.map { value in
            var term = cleanedConstraintTerm(value)
            for suffix in ["类岗位", "岗位", "的公司", "公司", "企业", "类"] where term.hasSuffix(suffix) {
                term.removeLast(suffix.count)
            }
            return cleanedConstraintTerm(term)
        }).filter { !$0.contains("严格") && $0.count >= 2 && $0.count <= 30 }

    }

    static func explicitRequiredTerms(in text: String) -> [String] {
        clauseTerms(in: text, markers: ["必须", "硬性要求", "只考虑"])
    }

    static func explicitPreferredTerms(in text: String) -> [String] {
        clauseTerms(in: text, markers: ["优先", "更看重", "期望", "加分"])
    }

    private static func inferredRoleQueries(text: String, skills: [String]) -> [String] {
        var queries = roleQueries(in: text)
        let normalizedSkills = skills.map { $0.lowercased() }
        let mappings: [([String], String)] = [
            (["java", "spring", "spring boot"], "Java 开发工程师"),
            (["python", "django", "flask", "fastapi"], "Python 开发工程师"),
            (["golang", "go"], "Go 开发工程师"),
            (["swift", "swiftui", "objective-c"], "iOS 开发工程师"),
            (["kubernetes", "k8s", "devops"], "云原生工程师"),
            (["算法", "pytorch", "tensorflow", "llm"], "算法工程师"),
            (["vue", "react", "typescript"], "前端开发工程师")
        ]
        for (needles, role) in mappings where needles.contains(where: { needle in
            normalizedSkills.contains(where: { $0 == needle || $0.contains(needle) })
        }) {
            queries.append(role)
        }
        if queries.isEmpty, let firstSkill = skills.first {
            queries.append(firstSkill)
        }
        return Array(unique(queries).prefix(4))
    }

    private static func roleQueries(in text: String) -> [String] {
        let patterns = [
            #"[A-Za-z0-9+#.\- ]{1,24}(?:开发|研发|后端|前端|客户端|测试|运维|算法|数据|安全|云原生)?工程师"#,
            #"[\p{Han}A-Za-z0-9+#.\- ]{1,18}架构师"#,
            #"[\p{Han}A-Za-z0-9+#.\- ]{1,18}(?:产品经理|项目经理|技术负责人)"#
        ]
        var values: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let valueRange = Range(match.range, in: text) else { continue }
                let value = text[valueRange]
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                if value.count >= 2 { values.append(String(value.suffix(40))) }
            }
        }
        return unique(values)
    }

    private static func clauseTerms(
        in text: String,
        markers: [String],
        includeTermsBeforeMarker: Bool = false
    ) -> [String] {
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "\n。；;"))
        let allMarkers = ["不考虑", "不接受", "硬性要求", "只考虑", "必须", "排除", "屏蔽", "拒绝", "不要", "不考", "优先", "更看重", "期望", "加分"]
        var output: [String] = []
        for clause in clauses {
            guard let marker = markers.first(where: { clause.contains($0) }),
                  let range = clause.range(of: marker) else { continue }
            var tail = String(clause[range.upperBound...])
            if let nextMarkerRange = allMarkers
                .filter({ $0 != marker })
                .compactMap({ tail.range(of: $0) })
                .min(by: { $0.lowerBound < $1.lowerBound }) {
                tail = String(tail[..<nextMarkerRange.lowerBound])
                // 后续分句可否定前面的泛指对象，如“只考虑上海，其他城市的不考虑”。
                if !includeTermsBeforeMarker,
                   let comma = tail.lastIndex(where: { "，,".contains($0) }) {
                    tail = String(tail[..<comma])
                }
            }
            tail = tail
                .replacingOccurrences(of: "岗位", with: "")
                .replacingOccurrences(of: "公司", with: "")
            output.append(contentsOf: tail.components(separatedBy: CharacterSet(charactersIn: "、,，/或和及与")))

            if includeTermsBeforeMarker {
                var head = String(clause[..<range.lowerBound])
                if let delimiter = head.lastIndex(where: { "，,: ：".contains($0) }) {
                    head = String(head[head.index(after: delimiter)...])
                }
                output.append(contentsOf: head.components(separatedBy: CharacterSet(charactersIn: "、,，/或和及与")))
            }
        }
        return unique(output.map(cleanedConstraintTerm)).filter { $0.count >= 2 && $0.count <= 30 }
    }

    private static func cleanedConstraintTerm(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let leadingWords = ["若是", "如果是", "要有", "具备", "有", "使用", "包含", "需要"]
        if let prefix = leadingWords.first(where: { cleaned.hasPrefix($0) }) {
            cleaned.removeFirst(prefix.count)
        }
        let trailingWords = ["实战经验", "相关经验", "经验", "实战", "能力", "的"]
        if let suffix = trailingWords.first(where: { cleaned.hasSuffix($0) }) {
            cleaned.removeLast(suffix.count)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func unique<S: Sequence>(_ values: S) -> [String] where S.Element == String {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            guard !trimmed.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private static let supportedCities = [
        "北京", "上海", "广州", "深圳", "杭州", "成都", "南京", "武汉", "西安", "苏州",
        "长沙", "天津", "重庆", "郑州", "东莞", "佛山", "合肥", "青岛", "宁波", "大连", "厦门", "济南"
    ]
}
