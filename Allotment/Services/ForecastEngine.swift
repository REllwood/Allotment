import Foundation
import SwiftUI

enum ForecastStatus: String, Sendable {
    case over
    case trendingOver
    case onTrack
    case trendingUnder
    case under
    case unallocated

    var title: String {
        switch self {
        case .over: "Over allocation"
        case .trendingOver: "Trending over"
        case .onTrack: "On track"
        case .trendingUnder: "Trending under"
        case .under: "Under allocation"
        case .unallocated: "No allocation"
        }
    }

    var shortTitle: String {
        switch self {
        case .over: "Over"
        case .trendingOver: "Trending over"
        case .onTrack: "On track"
        case .trendingUnder: "Trending under"
        case .under: "Under"
        case .unallocated: "No allocation"
        }
    }

    var symbol: String {
        switch self {
        case .over: "exclamationmark.triangle.fill"
        case .trendingOver: "arrow.up.right"
        case .onTrack: "checkmark.circle.fill"
        case .trendingUnder: "arrow.down.right"
        case .under: "arrow.down.circle.fill"
        case .unallocated: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .over: .red
        case .trendingOver: .orange
        case .onTrack: .green
        case .trendingUnder, .under: .blue
        case .unallocated: .secondary
        }
    }
}

struct ClientForecast: Identifiable, Sendable {
    let client: Client
    let period: DateInterval
    let allocation: Double?
    let actual: Double
    let billable: Double
    let expectedToDate: Double?
    let projected: Double
    let workdaysTotal: Double
    let workdaysElapsed: Double
    let status: ForecastStatus

    var id: UUID { client.id }
    var isComplete: Bool { workdaysElapsed >= workdaysTotal }
    var remaining: Double? { allocation.map { $0 - actual } }

    /// Hours a day needed to land exactly on the allocation.
    var neededPerDay: Double? {
        guard let remaining, remaining > 0 else { return nil }
        let daysLeft = workdaysTotal - workdaysElapsed
        return daysLeft > 0.05 ? remaining / daysLeft : nil
    }

    var progress: Double {
        guard let allocation, allocation > 0 else { return 0 }
        return actual / allocation
    }

    /// Where actual time is compared with where it should be by now. Positive means ahead of plan.
    var paceVariance: Double? { expectedToDate.map { actual - $0 } }
    var projectedVariance: Double? { allocation.map { projected - $0 } }
}

struct PeriodActual: Identifiable, Sendable {
    let period: DateInterval
    let actual: Double
    let allocation: Double?
    var id: Date { period.start }
}

struct CapacitySummary: Sendable {
    let weeklyCapacity: Double
    let weeklyAllocated: Double
    var free: Double { weeklyCapacity - weeklyAllocated }
    var isOverbooked: Bool { weeklyAllocated > weeklyCapacity + 0.01 }
    var fraction: Double { weeklyCapacity > 0 ? weeklyAllocated / weeklyCapacity : 0 }
}

/// Compares time logged against each client's allocation and projects where the period will end.
struct ForecastEngine {
    let schedule: WorkSchedule
    let entries: [TimeEntry]
    let tolerance: Double

    @MainActor
    init(store: TimeStore) {
        schedule = store.schedule
        entries = store.entries
        tolerance = store.settings.tolerancePercent / 100
    }

    init(schedule: WorkSchedule, entries: [TimeEntry], tolerance: Double) {
        self.schedule = schedule
        self.entries = entries
        self.tolerance = tolerance
    }

    func forecast(for client: Client, period kind: AllocationPeriod? = nil, at now: Date = .now) -> ClientForecast {
        let kind = kind ?? client.allocationPeriod
        let period = schedule.period(kind, containing: now)
        let clientEntries = entries.filter { $0.clientID == client.id && period.contains($0.start) && $0.start < period.end }
        let actual = clientEntries.reduce(0) { $0 + $1.duration(at: now) } / 3600
        let billable = clientEntries.filter(\.isBillable).reduce(0) { $0 + $1.duration(at: now) } / 3600
        let total = Double(schedule.workdayCount(in: period))
        let elapsed = schedule.elapsedWorkdays(in: period, at: now)

        let allocation: Double? = if kind == client.allocationPeriod {
            client.allocationHours.flatMap { $0 > 0 ? $0 : nil }
        } else {
            schedule.allocatedHours(client, in: period)
        }

        let expected = allocation.map { total > 0 ? $0 * elapsed / total : 0 }
        let projected = Self.project(actual: actual, allocation: allocation, totalDays: total, elapsedDays: elapsed)
        let status = Self.status(actual: actual, projected: projected, allocation: allocation,
                                 isComplete: elapsed >= total, tolerance: tolerance)
        return ClientForecast(client: client, period: period, allocation: allocation, actual: actual, billable: billable,
                              expectedToDate: expected, projected: projected, workdaysTotal: total,
                              workdaysElapsed: elapsed, status: status)
    }

    func forecasts(for clients: [Client], period kind: AllocationPeriod? = nil, at now: Date = .now) -> [ClientForecast] {
        clients.map { forecast(for: $0, period: kind, at: now) }
    }

    /// Actual hours for the last `count` periods, oldest first, including the current one.
    func history(for client: Client, period kind: AllocationPeriod, count: Int, at now: Date = .now) -> [PeriodActual] {
        (0..<count).reversed().map { back in
            let period = schedule.period(kind, containing: now, offset: -back)
            let actual = entries
                .filter { $0.clientID == client.id && $0.start >= period.start && $0.start < period.end }
                .reduce(0) { $0 + $1.duration(at: now) } / 3600
            let allocation: Double? = kind == client.allocationPeriod
                ? client.allocationHours.flatMap { $0 > 0 ? $0 : nil }
                : schedule.allocatedHours(client, in: period)
            return PeriodActual(period: period, actual: actual, allocation: allocation)
        }
    }

    func capacity(for clients: [Client]) -> CapacitySummary {
        CapacitySummary(weeklyCapacity: schedule.weeklyCapacity,
                        weeklyAllocated: clients.reduce(0) { $0 + schedule.weeklyAllocation($1) })
    }

    // MARK: - Core maths

    /// Projects the end-of-period total. Early in a period the plan carries more weight than the pace so far,
    /// which stops a busy Monday morning from forecasting a 60 hour week.
    static func project(actual: Double, allocation: Double?, totalDays: Double, elapsedDays: Double) -> Double {
        guard totalDays > 0, elapsedDays < totalDays else { return actual }
        let remainingDays = totalDays - elapsedDays
        let paceRate = elapsedDays > 0 ? actual / elapsedDays : 0
        guard let allocation else { return actual + remainingDays * paceRate }
        let planRate = allocation / totalDays
        let weight = elapsedDays / totalDays
        let rate = weight * paceRate + (1 - weight) * planRate
        return actual + remainingDays * rate
    }

    static func status(actual: Double, projected: Double, allocation: Double?, isComplete: Bool, tolerance: Double) -> ForecastStatus {
        guard let allocation, allocation > 0 else { return .unallocated }
        let upper = allocation * (1 + tolerance)
        let lower = allocation * (1 - tolerance)
        if actual > upper { return .over }
        if isComplete { return actual < lower ? .under : .onTrack }
        if projected > upper { return .trendingOver }
        if projected < lower { return .trendingUnder }
        return .onTrack
    }
}
