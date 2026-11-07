import Foundation

/// Calendar maths for the user's working week: periods, working days and capacity.
struct WorkSchedule: Sendable {
    let calendar: Calendar
    let workdays: Set<Int>
    let dayStartMinutes: Int
    let dayEndMinutes: Int
    let weeklyCapacity: Double

    init(settings: AppSettings, calendar base: Calendar = .current) {
        var cal = base
        cal.firstWeekday = settings.firstWeekday
        calendar = cal
        // An empty working week would make every forecast divide by zero.
        workdays = settings.workdays.isEmpty ? [2, 3, 4, 5, 6] : settings.workdays
        dayStartMinutes = settings.workdayStartMinutes
        dayEndMinutes = max(settings.workdayEndMinutes, settings.workdayStartMinutes + 1)
        weeklyCapacity = settings.weeklyCapacityHours
    }

    var dailyTarget: Double { weeklyCapacity / Double(workdays.count) }

    func isWorkday(_ date: Date) -> Bool {
        workdays.contains(calendar.component(.weekday, from: date))
    }

    func day(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
    }

    func week(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }

    func month(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 30 * 86_400)
    }

    func period(_ kind: AllocationPeriod, containing date: Date) -> DateInterval {
        kind == .week ? week(containing: date) : month(containing: date)
    }

    /// The period `offset` steps before or after the one containing `date`.
    func period(_ kind: AllocationPeriod, containing date: Date, offset: Int) -> DateInterval {
        let component: Calendar.Component = kind == .week ? .weekOfYear : .month
        let shifted = calendar.date(byAdding: component, value: offset, to: period(kind, containing: date).start) ?? date
        return period(kind, containing: shifted)
    }

    /// The start of every day in the interval.
    func days(in interval: DateInterval) -> [Date] {
        var result: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    func workdayCount(in interval: DateInterval) -> Int {
        days(in: interval).filter(isWorkday).count
    }

    /// How much of today's working hours have passed, from 0 to 1.
    func fractionOfWorkdayElapsed(at now: Date) -> Double {
        let startOfDay = calendar.startOfDay(for: now)
        let minutes = now.timeIntervalSince(startOfDay) / 60
        let span = Double(dayEndMinutes - dayStartMinutes)
        return min(1, max(0, (minutes - Double(dayStartMinutes)) / span))
    }

    /// Working days that have passed in the interval, counting part of today.
    func elapsedWorkdays(in interval: DateInterval, at now: Date) -> Double {
        if now >= interval.end { return Double(workdayCount(in: interval)) }
        if now < interval.start { return 0 }
        let today = calendar.startOfDay(for: now)
        var elapsed = 0.0
        for day in days(in: interval) where isWorkday(day) {
            if day < today {
                elapsed += 1
            } else if day == today {
                elapsed += fractionOfWorkdayElapsed(at: now)
            }
        }
        return elapsed
    }

    func capacityHours(in interval: DateInterval) -> Double {
        Double(workdayCount(in: interval)) * dailyTarget
    }

    /// The share of a client's allocation that falls inside `interval`, spread evenly over working days.
    func allocatedHours(_ client: Client, in interval: DateInterval) -> Double? {
        guard let hours = client.allocationHours, hours > 0 else { return nil }
        var total = 0.0
        var cursor = interval.start
        while cursor < interval.end {
            let period = period(client.allocationPeriod, containing: cursor)
            let periodDays = Double(workdayCount(in: period))
            if let overlap = period.intersection(with: interval), periodDays > 0 {
                total += hours * Double(workdayCount(in: overlap)) / periodDays
            }
            guard period.end > cursor else { break }
            cursor = period.end
        }
        return total
    }

    /// The allocation for the part of `interval` that has already happened, counting part of today.
    func allocatedHoursToDate(_ client: Client, in interval: DateInterval, at now: Date) -> Double? {
        guard now > interval.start, now < interval.end else { return allocatedHours(client, in: interval) }
        let today = day(containing: now)
        let before = DateInterval(start: interval.start, end: max(interval.start, today.start))
        let past = before.duration > 0 ? allocatedHours(client, in: before) : 0
        guard let past else { return nil }
        let todayShare = isWorkday(now) ? (allocatedHours(client, in: today) ?? 0) * fractionOfWorkdayElapsed(at: now) : 0
        return past + todayShare
    }

    /// A client's allocation expressed per week, so weekly and monthly allocations can be compared.
    func weeklyAllocation(_ client: Client) -> Double {
        guard let hours = client.allocationHours, hours > 0 else { return 0 }
        return client.allocationPeriod == .week ? hours : hours * 12 / 52
    }
}
