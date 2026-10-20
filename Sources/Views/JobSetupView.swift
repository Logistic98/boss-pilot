import SwiftUI
import UniformTypeIdentifiers

struct JobSetupView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var codex: CodexController
    @State private var showingFileImporter = false
    @State private var isImportingResume = false
    @State private var isDropTargeted = false
    @FocusState private var requirementsFocused: Bool

    let attachmentStorageDirectory: URL?

    private var resume: ResumeProfile { store.snapshot.resume }
    private var preferences: JobPreferences { store.snapshot.preferences }
    private var requirementDraft: String { store.requirementsDraft?.requirementText ?? preferences.requirementText }
    private var greetingDraft: String { store.requirementsDraft?.greetingTemplate ?? preferences.greetingTemplate }

    var body: some View {
        VStack(spacing: 0) {
            WorkspacePageHeader(
                title: "求职偏好",
                subtitle: store.hasUnsavedRequirementsChanges ? "未保存" : "已保存",
                systemImage: "wand.and.stars"
            ) {
                Button("保存") {
                    Task { await store.saveRequirementsChanges() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.isSavingRequirements)
            }
            Divider()

            GeometryReader { geometry in
                let layout = JobSetupLayout(viewport: geometry.size)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        readinessBar
                        editorColumns(layout: layout)
                    }
                    .frame(width: layout.contentWidth)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("")
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf, .plainText],
            allowsMultipleSelection: false,
            onCompletion: importSelection
        )
        .onAppear { store.beginRequirementsEditing() }
        .task(id: automaticPreparationID) {
            guard resume.hasStoredAttachment, !requirementsFocused, !store.hasUnsavedRequirementsChanges else { return }
            if !resume.hasGeneratedProfile {
                await codex.analyzeResume(using: store)
            } else if preferences.hasSearchCriteria, preferences.plannedSearchQueries.isEmpty {
                await codex.planSearch(using: store)
            }
        }
        .onChange(of: requirementsFocused) { _, focused in
            store.isEditingRequirements = focused || store.hasUnsavedRequirementsChanges
        }
        .onChange(of: store.requirementsDraft) { _, _ in
            store.isEditingRequirements = requirementsFocused || store.hasUnsavedRequirementsChanges
        }
        .onChange(of: store.hasUnsavedRequirementsChanges) { _, _ in
            store.isEditingRequirements = requirementsFocused || store.hasUnsavedRequirementsChanges
        }
        .onDisappear { store.finishRequirementsEditing() }
    }

    private var readinessBar: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
            alignment: .leading,
            spacing: 10
        ) {
            ReadinessItem(
                title: "简历",
                detail: resume.hasStoredAttachment ? "已保存" : "待添加",
                complete: resume.hasStoredAttachment
            )
            ReadinessItem(
                title: "候选人画像",
                detail: codex.isProfilingResume ? "生成中" : (resume.hasGeneratedProfile ? "已生成" : "待生成"),
                complete: resume.hasGeneratedProfile,
                working: codex.isProfilingResume
            )
            ReadinessItem(
                title: "求职要求",
                detail: store.hasUnsavedRequirementsChanges ? "未保存" : (preferences.hasSearchCriteria ? "已保存" : "待填写"),
                complete: preferences.hasSearchCriteria
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func editorColumns(layout: JobSetupLayout) -> some View {
        if let profileWidth = layout.profileColumnWidth {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    resumeCard
                    profileCard
                }
                .frame(width: profileWidth)

                VStack(spacing: 18) {
                    requirementCard(height: layout.requirementEditorHeight)
                    greetingCard(height: layout.greetingEditorHeight)
                }
                .frame(maxWidth: .infinity)
            }

        } else {
            VStack(spacing: 18) {
                resumeCard
                requirementCard(height: layout.requirementEditorHeight)
                greetingCard(height: layout.greetingEditorHeight)
                profileCard
            }
        }
    }

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "简历附件")

            HStack(spacing: 12) {
                Image(systemName: resume.hasStoredAttachment ? "doc.text.fill" : "doc.badge.plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(resume.hasStoredAttachment ? .green : BossPilotTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(resume.sourceFileName ?? "拖入或选择简历")
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(resume.sourceFileName ?? "拖入或选择简历")
                    Text(attachmentDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(isImportingResume ? "导入中" : (resume.hasStoredAttachment ? "更换" : "选择")) {
                    showingFileImporter = true
                }
                .disabled(isImportingResume)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help("选择 PDF、TXT 或 Markdown 简历")
            }
            .padding(12)
            .background(BossPilotTheme.accent.opacity(isDropTargeted ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isDropTargeted ? BossPilotTheme.accent : Color.secondary.opacity(0.12))
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard !isImportingResume, let url = urls.first else { return false }
                importURL(url)
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
        .panelStyle()
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(BossPilotTheme.accent)
                Text("候选人画像")
                    .font(.title3.bold())
                Spacer()
                if resume.hasStoredAttachment, !codex.isProfilingResume {
                    Button(resume.hasGeneratedProfile ? "更新画像" : "生成画像") {
                        Task { await codex.analyzeResume(using: store) }
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                }
            }

            if codex.isProfilingResume {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: codex.resumeAnalysisStartedAt ?? .now, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(codex.resumeAnalysisStartedAt ?? context.date)))
                        Text("生成中 · \(elapsed) 秒")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消") { codex.cancelResumeAnalysis() }
                        .buttonStyle(.borderless)
                }
                .accessibilityElement(children: .contain)
            }

            if let error = codex.resumeAnalysisError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if resume.hasGeneratedProfile {
                if resume.yearsOfExperience > 0 {
                    StatusPill(title: "\(resume.yearsOfExperience) 年经验", systemImage: "briefcase", color: BossPilotTheme.accent)
                }
                Text(resume.profileSummary)
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !codex.isProfilingResume {
                ContentUnavailableView {
                    Label("导入简历后自动生成", systemImage: "person.text.rectangle")
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
        }
        .panelStyle()
    }

    private func requirementCard(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "求职要求", detail: "\(requirementDraft.count) 字")

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { requirementDraft }, set: { store.requirementsDraft?.requirementText = $0 }))
                    .focused($requirementsFocused)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(height: height)
                    .accessibilityLabel("求职要求")
                    .help("用自然语言说明岗位、城市、薪资、必选项和排除项")

                if requirementDraft.isEmpty {
                    Text("例如：上海或杭州 Java 后端，35K 以上，要求微服务经验，不考虑外包。")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .lineSpacing(4)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

        }
        .panelStyle()
    }

    private func greetingCard(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "沟通草稿", detail: "\(greetingDraft.count) 字")
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { greetingDraft }, set: { store.requirementsDraft?.greetingTemplate = $0 }))
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(height: height)
                    .accessibilityLabel("本地沟通草稿")
                    .help("仅供参考，支持 {岗位}、{公司}，不会自动发送")
                if greetingDraft.isEmpty {
                    Text("填写沟通草稿")
                        .foregroundStyle(.tertiary)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        }
        .panelStyle()
    }

    private var automaticPreparationID: String {
        [
            resume.id.uuidString,
            String(resume.hasStoredAttachment),
            String(resume.hasGeneratedProfile),
            resume.hasGeneratedProfile ? preferences.requirementText : "",
            String(requirementsFocused),
            String(store.hasUnsavedRequirementsChanges)
        ].joined(separator: "|")
    }

    private var attachmentDetail: String {
        guard resume.hasStoredAttachment else { return "PDF / TXT / Markdown" }
        let size = resume.attachmentSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let date = resume.importedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return [size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func importSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            importURL(url)
        } catch {
            store.report(error)
        }
    }

    private func importURL(_ url: URL) {
        guard !isImportingResume else { return }
        isImportingResume = true
        Task {
            defer { isImportingResume = false }
            do {
                let result = try await ResumeImportService.shared.importFile(from: url, storageDirectory: attachmentStorageDirectory)
                store.importResume(result)
            } catch {
                store.report(error)
            }
        }
    }
}

struct JobSetupLayout {
    let viewport: CGSize

    var contentWidth: CGFloat { min(1_480, max(0, viewport.width - 48)) }
    var profileColumnWidth: CGFloat? {
        contentWidth >= 900 ? min(520, contentWidth * 0.4) : nil
    }
    var requirementEditorHeight: CGFloat { min(480, max(280, viewport.height * 0.47)) }
    var greetingEditorHeight: CGFloat { min(180, max(120, viewport.height * 0.18)) }
}

private struct ReadinessItem: View {
    let title: String
    let detail: String
    let complete: Bool
    var working = false

    var body: some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(complete ? .green : .secondary)
            }
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
