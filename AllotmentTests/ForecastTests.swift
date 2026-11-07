import Foundation
import Testing
@testable import Allotment

/// Fixed dates in a fixed time zone, so results do not depend on when or where the tests run.
enum Fixture {
    static let timeZone = TimeZone(identifier: "Europe/London")!

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// A date on this Mac's own calendar, for tests that go through the store.
    static func localDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static var schedule: WorkSchedule { WorkSchedule(settings: AppSettings(), calendar: calendar) }
}

struct WorkScheduleTests {
    let schedule = Fixture.schedule

    @Test func weekStartsOnMonday() {
        // Wednesday 4 November 2026.
        let week = schedule.week(containing: Fixture.date(2026, 11, 4, 12))
        #expect(week.start == Fixture.date(2026, 11, 2))
        #expect(week.end == Fixture.date(2026, 11, 9))
        #expect(schedule.workdayCount(in: week) == 5)
    }

    @Test func elapsedWorkdaysCountsPartOfToday() {
        let week = schedule.week(containing: Fixture.date(2026, 11, 4))
        // Monday and Tuesday are done, and Wednesday at 13:15 is half way through 9:00 to 17:30.
        let elapsed = schedule.elapsedWorkdays(in: week, at: Fixture.date(2026, 11, 4, 13, 15))
        #expect(abs(elapsed - 2.5) < 0.001)
        // A weekend morning counts every working day in the week as elapsed.
        #expect(schedule.elapsedWorkdays(in: week, at: Fixture.date(2026, 11, 7, 10)) == 5)
    }

    @Test func monthlyAllocationSpreadsAcrossWorkingDays() {
        let client = Client(name: "Northwind", colorHex: "#10B981", allocationHours: 42, allocationPeriod: .month)
        // November 2026 has 21 working days, so each one is worth 2 hours.
        let week = schedule.week(containing: Fixture.date(2026, 11, 4))
        #expect(abs((schedule.allocatedHours(client, in: week) ?? 0) - 10) < 0.001)
        #expect(abs(schedule.weeklyAllocation(client) - 42 * 12 / 52) < 0.001)
    }

    @Test func allocationToDateUsesPartOfToday() {
        let client = Client(name: "Acme", colorHex: "#3B82F6", allocationHours: 20, allocationPeriod: .week)
        let week = schedule.week(containing: Fixture.date(2026, 11, 4))
        let toDate = schedule.allocatedHoursToDate(client, in: week, at: Fixture.date(2026, 11, 4, 13, 15)) ?? 0
        // 4 hours a day, for 2.5 days.
        #expect(abs(toDate - 10) < 0.001)
    }
}

struct ForecastMathTests {
    @Test func projectionLeansOnThePlanEarlyInThePeriod() {
        // Four hours by mid-morning Monday would naively extrapolate to an 80 hour week.
        let early = ForecastEngine.project(actual: 4, allocation: 16, totalDays: 5, elapsedDays: 0.25)
        // Instead it stays close to "what you have done plus the plan for the rest of the week" (19.2 hours).
        #expect(early > 19.2 && early < 25)
        // At the very end the projection is the actual total.
        #expect(ForecastEngine.project(actual: 18, allocation: 16, totalDays: 5, elapsedDays: 5) == 18)
    }

    @Test func projectionFollowsPaceLateInThePeriod() {
        let late = ForecastEngine.project(actual: 16, allocation: 16, totalDays: 5, elapsedDays: 4)
        // Pace is 4 hours a day and the plan 3.2, blended 80:20, over one remaining day.
        #expect(abs(late - (16 + 0.8 * 4 + 0.2 * 3.2)) < 0.001)
    }

    @Test(arguments: [
        (actual: 20.0, projected: 20.0, complete: false, expected: ForecastStatus.over),
        (actual: 10.0, projected: 19.0, complete: false, expected: .trendingOver),
        (actual: 8.0, projected: 16.5, complete: false, expected: .onTrack),
        (actual: 4.0, projected: 12.0, complete: false, expected: .trendingUnder),
        (actual: 12.0, projected: 12.0, complete: true, expected: .under),
        (actual: 15.0, projected: 15.0, complete: true, expected: .onTrack),
    ])
    func statusAgainstSixteenHours(actual: Double, projected: Double, complete: Bool, expected: ForecastStatus) {
        #expect(ForecastEngine.status(actual: actual, projected: projected, allocation: 16, isComplete: complete, tolerance: 0.1) == expected)
    }

    @Test func noAllocationIsUnallocated() {
        #expect(ForecastEngine.status(actual: 5, projected: 9, allocation: nil, isComplete: false, tolerance: 0.1) == .unallocated)
    }

    @Test func forecastAddsUpEntriesForTheClient() {
        let acme = Client(name: "Acme", colorHex: "#3B82F6", allocationHours: 16, allocationPeriod: .week)
        let other = UUID()
        let entries = [
            TimeEntry(clientID: acme.id, start: Fixture.date(2026, 11, 2, 9), end: Fixture.date(2026, 11, 2, 13), isBillable: true),
            TimeEntry(clientID: acme.id, start: Fixture.date(2026, 11, 3, 9), end: Fixture.date(2026, 11, 3, 12), isBillable: false),
            TimeEntry(clientID: other, start: Fixture.date(2026, 11, 3, 13), end: Fixture.date(2026, 11, 3, 17), isBillable: true),
            // Last week, so outside the period.
            TimeEntry(clientID: acme.id, start: Fixture.date(2026, 10, 30, 9), end: Fixture.date(2026, 10, 30, 17), isBillable: true),
        ]
        let engine = ForecastEngine(schedule: Fixture.schedule, entries: entries, tolerance: 0.1)
        let forecast = engine.forecast(for: acme, at: Fixture.date(2026, 11, 4, 9))
        #expect(forecast.actual == 7)
        #expect(forecast.billable == 4)
        #expect(forecast.allocation == 16)
        #expect(abs((forecast.expectedToDate ?? 0) - 6.4) < 0.001)
        #expect(forecast.status == .onTrack)
    }
}
