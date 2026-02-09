import SwiftUI
import EventKit
import Combine

// 统一维护界面间距、圆角和配色，避免散落的魔法数字。
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
    // 普通事件可选的提醒偏移（单位：分钟，正数表示提前）。
    private static let appleCalendarReminderOffsets: [Int] = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080]
    // 全天事件对应 Apple Calendar 的提醒选项（含当天和跨天偏移）。
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
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.simplified.rawValue

    private let scheduler = LunarScheduler()
    private let adapter = EventKitAdapter()
    @FocusState private var focusedField: FocusField?

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .simplified
    }

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
            .environment(\.locale, appLanguage.locale)
            .navigationTitle(localized("LunarSmart 农历日程"))
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    languageToolbarMenu
                }
                #else
                ToolbarItem(placement: .automatic) {
                    languageToolbarPickerMac
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
            #if os(iOS)
            GeometryReader { proxy in
                let chipSpacing: CGFloat = 8
                let chipWidth = max(92, floor((proxy.size.width - chipSpacing * 2) / 3))
                HStack(spacing: chipSpacing) {
                    overviewChip(
                        title: "规则类型",
                        value: activeRuleId == nil ? "新建规则" : "编辑已有规则",
                        systemImage: "square.and.pencil",
                        tint: DesignTokens.Colors.brandBlue,
                        compact: true,
                        fixedWidth: chipWidth
                    )
                    overviewChip(
                        title: "目标",
                        value: targetType.label(language: appLanguage),
                        systemImage: "target",
                        tint: .teal,
                        compact: true,
                        fixedWidth: chipWidth
                    )
                    overviewChip(
                        title: "重复方式",
                        value: repeatMode.label(language: appLanguage),
                        systemImage: "repeat",
                        tint: .orange,
                        compact: true,
                        fixedWidth: chipWidth
                    )
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
            .frame(height: 88)
            #else
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
                        value: targetType.label(language: appLanguage),
                        systemImage: "target",
                        tint: .teal
                    )
                    overviewChip(
                        title: "重复方式",
                        value: repeatMode.label(language: appLanguage),
                        systemImage: "repeat",
                        tint: .orange
                    )
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
            #endif
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
                        Text(kind.label(language: appLanguage)).tag(kind)
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

    private var languageToolbarMenu: some View {
        Menu {
            Picker("", selection: $appLanguageRawValue) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language.rawValue)
                }
            }
        } label: {
            Text(appLanguage.shortLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
        }
        .accessibilityLabel("语言")
    }

    #if os(macOS)
    private var languageToolbarPickerMac: some View {
        Picker("", selection: $appLanguageRawValue) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.label).tag(language.rawValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 110)
        .accessibilityLabel("语言")
    }
    #endif

    private var lunarSettingsCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("农历规则")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("重复", selection: $repeatMode) {
                ForEach(LunarRepeatMode.allCases) { mode in
                    Text(mode.label(language: appLanguage)).tag(mode)
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
                            Text(mode.label(language: appLanguage)).tag(mode)
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
                    Text(policy.label(language: appLanguage)).tag(policy)
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
        #if os(iOS)
        VStack(spacing: 0) {
            savedRulesHeaderIOS
            Divider()
            ForEach(Array(ruleStore.rules.enumerated()), id: \.element.id) { index, rule in
                savedRuleRowIOS(rule, isStriped: index.isMultiple(of: 2))
                if index < ruleStore.rules.count - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lunarCardShape.fill(DesignTokens.Colors.cardBackground))
        .overlay(
            lunarCardShape
                .stroke(DesignTokens.Colors.neutralGray.opacity(0.18), lineWidth: 1)
        )
        .clipShape(lunarCardShape)
        .padding(.vertical, DesignTokens.Spacing.xs)
        #else
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
        #endif
    }

    #if os(iOS)
    // iOS 使用紧凑三列表格，确保宽度贴合屏幕。
    private var savedRulesHeaderIOS: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("标题")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("规则信息")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("操作")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .center)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.neutralGray.opacity(0.1))
    }

    private func savedRuleRowIOS(_ rule: StoredRule, isStriped: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(rule.type.label(language: appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(rule.repeatMode.label(language: appLanguage)) · \(rule.spec.displayText(language: appLanguage))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("关联 \(rule.occurrences.count) 条 · \(formattedUpdatedAt(rule.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("载入") {
                    load(rule)
                }
                Button("删除", role: .destructive) {
                    Task {
                        await deleteRule(rule)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Colors.brandBlue)
                    .frame(width: 40, height: 32)
            }
            .frame(width: 56, alignment: .center)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            activeRuleId == rule.id
            ? DesignTokens.Colors.brandBlue.opacity(0.15)
            : (isStriped ? DesignTokens.Colors.neutralGray.opacity(0.05) : Color.clear)
        )
    }
    #endif

    // 已保存规则表头。
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

    // 表格最小宽度，避免列挤压后可读性下降。
    private var savedRulesTableMinWidth: CGFloat {
        let columnWidths: CGFloat = 140 + 70 + 80 + 100 + 80 + 110 + 110
        let columnSpacings: CGFloat = 10 * 6
        let horizontalPadding: CGFloat = 24
        return columnWidths + columnSpacings + horizontalPadding
    }

    // 单条规则行，包含载入与删除操作。
    private func savedRuleRow(_ rule: StoredRule, isStriped: Bool) -> some View {
        HStack(spacing: 10) {
            tableDataCell(rule.title, width: 140, alignment: .leading, emphasized: true)
            tableDataCell(rule.type.label(language: appLanguage), width: 70, alignment: .leading)
            tableDataCell(rule.repeatMode.label(language: appLanguage), width: 80, alignment: .leading)
            tableDataCell(rule.spec.displayText(language: appLanguage), width: 100, alignment: .leading)
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

    // 表头单元格样式。
    private func tableHeaderCell(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(localized(text))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    @ViewBuilder
    // 表体单元格样式（可选强调和等宽数字）。
    private func tableDataCell(
        _ text: String,
        width: CGFloat,
        alignment: Alignment,
        emphasized: Bool = false,
        monospacedDigits: Bool = false
    ) -> some View {
        if monospacedDigits {
            Text(localized(text))
                .font(emphasized ? .body.weight(.semibold) : .caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .monospacedDigit()
                .frame(width: width, alignment: alignment)
        } else {
            Text(localized(text))
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
                    previewMetaItem(title: "规则", value: repeatMode.label(language: appLanguage))
                    previewMetaItem(title: "目标", value: targetType.label(language: appLanguage))
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

    // 去除前后空白后的标题，用于校验与保存。
    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 标题非空才允许保存规则。
    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    // 年份选择范围：当前年向前 5 年、向后 10 年。
    private var yearOptions: [Int] {
        Array((gregorianYear - 5)...(gregorianYear + 10))
    }

    // 将界面选择组装成农历规则。
    private var spec: LunarSpec {
        LunarSpec(month: lunarMonth, day: lunarDay, isLeapMonth: isLeapMonth)
    }

    // 保证“闰月开关”与重复模式、包含闰月策略保持一致。
    private func enforceLeapSelectionConsistency() {
        if (repeatMode == .monthly || repeatMode == .yearly)
            && !includeLeapMonthsForMonthlyRepeat
            && isLeapMonth {
            isLeapMonth = false
        }
    }

    // 保证重复结束参数合法，避免次数或结束日期越界。
    private func enforceRepeatEndConsistency() {
        if repeatEndCount < 1 {
            repeatEndCount = 1
        }
        if repeatEndDate < startDateForSelectedYear {
            repeatEndDate = startDateForSelectedYear
        }
    }

    // 根据当前表单配置刷新预览日期列表。
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
    // 创建或更新系统日历/提醒，并持久化当前规则。
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
    // 删除规则及其对应的系统条目。
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

    // 把已保存规则回填到编辑器，用于二次编辑。
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

    // 重置当前编辑上下文（新 ruleId、清空编辑态标记）。
    private func resetRuleEditor() {
        ruleId = UUID().uuidString
        activeRuleId = nil
        resultMessage = ""
        refreshPreview()
    }

    // 清空所有输入字段并恢复默认值。
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

    // 将“时:分”拼接到今天日期上，供时间选择器回显。
    private func makeTime(hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        let now = Date()
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        return cal.date(from: components) ?? now
    }

    // 普通事件提醒偏移文案。
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

    // 全天事件提醒偏移文案（对齐 Apple Calendar 语义）。
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

    // 当前所选公历年的首日，用于结束日期下限。
    private var startDateForSelectedYear: Date {
        let calendar = Calendar.current
        return calendar.date(from: DateComponents(year: gregorianYear, month: 1, day: 1)) ?? Date()
    }

    // 公历日期展示格式。
    private func formattedSolar(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = appLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // 统一 section 标题样式。
    private func sectionTitle(_ text: String) -> some View {
        Text(localized(text))
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    // 顶部概览卡片。
    private func overviewChip(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        compact: Bool = false,
        fixedWidth: CGFloat? = nil
    ) -> some View {
        let contentSpacing: CGFloat = compact ? 4 : 6
        let rowSpacing: CGFloat = compact ? 4 : 6
        let horizontalPadding: CGFloat = compact ? 10 : DesignTokens.Spacing.sm
        let verticalPadding: CGFloat = compact ? 8 : DesignTokens.Spacing.sm
        return VStack(alignment: .leading, spacing: contentSpacing) {
            HStack(spacing: rowSpacing) {
                Image(systemName: systemImage)
                    .font(compact ? .caption : .body)
                    .foregroundStyle(tint)
                Text(localized(title))
                    .font(compact ? .caption2 : .caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Text(localized(value))
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)
                .minimumScaleFactor(compact ? 0.72 : 0.9)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(width: fixedWidth, alignment: .leading)
        .frame(minWidth: compact ? 0 : 140, alignment: .leading)
        .background(lunarCardShape.fill(.ultraThinMaterial))
        .overlay(
            lunarCardShape
                .stroke(tint.opacity(0.26), lineWidth: 1)
        )
    }

    // 预览区的键值信息块。
    private func previewMetaItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localized(title))
                .foregroundStyle(.secondary)
            Text(localized(value))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    // 简繁切换：简体保持原文，繁体使用系统转换。
    private func localized(_ simplified: String) -> String {
        guard appLanguage == .traditional else { return simplified }
        return simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified
    }

    private var lunarCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
    }

    // 农历日期展示格式。
    private func formattedLunar(_ date: Date) -> String {
        guard let detail = lunarDetail(for: date) else {
            let fallback = DateFormatter()
            fallback.calendar = Calendar(identifier: .chinese)
            fallback.locale = appLanguage.locale
            fallback.timeZone = .current
            fallback.dateFormat = "r年M月d日"
            return fallback.string(from: date)
        }
        let leapPrefix = detail.isLeapMonth ? (appLanguage == .traditional ? "閏" : "闰") : ""
        return "\(leapPrefix)\(detail.month)月\(detail.day)日"
    }

    // 判断某个日期是否落在农历闰月。
    private func isLunarLeapMonth(_ date: Date) -> Bool {
        lunarDetail(for: date)?.isLeapMonth == true
    }

    // 汇总预览区中出现的闰月信息，供用户确认规则影响。
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

    // 读取某日的农历月、日和闰月标记。
    private func lunarDetail(for date: Date) -> (month: Int, day: Int, isLeapMonth: Bool)? {
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.timeZone = .current
        let comp = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: date)
        guard let month = comp.month, let day = comp.day else { return nil }
        return (month, day, comp.isLeapMonth ?? false)
    }

    // 规则更新时间展示格式。
    private func formattedUpdatedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = appLanguage.locale
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

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplified
    case traditional

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .simplified:
            return "简"
        case .traditional:
            return "繁"
        }
    }

    var label: String {
        switch self {
        case .simplified:
            return "简体中文"
        case .traditional:
            return "繁體中文"
        }
    }

    var locale: Locale {
        switch self {
        case .simplified:
            return Locale(identifier: "zh_Hans")
        case .traditional:
            return Locale(identifier: "zh_Hant")
        }
    }
}

private extension View {
    @ViewBuilder
    // iOS 上按句首自动大写；macOS 保持原样。
    func lunarAutocapSentences() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.sentences)
        #else
        self
        #endif
    }

    @ViewBuilder
    // iOS 上按单词自动大写；macOS 保持原样。
    func lunarAutocapWords() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    // 通用卡片样式（毛玻璃底 + 细描边）。
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

    // 通用输入框样式。
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

// 创建目标类型：系统日程或系统提醒。
enum TargetType: String, CaseIterable, Identifiable, Codable {
    case event
    case reminder

    var id: String { rawValue }

    var label: String { label(language: .simplified) }

    func label(language: AppLanguage) -> String {
        switch (self, language) {
        case (.event, .simplified): return "日程"
        case (.event, .traditional): return "日程"
        case (.reminder, .simplified): return "提醒"
        case (.reminder, .traditional): return "提醒事項"
        }
    }
}

// 农历重复方式：一次、按月、按年。
enum LunarRepeatMode: String, CaseIterable, Identifiable, Codable {
    case none
    case monthly
    case yearly

    var id: String { rawValue }

    var label: String { label(language: .simplified) }

    func label(language: AppLanguage) -> String {
        switch (self, language) {
        case (.none, .simplified): return "不重复"
        case (.none, .traditional): return "不重複"
        case (.monthly, .simplified): return "按农历月"
        case (.monthly, .traditional): return "按農曆月"
        case (.yearly, .simplified): return "按农历年"
        case (.yearly, .traditional): return "按農曆年"
        }
    }
}

// 重复结束条件：按次数或按日期。
enum RepeatEndMode: String, CaseIterable, Identifiable, Codable {
    case afterOccurrences
    case onDate

    var id: String { rawValue }

    var label: String { label(language: .simplified) }

    func label(language: AppLanguage) -> String {
        switch (self, language) {
        case (.afterOccurrences, .simplified): return "于"
        case (.afterOccurrences, .traditional): return "於"
        case (.onDate, .simplified): return "于日期"
        case (.onDate, .traditional): return "於日期"
        }
    }
}

// 当目标农历日在某月不存在时的处理策略。
enum MissingDayStrategy: String, CaseIterable, Identifiable, Codable {
    case skip
    case fallbackToMonthEnd

    var id: String { rawValue }

    var label: String { label(language: .simplified) }

    func label(language: AppLanguage) -> String {
        switch (self, language) {
        case (.skip, .simplified): return "跳过该月"
        case (.skip, .traditional): return "跳過該月"
        case (.fallbackToMonthEnd, .simplified): return "顺延到当月最后一天"
        case (.fallbackToMonthEnd, .traditional): return "順延到當月最後一天"
        }
    }
}

// 农历规则定义（月、日、是否闰月）。
struct LunarSpec: Codable {
    let month: Int
    let day: Int
    let isLeapMonth: Bool

    func displayText(language: AppLanguage = .simplified) -> String {
        let leapText = isLeapMonth ? (language == .traditional ? "閏" : "闰") : ""
        return "农历\(leapText)\(month)月\(day)日"
    }
}

// 规则与系统条目的映射记录。
struct StoredOccurrence: Codable, Identifiable {
    let occKey: String
    let calendarItemIdentifier: String

    var id: String { "\(occKey)-\(calendarItemIdentifier)" }
}

// 规则持久化模型。
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
        // 规则文件固定保存在 Application Support/LunarSmart/rules.json。
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LunarSmart", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("rules.json")
        load()
    }

    // 按 ID 查询规则。
    func rule(by id: String) -> StoredRule? {
        rules.first(where: { $0.id == id })
    }

    // 新增或更新规则。
    func upsert(_ rule: StoredRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.insert(rule, at: 0)
        }
        save()
    }

    // 删除规则。
    func delete(ruleID: String) {
        rules.removeAll { $0.id == ruleID }
        save()
    }

    // 从磁盘加载规则。
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([StoredRule].self, from: data) {
            rules = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    // 将规则写入磁盘。
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// 同步到 EventKit 所需的输入参数。
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

// 一次同步执行后的统计结果。
struct SyncResult {
    let created: Int
    let updated: Int
    let deleted: Int
    let skipped: Int
    let items: [StoredOccurrence]
}

// 调度层：负责组合农历引擎与重复结束策略。
final class LunarScheduler {
    private let engine = LunarEngine()

    // 生成预览用日期集合。
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
        // 预览需要更大的窗口，以便用户提前看到后续日期走势。
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

    // 生成实际落库用日期集合。
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
        // 实际创建只生成必要条目，避免一次写入过多系统日历数据。
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

    // 预览窗口策略（为了可视化会适当放大）。
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

    // 创建窗口策略（只取必要范围）。
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

    // 应用“按次数/按日期结束重复”的裁剪规则。
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

// 一段连续农历月份的数据块。
struct LunarMonthBlock {
    let lunarYear: Int
    let lunarMonth: Int
    let isLeapMonth: Bool
    let days: [Date]

    // 在当前月块中取目标农历日，必要时可退到月末。
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

// 农历计算引擎：负责从规则推导公历日期序列。
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

    // 按重复模式生成候选日期。
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

    // 计算某公历年内首个匹配日期。
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

    // 计算某公历年内所有匹配日期（可选包含对应闰月）。
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

    // 以锚点日期向后逐月扩展日期序列。
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
        // 按“农历年-月-闰月标记”连续切块，方便按月定位目标农历日。
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

// EventKit 适配层：负责权限、查找、增删改提交。
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

    // 同步一条规则到系统条目（创建/更新/删除）。
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

    // 批量删除已有系统条目。
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

    // 计算需要扫描系统条目的时间区间。
    private func makeDateRange(for occurrences: [Date]) -> (start: Date, end: Date) {
        let minDate = occurrences.min() ?? Date()
        let maxDate = occurrences.max() ?? minDate
        let start = gregorian.startOfDay(for: minDate)
        let end = gregorian.date(byAdding: .day, value: 1, to: gregorian.startOfDay(for: maxDate)) ?? maxDate
        return (start, end)
    }

    // 从系统条目中提取“发生键 -> 条目标识符”的映射。
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

    // 异步拉取提醒事项列表。
    private func fetchReminders(predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // 创建一条系统日程或提醒。
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

    // 更新已存在的系统日程或提醒。
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

    // 删除单条系统日程或提醒。
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

    // 将业务请求映射到 EKEvent 字段。
    private func apply(event: EKEvent, request: CreateRequest, date: Date) {
        event.title = request.title
        event.location = request.location
        event.notes = request.notes
        // 事件不写入 URL，避免污染 Apple Calendar 的“添加 URL”字段。
        event.url = nil

        if request.isAllDay {
            let bounds = allDayBounds(for: date)
            event.isAllDay = true
            // 全天事件使用浮动时区（nil），让系统按“日期条目”而非“具体时刻”处理。
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

    // 将业务请求映射到 EKReminder 字段。
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

    // 把提醒偏移分钟转换为 EventKit 相对秒数。
    private func alarmRelativeOffset(for request: CreateRequest) -> TimeInterval? {
        guard request.reminderOffsetMinutes != 0 else { return nil }
        // reminderOffsetMinutes 记录“开始前多少分钟”；负数表示“开始后多少分钟”。
        return TimeInterval(-request.reminderOffsetMinutes * 60)
    }

    // 发生日期键，格式 yyyy-MM-dd。
    private func occurrenceKey(for date: Date) -> String {
        occFormatter.string(from: date)
    }

    // 生成写入系统条目的规则标记 URL。
    private func markerURL(ruleId: String, occKey: String) -> URL? {
        // 用自定义 URL 回写规则 ID 和发生日期，后续同步可稳定定位已有条目。
        var comps = URLComponents()
        comps.scheme = "lunarsmart"
        comps.host = "rule"
        comps.path = "/\(ruleId)"
        comps.queryItems = [URLQueryItem(name: "occ", value: occKey)]
        return comps.url
    }

    // 从 URL 或兼容的 notes 标记中解析发生日期键。
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

    // 合并“日期部分 + 时间部分”为最终触发时间。
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

    // 计算全天事项的起止边界。
    private func allDayBounds(for date: Date) -> (start: Date, end: Date) {
        var local = gregorian
        local.timeZone = .current
        var day = local.dateComponents([.year, .month, .day], from: date)
        day.hour = 0
        day.minute = 0
        day.second = 0
        let start = local.date(from: day) ?? local.startOfDay(for: date)
        // 结束时间与开始时间同日，匹配 Calendar.app 对单日全天事项的编辑行为。
        let end = start
        return (start, end)
    }

    // 请求系统日历权限。
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

    // 请求系统提醒事项权限。
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

// 业务层统一错误类型。
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
