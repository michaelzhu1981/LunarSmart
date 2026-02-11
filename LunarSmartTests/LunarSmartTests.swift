import Foundation
import Testing
@testable import LunarSmart

struct LunarSmartTests {
    private func lunarComponents(for date: Date) -> DateComponents {
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = .current
        return lunar.dateComponents([.month, .day, .isLeapMonth], from: date)
    }

    @Test
    func monthlyRepeatExcludingLeapMonthsUsesNonLeapAnchor() throws {
        let engine = LunarEngine()
        let dates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 2, day: 1, isLeapMonth: true),
            repeatMode: .monthly,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: false,
            monthlyWindowCount: 6,
            yearlyWindowCount: 1
        )

        let first = try #require(dates.first)
        let comp = lunarComponents(for: first)
        #expect(comp.month == 2)
        #expect(comp.day == 1)
        #expect(comp.isLeapMonth == false)
    }

    @Test
    func monthlyRepeatIncludingLeapMonthsCanAnchorLeapMonth() throws {
        let engine = LunarEngine()
        let dates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 2, day: 1, isLeapMonth: true),
            repeatMode: .monthly,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: true,
            monthlyWindowCount: 6,
            yearlyWindowCount: 1
        )

        let first = try #require(dates.first)
        let comp = lunarComponents(for: first)
        #expect(comp.month == 2)
        #expect(comp.day == 1)
        #expect(comp.isLeapMonth == true)
    }

    @Test
    func oneTimeRuleStillRespectsLeapMonthSelection() throws {
        let engine = LunarEngine()
        let dates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 2, day: 1, isLeapMonth: true),
            repeatMode: .none,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: false,
            monthlyWindowCount: 1,
            yearlyWindowCount: 1
        )

        let first = try #require(dates.first)
        let comp = lunarComponents(for: first)
        #expect(comp.month == 2)
        #expect(comp.day == 1)
        #expect(comp.isLeapMonth == true)
    }

    @Test
    func monthlyRepeatIncludingLeapMonthsContainsLeapMonthOccurrence() throws {
        let engine = LunarEngine()
        let includeLeapDates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 1, day: 1, isLeapMonth: false),
            repeatMode: .monthly,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: true,
            monthlyWindowCount: 20,
            yearlyWindowCount: 1
        )
        let excludeLeapDates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 1, day: 1, isLeapMonth: false),
            repeatMode: .monthly,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: false,
            monthlyWindowCount: 20,
            yearlyWindowCount: 1
        )

        #expect(includeLeapDates.contains { lunarComponents(for: $0).isLeapMonth == true })
        #expect(excludeLeapDates.allSatisfy { lunarComponents(for: $0).isLeapMonth != true })
    }

    @Test
    func yearlyRepeatIncludingLeapMonthsContainsLeapMonthOccurrence() throws {
        let engine = LunarEngine()
        let includeLeapDates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 2, day: 1, isLeapMonth: false),
            repeatMode: .yearly,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: true,
            monthlyWindowCount: 1,
            yearlyWindowCount: 8
        )
        let excludeLeapDates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 2, day: 1, isLeapMonth: false),
            repeatMode: .yearly,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: false,
            monthlyWindowCount: 1,
            yearlyWindowCount: 8
        )

        #expect(includeLeapDates.contains { lunarComponents(for: $0).isLeapMonth == true })
        #expect(excludeLeapDates.allSatisfy { lunarComponents(for: $0).isLeapMonth != true })
    }

    @Test
    func previewMonthlyAfterOccurrencesMatchesRequestedCount() throws {
        let scheduler = LunarScheduler()
        let preview = try scheduler.previewOccurrences(
            startGregorianYear: 2026,
            spec: LunarSpec(month: 1, day: 1, isLeapMonth: false),
            repeatMode: .monthly,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: false,
            repeatEndMode: .afterOccurrences,
            repeatEndCount: 3,
            repeatEndDate: Date()
        )

        #expect(preview.count == 3)
    }

    @Test
    func crossYearMonthDoesNotShiftTargetLunarDay() throws {
        let engine = LunarEngine()
        let dates = try engine.occurrences(
            startGregorianYear: 2023,
            spec: LunarSpec(month: 12, day: 11, isLeapMonth: false),
            repeatMode: .none,
            missingDayStrategy: .skip,
            includeLeapMonthsForMonthlyRepeat: false,
            monthlyWindowCount: 1,
            yearlyWindowCount: 1
        )

        let first = try #require(dates.first)
        let comp = lunarComponents(for: first)
        #expect(comp.month == 12)
        #expect(comp.day == 11)
        #expect(comp.isLeapMonth == false)
    }
}
