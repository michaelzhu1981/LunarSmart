import SwiftUI
import EventKit
import Combine

private enum DesignTokens {
    enum Spacing {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 20
        static let lg: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 18
        static let field: CGFloat = 10
    }

    enum Colors {
        #if os(macOS)
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.9)
        static let fieldBackground = Color(nsColor: .textBackgroundColor).opacity(0.65)
        #else
        static let windowBackground = Color(.systemGroupedBackground)
        static let cardBackground = Color(.secondarySystemGroupedBackground).opacity(0.9)
        static let fieldBackground = Color(.tertiarySystemFill).opacity(0.55)
        #endif

        static let brandBlue = Color(red: 0.18, green: 0.52, blue: 0.98)
        static let neutralGray = Color.gray
        static let dangerRed = Color.red
        static let successGreen = Color.green
    }
}

struct ContentView: View {
    private static let appleCalendarReminderOffsets: [Int] = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080]
    private static let appleCalendarAllDayReminderOffsets: [Int] = [900, 0, -540, 2340, 10080]

    @StateObject private var ruleStore = RuleStore()

    @State private var title = ""
    @State private var notes = ""
    @State private var location = ""
    @State private var targetType: TargetType = .event
    @State private var repeatMode: LunarRepeatMode = .none
    @State private var missingDayStrategy: MissingDayStrategy = .skip
    @State private var repeatEndMode: RepeatEndMode = .afterOccurrences
    @State private var repeatEndCount = 1
    @State private var repeatEndDate = Date()

    @State private var gregorianYear = Calendar.current.component(.year, from: Date())
    @State private var lunarMonth = 1
    @State private var lunarDay = 1
    @State private var isLeapMonth = false
    @State private var includeLeapMonthsForMonthlyRepeat = false

    @State private var isAllDay = true
    @State private var time = Date()
    @State private var eventDurationMinutes = 60
    @State private var reminderOffsetMinutes = 900

    @State private var ruleId = UUID().uuidString
    @State private var activeRuleId: String?
    @State private var resultMessage = ""
    @State private var previewDates: [Date] = []
    private let previewDisplayLimit = 20
    @State private var isSaving = false

    private let scheduler = LunarScheduler()
    private let adapter = EventKitAdapter()
    @FocusState private var focusedField: FocusField?

    var body: some View {
        NavigationStack {
            ZStack {
                appleBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        overviewSection
                        basicSection
                        settingsCardsSection
                        previewSection
                        savedRulesSection
                        saveActionSection
                        resultSection
                    }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.lg)
                    .frame(maxWidth: 1024)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }
            .navigationTitle("LunarSmart 农历日程")
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshPreview()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button {
                        refreshPreview()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                #endif
            }
            .onAppear {
                enforceLeapSelectionConsistency()
                enforceRepeatEndConsistency()
                refreshPreview()
            }
            .onChange(of: gregorianYear) { _, _ in
                enforceRepeatEndConsistency()
                refreshPreview()
            }
            .onChange(of: lunarMonth) { _, _ in refreshPreview() }
            .onChange(of: lunarDay) { _, _ in refreshPreview() }
            .onChange(of: isLeapMonth) { _, _ in refreshPreview() }
            .onChange(of: repeatMode) { _, _ in
                enforceLeapSelectionConsistency()
                enforceRepeatEndConsistency()
                refreshPreview()
            }
            .onChange(of: includeLeapMonthsForMonthlyRepeat) { _, _ in
                enforceLeapSelectionConsistency()
                refreshPreview()
            }
            .onChange(of: missingDayStrategy) { _, _ in refreshPreview() }
            .onChange(of: repeatEndMode) { _, _ in refreshPreview() }
            .onChange(of: repeatEndCount) { _, newValue in
                if newValue < 1 {
                    repeatEndCount = 1
                    return
                }
                refreshPreview()
            }
            .onChange(of: repeatEndDate) { _, _ in refreshPreview() }
            .onChange(of: isAllDay) { _, newValue in
                if newValue {
                    if !Self.appleCalendarAllDayReminderOffsets.contains(reminderOffsetMinutes) {
                        reminderOffsetMinutes = 900
                    }
                } else if !Self.appleCalendarReminderOffsets.contains(reminderOffsetMinutes) {
                    reminderOffsetMinutes = 0
                }
            }
        }
    }

    private var appleBackground: some View {
        ZStack {
            DesignTokens.Colors.windowBackground
            LinearGradient(
                colors: [
                    DesignTokens.Colors.brandBlue.opacity(0.22),
                    .mint.opacity(0.13),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(0.2), .clear],
                center: .topTrailing,
                startRadius: 60,
                endRadius: 520
            )
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            sectionTitle("概览")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    overviewChip(
                        title: "规则类型",
                        value: activeRuleId == nil ? "新建规则" : "编辑已有规则",
                        systemImage: "square.and.pencil",
                        tint: DesignTokens.Colors.brandBlue
                    )
                    overviewChip(
                        title: "目标",
                        value: targetType.label,
                        systemImage: "target",
                        tint: .teal
                    )
                    overviewChip(
                        title: "重复方式",
                        value: repeatMode.label,
                        systemImage: "repeat",
                        tint: .orange
                    )
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
        }
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            sectionTitle("基础信息")
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                TextField("标题（必填）", text: $title)
                    .focused($focusedField, equals: .title)
                    .lunarAutocapSentences()
                    .lunarTextFieldStyle()

                Label("请先填写标题，才能保存规则。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 18, alignment: .topLeading)
                    .opacity(trimmedTitle.isEmpty ? 1 : 0)
                    .accessibilityHidden(!trimmedTitle.isEmpty)

                TextField("备注", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .notes)
                    .lunarTextFieldStyle()

                if targetType == .event {
                    TextField("地点（可选）", text: $location)
                        .focused($focusedField, equals: .location)
                        .lunarAutocapWords()
                        .lunarTextFieldStyle()
                }

                Picker("创建类型", selection: $targetType) {
                    ForEach(TargetType.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }
            .lunarCard()
        }
    }

    private var settingsCardsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            sectionTitle("设置")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    lunarSettingsCard
                    timeSettingsCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: DesignTokens.Spacing.sm) {
                    lunarSettingsCard
                    timeSettingsCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lunarSettingsCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("农历规则")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("重复", selection: $repeatMode) {
                ForEach(LunarRepeatMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Picker("起始年份", selection: $gregorianYear) {
                    ForEach(yearOptions, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("农历月", selection: $lunarMonth) {
                    ForEach(1...12, id: \.self) { month in
                        Text("第\(month)月").tag(month)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("农历日", selection: $lunarDay) {
                    ForEach(1...30, id: \.self) { day in
                        Text("第\(day)日").tag(day)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if repeatMode == .monthly || repeatMode == .yearly {
                HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                    Picker("结束重复", selection: $repeatEndMode) {
                        ForEach(RepeatEndMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if repeatEndMode == .afterOccurrences {
                        HStack(spacing: 6) {
                            TextField("次数", value: $repeatEndCount, format: .number)
                                .frame(width: 90)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(DesignTokens.Colors.brandBlue.opacity(0.14))
                                )
                            Text("次以后")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        DatePicker(
                            "结束日期",
                            selection: $repeatEndDate,
                            in: startDateForSelectedYear...,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Picker("当月无该日时", selection: $missingDayStrategy) {
                ForEach(MissingDayStrategy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if repeatMode == .monthly || repeatMode == .yearly {
                Toggle("按农历月/年重复时包含闰月", isOn: $includeLeapMonthsForMonthlyRepeat)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .lunarCard()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var timeSettingsCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("时间设置")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("全天", isOn: $isAllDay)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isAllDay {
                DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("提醒", selection: reminderOffsetSelection) {
                if isAllDay {
                    ForEach(Self.appleCalendarAllDayReminderOffsets, id: \.self) { offset in
                        Text(allDayReminderLabel(for: offset)).tag(offset)
                    }
                } else {
                    Text("不提醒").tag(0)
                    ForEach(Self.appleCalendarReminderOffsets.filter { $0 != 0 }, id: \.self) { offset in
                        Text(reminderLabel(for: offset)).tag(offset)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isAllDay {
                if targetType == .event {
                    Stepper("时长 \(eventDurationMinutes) 分钟", value: $eventDurationMinutes, in: 5...1440, step: 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LabeledContent("时长") {
                        Text("仅日程可设置")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .lunarCard()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var reminderOffsetSelection: Binding<Int> {
        Binding(
            get: {
                if isAllDay {
                    return Self.appleCalendarAllDayReminderOffsets.contains(reminderOffsetMinutes) ? reminderOffsetMinutes : 900
                }
                return Self.appleCalendarReminderOffsets.contains(reminderOffsetMinutes) ? reminderOffsetMinutes : 0
            },
            set: { reminderOffsetMinutes = $0 }
        )
    }

    @ViewBuilder
    private var savedRulesSection: some View {
        if !ruleStore.rules.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                sectionTitle("已保存规则")
                savedRulesTable
            }
        }
    }

    private var savedRulesTable: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                savedRulesHeader
                Divider()
                ForEach(Array(ruleStore.rules.enumerated()), id: \.element.id) { index, rule in
                    savedRuleRow(rule, isStriped: index.isMultiple(of: 2))
                    if index < ruleStore.rules.count - 1 {
                        Divider().opacity(0.35)
                    }
                }
            }
            .frame(minWidth: savedRulesTableMinWidth, alignment: .leading)
            .background(lunarCardShape.fill(DesignTokens.Colors.cardBackground))
            .overlay(
                lunarCardShape
                    .stroke(DesignTokens.Colors.neutralGray.opacity(0.18), lineWidth: 1)
            )
            .clipShape(lunarCardShape)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private var savedRulesHeader: some View {
        HStack(spacing: 10) {
            tableHeaderCell("标题", width: 140, alignment: .leading)
            tableHeaderCell("类型", width: 70, alignment: .leading)
            tableHeaderCell("重复", width: 80, alignment: .leading)
            tableHeaderCell("农历规则", width: 100, alignment: .leading)
            tableHeaderCell("关联条目", width: 80, alignment: .trailing)
            tableHeaderCell("更新时间", width: 110, alignment: .leading)
            tableHeaderCell("操作", width: 110, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.neutralGray.opacity(0.1))
    }

    private var savedRulesTableMinWidth: CGFloat {
        let columnWidths: CGFloat = 140 + 70 + 80 + 100 + 80 + 110 + 110
        let columnSpacings: CGFloat = 10 * 6
        let horizontalPadding: CGFloat = 24
        return columnWidths + columnSpacings + horizontalPadding
    }

    private func savedRuleRow(_ rule: StoredRule, isStriped: Bool) -> some View {
        HStack(spacing: 10) {
            tableDataCell(rule.title, width: 140, alignment: .leading, emphasized: true)
            tableDataCell(rule.type.label, width: 70, alignment: .leading)
            tableDataCell(rule.repeatMode.label, width: 80, alignment: .leading)
            tableDataCell(rule.spec.displayText, width: 100, alignment: .leading)
            tableDataCell("\(rule.occurrences.count)", width: 80, alignment: .trailing, monospacedDigits: true)
            tableDataCell(formattedUpdatedAt(rule.updatedAt), width: 110, alignment: .leading, monospacedDigits: true)

            HStack(spacing: 8) {
                Button("载入") {
                    load(rule)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("删除") {
                    Task {
                        await deleteRule(rule)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DesignTokens.Colors.dangerRed)
            }
            .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            activeRuleId == rule.id
            ? DesignTokens.Colors.brandBlue.opacity(0.15)
            : (isStriped ? DesignTokens.Colors.neutralGray.opacity(0.05) : Color.clear)
        )
    }

    private func tableHeaderCell(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    @ViewBuilder
    private func tableDataCell(
        _ text: String,
        width: CGFloat,
        alignment: Alignment,
        emphasized: Bool = false,
        monospacedDigits: Bool = false
    ) -> some View {
        if monospacedDigits {
            Text(text)
                .font(emphasized ? .body.weight(.semibold) : .caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .monospacedDigit()
                .frame(width: width, alignment: alignment)
        } else {
            Text(text)
                .font(emphasized ? .body.weight(.semibold) : .caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .frame(width: width, alignment: alignment)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            sectionTitle("预览")
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.md) {
                    previewMetaItem(title: "规则", value: repeatMode.label)
                    previewMetaItem(title: "目标", value: targetType.label)
                    previewMetaItem(title: "结果", value: "\(previewDates.count) 条")
                }
                .font(.caption)

                if let leapMonthSummary = previewLeapMonthSummary {
                    Text("预览检测到闰月：\(leapMonthSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    if previewDates.isEmpty {
                        ContentUnavailableView(
                            "暂无预览结果",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("点击“刷新预览”查看将要创建的日期。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .foregroundStyle(.secondary)
                    } else {
                        let visiblePreviewDates = Array(previewDates.prefix(previewDisplayLimit))
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 220), spacing: DesignTokens.Spacing.sm, alignment: .top)
                                ],
                                alignment: .leading,
                                spacing: DesignTokens.Spacing.sm
                            ) {
                                ForEach(visiblePreviewDates, id: \.self) { date in
                                    HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                                        Image(systemName: "calendar")
                                            .foregroundStyle(DesignTokens.Colors.brandBlue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(formattedSolar(date))
                                                    .font(.body.weight(.medium))
                                                if isLunarLeapMonth(date) {
                                                    Text("闰月")
                                                        .font(.caption2.weight(.semibold))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(
                                                            Capsule(style: .continuous)
                                                                .fill(DesignTokens.Colors.brandBlue.opacity(0.16))
                                                        )
                                                        .foregroundStyle(DesignTokens.Colors.brandBlue)
                                                }
                                            }
                                            Text("农历 \(formattedLunar(date))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.secondary.opacity(0.08))
                                    )
                                }
                            }

                            if previewDates.count > previewDisplayLimit {
                                Text("... 仅显示前 \(previewDisplayLimit) 条，共 \(previewDates.count) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: 180)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .background(lunarCardShape.fill(DesignTokens.Colors.cardBackground))

                Button("刷新预览") {
                    refreshPreview()
                }
                .disabled(isSaving)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .lunarCard()
        }
    }

    private var saveActionSection: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await syncRule()
                }
            } label: {
                HStack {
                    if isSaving {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text(activeRuleId == nil ? "创建并保存规则" : "保存并同步规则")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || !canSave)

            Button("清空") {
                clearRuleEditor()
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private var resultSection: some View {
        if !resultMessage.isEmpty {
            Label {
                Text(resultMessage)
            } icon: {
                Image(systemName: resultMessage.hasPrefix("同步失败") || resultMessage.hasPrefix("删除失败") ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .foregroundStyle(resultMessage.hasPrefix("同步失败") || resultMessage.hasPrefix("删除失败") ? DesignTokens.Colors.dangerRed : DesignTokens.Colors.successGreen)
            }
            .lunarCard()
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    private var yearOptions: [Int] {
        Array((gregorianYear - 5)...(gregorianYear + 10))
    }

    private var spec: LunarSpec {
        LunarSpec(month: lunarMonth, day: lunarDay, isLeapMonth: isLeapMonth)
    }

    private func enforceLeapSelectionConsistency() {
        if (repeatMode == .monthly || repeatMode == .yearly)
            && !includeLeapMonthsForMonthlyRepeat
            && isLeapMonth {
            isLeapMonth = false
        }
    }

    private func enforceRepeatEndConsistency() {
        if repeatEndCount < 1 {
            repeatEndCount = 1
        }
        if repeatEndDate < startDateForSelectedYear {
            repeatEndDate = startDateForSelectedYear
        }
    }

    private func refreshPreview() {
        do {
            previewDates = try scheduler.previewOccurrences(
                startGregorianYear: gregorianYear,
                spec: spec,
                repeatMode: repeatMode,
                missingDayStrategy: missingDayStrategy,
                includeLeapMonthsForMonthlyRepeat: includeLeapMonthsForMonthlyRepeat,
                repeatEndMode: repeatEndMode,
                repeatEndCount: repeatEndCount,
                repeatEndDate: repeatEndDate
            )
            resultMessage = ""
        } catch {
            previewDates = []
            resultMessage = error.localizedDescription
        }
    }

    @MainActor
    private func syncRule() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let occurrences = try scheduler.creationOccurrences(
                startGregorianYear: gregorianYear,
                spec: spec,
                repeatMode: repeatMode,
                missingDayStrategy: missingDayStrategy,
                includeLeapMonthsForMonthlyRepeat: includeLeapMonthsForMonthlyRepeat,
                repeatEndMode: repeatEndMode,
                repeatEndCount: repeatEndCount,
                repeatEndDate: repeatEndDate
            )

            let existingRule = ruleStore.rule(by: ruleId)
            let existingItems = existingRule?.occurrences ?? []

            let request = CreateRequest(
                ruleId: ruleId,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notes,
                location: location,
                type: targetType,
                isAllDay: isAllDay,
                time: time,
                eventDurationMinutes: eventDurationMinutes,
                reminderOffsetMinutes: reminderOffsetMinutes
            )

            let sync = try await adapter.syncRule(
                request: request,
                occurrences: occurrences,
                existingItems: existingItems
            )

            let savedRule = StoredRule(
                id: ruleId,
                title: request.title,
                notes: request.notes,
                location: request.location,
                type: request.type,
                repeatMode: repeatMode,
                repeatEndMode: repeatEndMode,
                repeatEndCount: repeatEndCount,
                repeatEndDate: repeatMode == .monthly || repeatMode == .yearly ? repeatEndDate : nil,
                missingDayStrategy: missingDayStrategy,
                startGregorianYear: gregorianYear,
                spec: spec,
                includeLeapMonthsForMonthlyRepeat: includeLeapMonthsForMonthlyRepeat,
                isAllDay: isAllDay,
                hour: Calendar.current.component(.hour, from: time),
                minute: Calendar.current.component(.minute, from: time),
                eventDurationMinutes: eventDurationMinutes,
                reminderOffsetMinutes: reminderOffsetMinutes,
                occurrences: sync.items,
                updatedAt: Date()
            )

            ruleStore.upsert(savedRule)
            activeRuleId = ruleId
            resultMessage = "已创建 \(sync.created) 条，已更新 \(sync.updated) 条，已删除 \(sync.deleted) 条，已跳过 \(sync.skipped) 条。"
        } catch {
            resultMessage = "同步失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func deleteRule(_ rule: StoredRule) async {
        isSaving = true
        defer { isSaving = false }

        do {
            let deletedCount = try await adapter.deleteItems(type: rule.type, items: rule.occurrences)
            ruleStore.delete(ruleID: rule.id)

            if activeRuleId == rule.id {
                resetRuleEditor()
            }

            resultMessage = "规则已删除，同时删除系统条目 \(deletedCount) 条。"
        } catch {
            resultMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func load(_ rule: StoredRule) {
        ruleId = rule.id
        activeRuleId = rule.id

        title = rule.title
        notes = rule.notes
        location = rule.location
        targetType = rule.type
        repeatMode = rule.repeatMode
        repeatEndMode = rule.repeatEndMode
        repeatEndCount = max(1, rule.repeatEndCount)
        repeatEndDate = rule.repeatEndDate ?? startDateForSelectedYear
        missingDayStrategy = rule.missingDayStrategy

        gregorianYear = rule.startGregorianYear
        lunarMonth = rule.spec.month
        lunarDay = rule.spec.day
        isLeapMonth = rule.spec.isLeapMonth
        includeLeapMonthsForMonthlyRepeat = rule.includeLeapMonthsForMonthlyRepeat
        enforceLeapSelectionConsistency()

        isAllDay = rule.isAllDay
        eventDurationMinutes = rule.eventDurationMinutes
        reminderOffsetMinutes = rule.reminderOffsetMinutes
        time = makeTime(hour: rule.hour, minute: rule.minute)

        refreshPreview()
    }

    private func resetRuleEditor() {
        ruleId = UUID().uuidString
        activeRuleId = nil
        resultMessage = ""
        refreshPreview()
    }

    private func clearRuleEditor() {
        focusedField = nil

        title = ""
        notes = ""
        location = ""
        targetType = .event
        repeatMode = .none
        repeatEndMode = .afterOccurrences
        repeatEndCount = 1
        repeatEndDate = startDateForSelectedYear
        missingDayStrategy = .skip

        gregorianYear = Calendar.current.component(.year, from: Date())
        lunarMonth = 1
        lunarDay = 1
        isLeapMonth = false
        includeLeapMonthsForMonthlyRepeat = false

        isAllDay = true
        time = Date()
        eventDurationMinutes = 60
        reminderOffsetMinutes = 900

        resetRuleEditor()
    }

    private func makeTime(hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        return cal.date(from: components) ?? now
    }

    private func reminderLabel(for offset: Int) -> String {
        switch offset {
        case 5:
            return "提前 5 分钟"
        case 10:
            return "提前 10 分钟"
        case 15:
            return "提前 15 分钟"
        case 30:
            return "提前 30 分钟"
        case 60:
            return "提前 1 小时"
        case 120:
            return "提前 2 小时"
        case 1440:
            return "提前 1 天"
        case 2880:
            return "提前 2 天"
        case 10080:
            return "提前 1 周"
        default:
            if offset % 1440 == 0 {
                return "提前 \(offset / 1440) 天"
            }
            if offset % 60 == 0 {
                return "提前 \(offset / 60) 小时"
            }
            return "提前 \(offset) 分钟"
        }
    }

    private func allDayReminderLabel(for offset: Int) -> String {
        switch offset {
        case 900:
            return "1天前（上午 9 时）"
        case 0:
            return "无"
        case -540:
            return "日程当天（上午 9 时）"
        case 2340:
            return "2天前（上午 9 时）"
        case 10080:
            return "1周前"
        default:
            return reminderLabel(for: offset)
        }
    }

    private var startDateForSelectedYear: Date {
        let calendar = Calendar.current
        return calendar.date(from: DateComponents(year: gregorianYear, month: 1, day: 1)) ?? Date()
    }

    private func formattedSolar(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateStyle = .medium
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func overviewChip(title: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(minWidth: 140, alignment: .leading)
        .background(lunarCardShape.fill(.ultraThinMaterial))
        .overlay(
            lunarCardShape
                .stroke(tint.opacity(0.26), lineWidth: 1)
        )
    }

    private func previewMetaItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    private var lunarCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
    }

    private func formattedLunar(_ date: Date) -> String {
        guard let detail = lunarDetail(for: date) else {
            let fallback = DateFormatter()
            fallback.calendar = Calendar(identifier: .chinese)
            fallback.locale = Locale(identifier: "zh_CN")
            fallback.timeZone = .current
            fallback.dateFormat = "r年M月d日"
            return fallback.string(from: date)
        }
        let leapPrefix = detail.isLeapMonth ? "闰" : ""
        return "\(leapPrefix)\(detail.month)月\(detail.day)日"
    }

    private func isLunarLeapMonth(_ date: Date) -> Bool {
        lunarDetail(for: date)?.isLeapMonth == true
    }

    private var previewLeapMonthSummary: String? {
        var seen: Set<String> = []
        var ordered: [String] = []
        let calendar = Calendar.current

        for date in previewDates {
            guard let detail = lunarDetail(for: date), detail.isLeapMonth else { continue }
            let solarYear = calendar.component(.year, from: date)
            let token = "\(solarYear)年闰\(detail.month)月"
            if seen.insert(token).inserted {
                ordered.append(token)
            }
        }

        guard !ordered.isEmpty else { return nil }
        return ordered.joined(separator: "、")
    }

    private func lunarDetail(for date: Date) -> (month: Int, day: Int, isLeapMonth: Bool)? {
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.timeZone = .current
        let comp = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: date)
        guard let month = comp.month, let day = comp.day else { return nil }
        return (month, day, comp.isLeapMonth ?? false)
    }

    private func formattedUpdatedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

private enum FocusField: Hashable {
    case title
    case notes
    case location
}

private extension View {
    @ViewBuilder
    func lunarAutocapSentences() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.sentences)
        #else
        self
        #endif
    }

    @ViewBuilder
    func lunarAutocapWords() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    func lunarCard() -> some View {
        padding(DesignTokens.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }

    func lunarTextFieldStyle() -> some View {
        padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.field, style: .continuous)
                    .fill(DesignTokens.Colors.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.field, style: .continuous)
                    .stroke(DesignTokens.Colors.brandBlue.opacity(0.24), lineWidth: 1)
            )
    }
}

enum TargetType: String, CaseIterable, Identifiable, Codable {
    case event
    case reminder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .event: return "日程"
        case .reminder: return "提醒"
        }
    }
}

enum LunarRepeatMode: String, CaseIterable, Identifiable, Codable {
    case none
    case monthly
    case yearly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "不重复"
        case .monthly: return "按农历月"
        case .yearly: return "按农历年"
        }
    }
}

enum RepeatEndMode: String, CaseIterable, Identifiable, Codable {
    case afterOccurrences
    case onDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .afterOccurrences: return "于"
        case .onDate: return "于日期"
        }
    }
}

enum MissingDayStrategy: String, CaseIterable, Identifiable, Codable {
    case skip
    case fallbackToMonthEnd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .skip: return "跳过该月"
        case .fallbackToMonthEnd: return "顺延到当月最后一天"
        }
    }
}

struct LunarSpec: Codable {
    let month: Int
    let day: Int
    let isLeapMonth: Bool

    var displayText: String {
        let leapText = isLeapMonth ? "闰" : ""
        return "农历\(leapText)\(month)月\(day)日"
    }
}

struct StoredOccurrence: Codable, Identifiable {
    let occKey: String
    let calendarItemIdentifier: String

    var id: String { "\(occKey)-\(calendarItemIdentifier)" }
}

struct StoredRule: Codable, Identifiable {
    let id: String
    let title: String
    let notes: String
    let location: String
    let type: TargetType
    let repeatMode: LunarRepeatMode
    let repeatEndMode: RepeatEndMode
    let repeatEndCount: Int
    let repeatEndDate: Date?
    let missingDayStrategy: MissingDayStrategy
    let startGregorianYear: Int
    let spec: LunarSpec
    let includeLeapMonthsForMonthlyRepeat: Bool
    let isAllDay: Bool
    let hour: Int
    let minute: Int
    let eventDurationMinutes: Int
    let reminderOffsetMinutes: Int
    let occurrences: [StoredOccurrence]
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case location
        case type
        case repeatMode
        case repeatEndMode
        case repeatEndCount
        case repeatEndDate
        case missingDayStrategy
        case startGregorianYear
        case spec
        case includeLeapMonthsForMonthlyRepeat
        case isAllDay
        case hour
        case minute
        case eventDurationMinutes
        case reminderOffsetMinutes
        case occurrences
        case updatedAt
    }

    init(
        id: String,
        title: String,
        notes: String,
        location: String,
        type: TargetType,
        repeatMode: LunarRepeatMode,
        repeatEndMode: RepeatEndMode,
        repeatEndCount: Int,
        repeatEndDate: Date?,
        missingDayStrategy: MissingDayStrategy,
        startGregorianYear: Int,
        spec: LunarSpec,
        includeLeapMonthsForMonthlyRepeat: Bool,
        isAllDay: Bool,
        hour: Int,
        minute: Int,
        eventDurationMinutes: Int,
        reminderOffsetMinutes: Int,
        occurrences: [StoredOccurrence],
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.location = location
        self.type = type
        self.repeatMode = repeatMode
        self.repeatEndMode = repeatEndMode
        self.repeatEndCount = max(1, repeatEndCount)
        self.repeatEndDate = repeatEndDate
        self.missingDayStrategy = missingDayStrategy
        self.startGregorianYear = startGregorianYear
        self.spec = spec
        self.includeLeapMonthsForMonthlyRepeat = includeLeapMonthsForMonthlyRepeat
        self.isAllDay = isAllDay
        self.hour = hour
        self.minute = minute
        self.eventDurationMinutes = eventDurationMinutes
        self.reminderOffsetMinutes = reminderOffsetMinutes
        self.occurrences = occurrences
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decode(String.self, forKey: .notes)
        location = try container.decode(String.self, forKey: .location)
        type = try container.decode(TargetType.self, forKey: .type)
        repeatMode = try container.decode(LunarRepeatMode.self, forKey: .repeatMode)
        repeatEndMode = try container.decodeIfPresent(RepeatEndMode.self, forKey: .repeatEndMode) ?? .afterOccurrences
        repeatEndCount = max(1, try container.decodeIfPresent(Int.self, forKey: .repeatEndCount) ?? 1)
        repeatEndDate = try container.decodeIfPresent(Date.self, forKey: .repeatEndDate)
        missingDayStrategy = try container.decode(MissingDayStrategy.self, forKey: .missingDayStrategy)
        startGregorianYear = try container.decode(Int.self, forKey: .startGregorianYear)
        spec = try container.decode(LunarSpec.self, forKey: .spec)
        includeLeapMonthsForMonthlyRepeat = try container.decode(Bool.self, forKey: .includeLeapMonthsForMonthlyRepeat)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        hour = try container.decode(Int.self, forKey: .hour)
        minute = try container.decode(Int.self, forKey: .minute)
        eventDurationMinutes = try container.decode(Int.self, forKey: .eventDurationMinutes)
        reminderOffsetMinutes = try container.decode(Int.self, forKey: .reminderOffsetMinutes)
        occurrences = try container.decode([StoredOccurrence].self, forKey: .occurrences)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

final class RuleStore: ObservableObject {
    @Published private(set) var rules: [StoredRule] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LunarSmart", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("rules.json")
        load()
    }

    func rule(by id: String) -> StoredRule? {
        rules.first(where: { $0.id == id })
    }

    func upsert(_ rule: StoredRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.insert(rule, at: 0)
        }
        save()
    }

    func delete(ruleID: String) {
        rules.removeAll { $0.id == ruleID }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([StoredRule].self, from: data) {
            rules = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct CreateRequest {
    let ruleId: String
    let title: String
    let notes: String
    let location: String
    let type: TargetType
    let isAllDay: Bool
    let time: Date
    let eventDurationMinutes: Int
    let reminderOffsetMinutes: Int
}

struct SyncResult {
    let created: Int
    let updated: Int
    let deleted: Int
    let skipped: Int
    let items: [StoredOccurrence]
}

final class LunarScheduler {
    private let engine = LunarEngine()

    func previewOccurrences(
        startGregorianYear: Int,
        spec: LunarSpec,
        repeatMode: LunarRepeatMode,
        missingDayStrategy: MissingDayStrategy,
        includeLeapMonthsForMonthlyRepeat: Bool,
        repeatEndMode: RepeatEndMode,
        repeatEndCount: Int,
        repeatEndDate: Date
    ) throws -> [Date] {
        let normalizedCount = max(1, repeatEndCount)
        let window = previewWindow(
            repeatMode: repeatMode,
            repeatEndMode: repeatEndMode,
            repeatEndCount: normalizedCount
        )

        let generated = try engine.occurrences(
            startGregorianYear: startGregorianYear,
            spec: spec,
            repeatMode: repeatMode,
            missingDayStrategy: missingDayStrategy,
            includeLeapMonthsForMonthlyRepeat: includeLeapMonthsForMonthlyRepeat,
            monthlyWindowCount: window.monthlyWindowCount,
            yearlyWindowCount: window.yearlyWindowCount
        )

        return applyRepeatEnding(
            dates: generated,
            repeatMode: repeatMode,
            repeatEndMode: repeatEndMode,
            repeatEndCount: normalizedCount,
            repeatEndDate: repeatEndDate
        )
    }

    func creationOccurrences(
        startGregorianYear: Int,
        spec: LunarSpec,
        repeatMode: LunarRepeatMode,
        missingDayStrategy: MissingDayStrategy,
        includeLeapMonthsForMonthlyRepeat: Bool,
        repeatEndMode: RepeatEndMode,
        repeatEndCount: Int,
        repeatEndDate: Date
    ) throws -> [Date] {
        let normalizedCount = max(1, repeatEndCount)
        let window = creationWindow(
            repeatMode: repeatMode,
            repeatEndMode: repeatEndMode,
            repeatEndCount: normalizedCount
        )

        let generated = try engine.occurrences(
            startGregorianYear: startGregorianYear,
            spec: spec,
            repeatMode: repeatMode,
            missingDayStrategy: missingDayStrategy,
            includeLeapMonthsForMonthlyRepeat: includeLeapMonthsForMonthlyRepeat,
            monthlyWindowCount: window.monthlyWindowCount,
            yearlyWindowCount: window.yearlyWindowCount
        )

        return applyRepeatEnding(
            dates: generated,
            repeatMode: repeatMode,
            repeatEndMode: repeatEndMode,
            repeatEndCount: normalizedCount,
            repeatEndDate: repeatEndDate
        )
    }

    private func previewWindow(
        repeatMode: LunarRepeatMode,
        repeatEndMode: RepeatEndMode,
        repeatEndCount: Int
    ) -> (monthlyWindowCount: Int, yearlyWindowCount: Int) {
        switch repeatMode {
        case .none:
            return (1, 1)
        case .monthly:
            let monthly = repeatEndMode == .afterOccurrences ? max(12, repeatEndCount) : 720
            return (monthly, 1)
        case .yearly:
            let yearly = repeatEndMode == .afterOccurrences ? max(5, repeatEndCount) : 120
            return (1, yearly)
        }
    }

    private func creationWindow(
        repeatMode: LunarRepeatMode,
        repeatEndMode: RepeatEndMode,
        repeatEndCount: Int
    ) -> (monthlyWindowCount: Int, yearlyWindowCount: Int) {
        switch repeatMode {
        case .none:
            return (1, 1)
        case .monthly:
            let monthly = repeatEndMode == .afterOccurrences ? repeatEndCount : 720
            return (monthly, 1)
        case .yearly:
            let yearly = repeatEndMode == .afterOccurrences ? repeatEndCount : 120
            return (1, yearly)
        }
    }

    private func applyRepeatEnding(
        dates: [Date],
        repeatMode: LunarRepeatMode,
        repeatEndMode: RepeatEndMode,
        repeatEndCount: Int,
        repeatEndDate: Date
    ) -> [Date] {
        guard repeatMode == .monthly || repeatMode == .yearly else {
            return Array(dates.prefix(1))
        }

        switch repeatEndMode {
        case .afterOccurrences:
            return Array(dates.prefix(max(1, repeatEndCount)))
        case .onDate:
            let endOfDay = Calendar.current.date(
                bySettingHour: 23,
                minute: 59,
                second: 59,
                of: repeatEndDate
            ) ?? repeatEndDate
            return dates.filter { $0 <= endOfDay }
        }
    }
}

struct LunarMonthBlock {
    let lunarYear: Int
    let lunarMonth: Int
    let isLeapMonth: Bool
    let days: [Date]

    func date(forDay day: Int, strategy: MissingDayStrategy) -> Date? {
        if day <= days.count {
            return days[day - 1]
        }
        if strategy == .fallbackToMonthEnd {
            return days.last
        }
        return nil
    }
}

final class LunarEngine {
    private var gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    private var lunar: Calendar = {
        var c = Calendar(identifier: .chinese)
        c.timeZone = .current
        return c
    }()

    func occurrences(
        startGregorianYear: Int,
        spec: LunarSpec,
        repeatMode: LunarRepeatMode,
        missingDayStrategy: MissingDayStrategy,
        includeLeapMonthsForMonthlyRepeat: Bool,
        monthlyWindowCount: Int,
        yearlyWindowCount: Int
    ) throws -> [Date] {
        switch repeatMode {
        case .none:
            guard let first = try firstOccurrenceInYear(
                startGregorianYear: startGregorianYear,
                spec: spec,
                missingDayStrategy: missingDayStrategy
            ) else {
                throw LunarError.invalidInput("该公历年份内没有匹配日期，请检查闰月和日期策略。")
            }
            return [first]

        case .yearly:
            var dates: [Date] = []
            for year in startGregorianYear..<(startGregorianYear + yearlyWindowCount) {
                let yearDates = try occurrencesInYear(
                    startGregorianYear: year,
                    spec: spec,
                    missingDayStrategy: missingDayStrategy,
                    includeLeapMonthCompanion: includeLeapMonthsForMonthlyRepeat
                )
                dates.append(contentsOf: yearDates)
            }
            return dates

        case .monthly:
            let anchorSpec: LunarSpec
            if !includeLeapMonthsForMonthlyRepeat && spec.isLeapMonth {
                anchorSpec = LunarSpec(month: spec.month, day: spec.day, isLeapMonth: false)
            } else {
                anchorSpec = spec
            }

            guard let anchor = try firstOccurrenceInYear(
                startGregorianYear: startGregorianYear,
                spec: anchorSpec,
                missingDayStrategy: missingDayStrategy
            ) else {
                throw LunarError.invalidInput("该公历年份内没有匹配日期，请检查闰月和日期策略。")
            }

            return monthlyOccurrences(
                anchor: anchor,
                targetDay: anchorSpec.day,
                includeLeapMonths: includeLeapMonthsForMonthlyRepeat,
                missingDayStrategy: missingDayStrategy,
                monthlyWindowCount: monthlyWindowCount
            )
        }
    }

    private func firstOccurrenceInYear(
        startGregorianYear: Int,
        spec: LunarSpec,
        missingDayStrategy: MissingDayStrategy
    ) throws -> Date? {
        try occurrencesInYear(
            startGregorianYear: startGregorianYear,
            spec: spec,
            missingDayStrategy: missingDayStrategy,
            includeLeapMonthCompanion: false
        ).first
    }

    private func occurrencesInYear(
        startGregorianYear: Int,
        spec: LunarSpec,
        missingDayStrategy: MissingDayStrategy,
        includeLeapMonthCompanion: Bool
    ) throws -> [Date] {
        guard let yearStart = gregorian.date(from: DateComponents(year: startGregorianYear, month: 1, day: 1)),
              let yearEnd = gregorian.date(from: DateComponents(year: startGregorianYear, month: 12, day: 31))
        else {
            throw LunarError.invalidInput("年份无效。")
        }

        let shouldIncludeLeapCompanion = includeLeapMonthCompanion && !spec.isLeapMonth
        let blocks = monthBlocks(from: yearStart, to: yearEnd)
            .filter {
                guard $0.lunarMonth == spec.month else { return false }
                if shouldIncludeLeapCompanion {
                    return true
                }
                return $0.isLeapMonth == spec.isLeapMonth
            }

        var results: [Date] = []
        for block in blocks {
            if let date = block.date(forDay: spec.day, strategy: missingDayStrategy) {
                results.append(date)
            }
        }
        return results
    }

    private func monthlyOccurrences(
        anchor: Date,
        targetDay: Int,
        includeLeapMonths: Bool,
        missingDayStrategy: MissingDayStrategy,
        monthlyWindowCount: Int
    ) -> [Date] {
        guard monthlyWindowCount > 0 else { return [] }
        guard let end = gregorian.date(byAdding: .year, value: 60, to: anchor) else { return [anchor] }

        var dates: [Date] = [anchor]
        if dates.count >= monthlyWindowCount {
            return dates
        }

        let anchorComp = lunar.dateComponents([.year, .month, .isLeapMonth], from: anchor)
        let anchorYear = anchorComp.year ?? 0
        let anchorMonth = anchorComp.month ?? 0
        let anchorLeap = anchorComp.isLeapMonth ?? false

        for block in monthBlocks(from: anchor, to: end) {
            if block.lunarYear == anchorYear &&
                block.lunarMonth == anchorMonth &&
                block.isLeapMonth == anchorLeap {
                continue
            }
            if !includeLeapMonths && block.isLeapMonth {
                continue
            }
            if let date = block.date(forDay: targetDay, strategy: missingDayStrategy) {
                dates.append(date)
            }
            if dates.count >= monthlyWindowCount {
                break
            }
        }

        return dates
    }

    private func monthBlocks(from start: Date, to end: Date) -> [LunarMonthBlock] {
        var blocks: [LunarMonthBlock] = []
        var current = start

        var currentKey: String?
        var currentDates: [Date] = []
        var currentYear = 0
        var currentMonth = 0
        var currentLeap = false

        while current <= end {
            let comp = lunar.dateComponents([.year, .month, .isLeapMonth], from: current)
            let lYear = comp.year ?? 0
            let lMonth = comp.month ?? 0
            let leap = comp.isLeapMonth ?? false
            let key = "\(lYear)-\(lMonth)-\(leap)"

            if currentKey == nil {
                currentKey = key
                currentYear = lYear
                currentMonth = lMonth
                currentLeap = leap
            }

            if key != currentKey {
                if !currentDates.isEmpty {
                    blocks.append(LunarMonthBlock(lunarYear: currentYear, lunarMonth: currentMonth, isLeapMonth: currentLeap, days: currentDates))
                }
                currentDates = []
                currentKey = key
                currentYear = lYear
                currentMonth = lMonth
                currentLeap = leap
            }

            currentDates.append(current)
            guard let next = gregorian.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        if !currentDates.isEmpty {
            blocks.append(LunarMonthBlock(lunarYear: currentYear, lunarMonth: currentMonth, isLeapMonth: currentLeap, days: currentDates))
        }

        return blocks
    }
}

final class EventKitAdapter {
    private let eventStore = EKEventStore()

    private var gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    private lazy var occFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = gregorian
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func syncRule(
        request: CreateRequest,
        occurrences: [Date],
        existingItems: [StoredOccurrence]
    ) async throws -> SyncResult {
        if occurrences.isEmpty {
            let deleted = try await deleteItems(type: request.type, items: existingItems)
            return SyncResult(created: 0, updated: 0, deleted: deleted, skipped: 0, items: [])
        }

        switch request.type {
        case .event:
            try await requestEventPermission()
        case .reminder:
            try await requestReminderPermission()
        }

        let range = makeDateRange(for: occurrences)
        let markerMap = try await existingMarkerMap(
            type: request.type,
            ruleId: request.ruleId,
            start: range.start,
            end: range.end
        )

        let existingByOcc = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.occKey, $0.calendarItemIdentifier) })

        var created = 0
        var updated = 0
        var deleted = 0
        var skipped = 0
        var keptOccurrences: [StoredOccurrence] = []

        let sortedDates = occurrences.sorted()
        let desiredKeys = Set(sortedDates.map { occurrenceKey(for: $0) })

        for date in sortedDates {
            let occKey = occurrenceKey(for: date)

            let existingID = existingByOcc[occKey] ?? markerMap[occKey]
            if let existingID,
               let item = eventStore.calendarItem(withIdentifier: existingID) {
                do {
                    let savedID = try updateExistingItem(item, request: request, date: date, occKey: occKey)
                    keptOccurrences.append(StoredOccurrence(occKey: occKey, calendarItemIdentifier: savedID))
                    updated += 1
                    continue
                } catch {
                    if let fallbackID = try? createItem(request: request, date: date, occKey: occKey) {
                        keptOccurrences.append(StoredOccurrence(occKey: occKey, calendarItemIdentifier: fallbackID))
                        created += 1
                        continue
                    }
                    skipped += 1
                    continue
                }
            }

            if let newID = try? createItem(request: request, date: date, occKey: occKey) {
                keptOccurrences.append(StoredOccurrence(occKey: occKey, calendarItemIdentifier: newID))
                created += 1
            } else {
                skipped += 1
            }
        }

        for stored in existingItems {
            if desiredKeys.contains(stored.occKey) {
                continue
            }
            if let item = eventStore.calendarItem(withIdentifier: stored.calendarItemIdentifier) {
                try deleteItem(item: item, type: request.type)
                deleted += 1
            }
        }

        try eventStore.commit()
        keptOccurrences.sort { $0.occKey < $1.occKey }

        return SyncResult(
            created: created,
            updated: updated,
            deleted: deleted,
            skipped: skipped,
            items: keptOccurrences
        )
    }

    func deleteItems(type: TargetType, items: [StoredOccurrence]) async throws -> Int {
        switch type {
        case .event:
            try await requestEventPermission()
        case .reminder:
            try await requestReminderPermission()
        }

        var deleted = 0
        for item in items {
            if let existing = eventStore.calendarItem(withIdentifier: item.calendarItemIdentifier) {
                try deleteItem(item: existing, type: type)
                deleted += 1
            }
        }
        try eventStore.commit()
        return deleted
    }

    private func makeDateRange(for occurrences: [Date]) -> (start: Date, end: Date) {
        let minDate = occurrences.min() ?? Date()
        let maxDate = occurrences.max() ?? minDate
        let start = gregorian.startOfDay(for: minDate)
        let end = gregorian.date(byAdding: .day, value: 1, to: gregorian.startOfDay(for: maxDate)) ?? maxDate
        return (start, end)
    }

    private func existingMarkerMap(type: TargetType, ruleId: String, start: Date, end: Date) async throws -> [String: String] {
        switch type {
        case .event:
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = eventStore.events(matching: predicate)
            var map: [String: String] = [:]
            for event in events {
                if let occ = extractOccurrenceKey(url: event.url, notes: event.notes, expectedRuleId: ruleId) {
                    map[occ] = event.calendarItemIdentifier
                }
            }
            return map

        case .reminder:
            let predicate = eventStore.predicateForReminders(in: nil)
            let reminders = await fetchReminders(predicate: predicate)
            var map: [String: String] = [:]
            for reminder in reminders {
                guard let due = reminder.dueDateComponents?.date,
                      due >= start,
                      due <= end
                else {
                    continue
                }
                if let occ = extractOccurrenceKey(url: reminder.url, notes: reminder.notes, expectedRuleId: ruleId) {
                    map[occ] = reminder.calendarItemIdentifier
                }
            }
            return map
        }
    }

    private func fetchReminders(predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func createItem(request: CreateRequest, date: Date, occKey: String) throws -> String {
        switch request.type {
        case .event:
            guard let calendar = eventStore.defaultCalendarForNewEvents else {
                throw LunarError.runtime("找不到默认日历。")
            }

            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            apply(event: event, request: request, date: date)
            try eventStore.save(event, span: .thisEvent, commit: false)
            return event.calendarItemIdentifier

        case .reminder:
            guard let calendar = eventStore.defaultCalendarForNewReminders() else {
                throw LunarError.runtime("找不到默认提醒列表。")
            }

            let reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = calendar
            apply(reminder: reminder, request: request, date: date, occKey: occKey)
            try eventStore.save(reminder, commit: false)
            return reminder.calendarItemIdentifier
        }
    }

    private func updateExistingItem(_ item: EKCalendarItem, request: CreateRequest, date: Date, occKey: String) throws -> String {
        switch request.type {
        case .event:
            guard let event = item as? EKEvent else {
                throw LunarError.runtime("系统条目类型不匹配，无法更新。")
            }
            apply(event: event, request: request, date: date)
            try eventStore.save(event, span: .thisEvent, commit: false)
            return event.calendarItemIdentifier

        case .reminder:
            guard let reminder = item as? EKReminder else {
                throw LunarError.runtime("系统条目类型不匹配，无法更新。")
            }
            apply(reminder: reminder, request: request, date: date, occKey: occKey)
            try eventStore.save(reminder, commit: false)
            return reminder.calendarItemIdentifier
        }
    }

    private func deleteItem(item: EKCalendarItem, type: TargetType) throws {
        switch type {
        case .event:
            guard let event = item as? EKEvent else { return }
            try eventStore.remove(event, span: .thisEvent, commit: false)
        case .reminder:
            guard let reminder = item as? EKReminder else { return }
            try eventStore.remove(reminder, commit: false)
        }
    }

    private func apply(event: EKEvent, request: CreateRequest, date: Date) {
        event.title = request.title
        event.location = request.location
        event.notes = request.notes
        // Keep Apple Calendar's "Add URL" field empty.
        event.url = nil

        if request.isAllDay {
            let bounds = allDayBounds(for: date)
            event.isAllDay = true
            // For all-day events, keep timezone floating (nil) so Calendar treats
            // the event as a date-only entry instead of a timed one.
            event.timeZone = nil
            event.startDate = bounds.start
            event.endDate = bounds.end
        } else {
            let baseDate = mergedDate(dateOnly: date, timeSource: request.time, allDay: false)
            event.isAllDay = false
            event.timeZone = .current
            event.startDate = baseDate
            event.endDate = gregorian.date(byAdding: .minute, value: request.eventDurationMinutes, to: baseDate)
        }

        event.alarms = nil
        if let relativeOffset = alarmRelativeOffset(for: request) {
            event.addAlarm(EKAlarm(relativeOffset: relativeOffset))
        }
    }

    private func apply(reminder: EKReminder, request: CreateRequest, date: Date, occKey: String) {
        reminder.title = request.title
        reminder.notes = request.notes
        reminder.url = markerURL(ruleId: request.ruleId, occKey: occKey)

        let baseDate = mergedDate(dateOnly: date, timeSource: request.time, allDay: request.isAllDay)
        reminder.dueDateComponents = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: baseDate)

        reminder.alarms = nil
        if let relativeOffset = alarmRelativeOffset(for: request) {
            reminder.addAlarm(EKAlarm(relativeOffset: relativeOffset))
        }
    }

    private func alarmRelativeOffset(for request: CreateRequest) -> TimeInterval? {
        guard request.reminderOffsetMinutes != 0 else { return nil }
        // reminderOffsetMinutes stores "minutes before start". A negative value means
        // "minutes after start", used by all-day Apple Calendar style options.
        return TimeInterval(-request.reminderOffsetMinutes * 60)
    }

    private func occurrenceKey(for date: Date) -> String {
        occFormatter.string(from: date)
    }

    private func markerURL(ruleId: String, occKey: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "lunarsmart"
        comps.host = "rule"
        comps.path = "/\(ruleId)"
        comps.queryItems = [URLQueryItem(name: "occ", value: occKey)]
        return comps.url
    }

    private func extractOccurrenceKey(url: URL?, notes: String?, expectedRuleId: String) -> String? {
        if let url,
           url.scheme == "lunarsmart",
           url.host == "rule" {
            let urlRuleID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if urlRuleID == expectedRuleId,
               let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let occ = comps.queryItems?.first(where: { $0.name == "occ" })?.value,
               !occ.isEmpty {
                return occ
            }
        }

        guard let notes else { return nil }
        let ruleToken = "[LUNAR_RULE_ID=\(expectedRuleId)]"
        guard notes.contains(ruleToken) else { return nil }

        let prefix = "[LUNAR_OCC="
        guard let occStart = notes.range(of: prefix) else { return nil }
        let afterPrefix = notes[occStart.upperBound...]
        guard let end = afterPrefix.firstIndex(of: "]") else { return nil }
        return String(afterPrefix[..<end])
    }

    private func mergedDate(dateOnly: Date, timeSource: Date, allDay: Bool) -> Date {
        let dateComponents = gregorian.dateComponents([.year, .month, .day], from: dateOnly)
        if allDay {
            return gregorian.date(from: dateComponents) ?? dateOnly
        }

        let timeComponents = gregorian.dateComponents([.hour, .minute], from: timeSource)
        var merged = DateComponents()
        merged.year = dateComponents.year
        merged.month = dateComponents.month
        merged.day = dateComponents.day
        merged.hour = timeComponents.hour
        merged.minute = timeComponents.minute
        return gregorian.date(from: merged) ?? dateOnly
    }

    private func allDayBounds(for date: Date) -> (start: Date, end: Date) {
        var local = gregorian
        local.timeZone = .current
        var day = local.dateComponents([.year, .month, .day], from: date)
        day.hour = 0
        day.minute = 0
        day.second = 0
        let start = local.date(from: day) ?? local.startOfDay(for: date)
        // Keep same-day end for one-day all-day events to match Calendar.app's
        // date-style editing behavior.
        let end = start
        return (start, end)
    }

    private func requestEventPermission() async throws {
        if #available(iOS 17.0, macOS 14.0, *) {
            let granted = try await eventStore.requestFullAccessToEvents()
            guard granted else { throw LunarError.permissionDenied("没有日历权限。") }
        } else {
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestAccess(to: .event) { ok, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ok)
                    }
                }
            }
            guard granted else { throw LunarError.permissionDenied("没有日历权限。") }
        }
    }

    private func requestReminderPermission() async throws {
        if #available(iOS 17.0, macOS 14.0, *) {
            let granted = try await eventStore.requestFullAccessToReminders()
            guard granted else { throw LunarError.permissionDenied("没有提醒事项权限。") }
        } else {
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestAccess(to: .reminder) { ok, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ok)
                    }
                }
            }
            guard granted else { throw LunarError.permissionDenied("没有提醒事项权限。") }
        }
    }
}

enum LunarError: LocalizedError {
    case invalidInput(String)
    case permissionDenied(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .permissionDenied(let message), .runtime(let message):
            return message
        }
    }
}
