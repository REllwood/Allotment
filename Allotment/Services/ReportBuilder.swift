import Foundation

enum BillableFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case billable
    case nonBillable

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All time"
        case .billable: "Billable only"
        case .nonBillable: "Non-billable only"
        }
    }
}

struct ReportFilter: Hashable, Sendable {
    var interval: DateInterval
    /// `nil` includes every client and time with no client.
    var clientIDs: Set<UUID>?
    var billable: BillableFilter = .all
}

/// One time entry with every name resolved, ready to display or export.
struct ReportRow: Identifiable, Sendable {
    let id: UUID
    let start: Date
    let end: Date?
    let clientID: UUID?
    let clientName: String
    let clientColorHex: String
    let projectName: String
    let activityName: String
    let isAdmin: Bool
    let notes: String
    let isBillable: Bool
    let hours: Double
    let rate: Double
    let source: EntrySource

    var amount: Double { isBillable ? hours * rate : 0 }
    var isRunning: Bool { end == nil }
}

struct ReportGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    var hours: Double = 0
    var billableHours: Double = 0
    var amount: Double = 0
    var entryCount = 0
    /// Allocated hours for the report period, for clients with an allocation.
    var allocated: Double?

    var variance: Double? { allocated.map { hours - $0 } }
}

struct ReportDay: Identifiable, Sendable {
    let date: Date
    var hours: Double = 0
    var byClient: [String: Double] = [:]
    var id: Date { date }
}

struct Report: Sendable {
    let filter: ReportFilter
    let generatedAt: Date
    let rows: [ReportRow]
    let byClient: [ReportGroup]
    let byProject: [ReportGroup]
    let byActivity: [ReportGroup]
    let days: [ReportDay]
    let capacityHours: Double
    /// Capacity for the part of the period that has passed. Equals `capacityHours` for finished periods.
    let capacityToDate: Double
    /// True while the period is still under way, so allocations are compared to date rather than in full.
    let isInProgress: Bool
    /// How far over an allocation still counts as on track, as a fraction.
    let tolerance: Double
    let currencyCode: String
    let rounding: RoundingRule
    let userName: String
    /// The client name when the report covers exactly one client.
    let singleClientName: String?

    var totalHours: Double { rows.reduce(0) { $0 + $1.hours } }
    var billableHours: Double { rows.filter(\.isBillable).reduce(0) { $0 + $1.hours } }
    var nonBillableHours: Double { totalHours - billableHours }
    var adminHours: Double { rows.filter(\.isAdmin).reduce(0) { $0 + $1.hours } }
    var amount: Double { rows.reduce(0) { $0 + $1.amount } }
    var utilization: Double { capacityToDate > 0 ? billableHours / capacityToDate : 0 }
    func isOver(_ group: ReportGroup) -> Bool {
        guard let variance = group.variance, let allocated = group.allocated else { return false }
        return variance > allocated * tolerance
    }

    func isUnder(_ group: ReportGroup) -> Bool {
        guard let variance = group.variance, let allocated = group.allocated else { return false }
        return variance < -allocated * tolerance
    }

    var allocationLabel: String { isInProgress ? "Allocated to date" : "Allocated hours" }
    var billableShare: Double { totalHours > 0 ? billableHours / totalHours : 0 }
    var hasRates: Bool { rows.contains { $0.rate > 0 && $0.isBillable } }

    var title: String {
        if let singleClientName { return "Timesheet for \(singleClientName)" }
        return "Timesheet"
    }
}

enum ReportBuilder {
    static let noClientName = "No client"

    @MainActor
    static func build(_ filter: ReportFilter, store: TimeStore, now: Date = .now) -> Report {
        let settings = store.settings
        let schedule = store.schedule
        let entries = store.entries(in: filter.interval).filter { entry in
            if let ids = filter.clientIDs {
                guard let clientID = entry.clientID, ids.contains(clientID) else { return false }
            }
            switch filter.billable {
            case .all: return true
            case .billable: return entry.isBillable
            case .nonBillable: return !entry.isBillable
            }
        }

        let rows = entries.map { entry -> ReportRow in
            let client = store.client(entry.clientID)
            let activity = store.activity(entry.activityID)
            return ReportRow(
                id: entry.id,
                start: entry.start,
                end: entry.end,
                clientID: entry.clientID,
                clientName: client?.name ?? noClientName,
                clientColorHex: client?.colorHex ?? Palette.internalHex,
                projectName: store.project(entry.projectID)?.name ?? "",
                activityName: activity?.name ?? "",
                isAdmin: activity?.isAdmin ?? false,
                notes: entry.notes,
                isBillable: entry.isBillable,
                hours: settings.rounding.apply(entry.duration(at: now)) / 3600,
                rate: store.rate(for: entry.clientID),
                source: entry.source
            )
        }

        var clientGroups: [String: ReportGroup] = [:]
        var projectGroups: [String: ReportGroup] = [:]
        var activityGroups: [String: ReportGroup] = [:]
        func add(_ row: ReportRow, to groups: inout [String: ReportGroup], key: String, name: String, color: String) {
            var group = groups[key] ?? ReportGroup(id: key, name: name, colorHex: color)
            group.hours += row.hours
            group.amount += row.amount
            group.entryCount += 1
            if row.isBillable { group.billableHours += row.hours }
            groups[key] = group
        }
        for row in rows {
            let clientKey = row.clientID?.uuidString ?? "none"
            add(row, to: &clientGroups, key: clientKey, name: row.clientName, color: row.clientColorHex)
            let projectName = row.projectName.isEmpty ? "\(row.clientName), no project" : "\(row.clientName): \(row.projectName)"
            add(row, to: &projectGroups, key: "\(clientKey)|\(row.projectName)", name: projectName, color: row.clientColorHex)
            let activityName = row.activityName.isEmpty ? "No activity" : row.activityName
            add(row, to: &activityGroups, key: activityName, name: activityName, color: row.isAdmin ? Palette.internalHex : "#5E5CE6")
        }

        // Show every allocated client in the period, even with no time yet, so under-delivery is visible.
        let isInProgress = now > filter.interval.start && now < filter.interval.end
        for client in store.activeClients where filter.clientIDs?.contains(client.id) ?? true {
            guard let allocated = schedule.allocatedHoursToDate(client, in: filter.interval, at: now) else { continue }
            let key = client.id.uuidString
            var group = clientGroups[key] ?? ReportGroup(id: key, name: client.name, colorHex: client.colorHex)
            group.allocated = allocated
            clientGroups[key] = group
        }

        var days = schedule.days(in: filter.interval).map { ReportDay(date: $0) }
        let dayIndex = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.date, $0) })
        for row in rows {
            guard let index = dayIndex[schedule.calendar.startOfDay(for: row.start)] else { continue }
            days[index].hours += row.hours
            days[index].byClient[row.clientName, default: 0] += row.hours
        }

        let byHours: (ReportGroup, ReportGroup) -> Bool = { a, b in
            a.hours == b.hours ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.hours > b.hours
        }
        let singleClient: String? = if let ids = filter.clientIDs, ids.count == 1 { store.client(ids.first)?.name } else { nil }

        return Report(
            filter: filter,
            generatedAt: now,
            rows: rows,
            byClient: clientGroups.values.sorted(by: byHours),
            byProject: projectGroups.values.sorted(by: byHours),
            byActivity: activityGroups.values.sorted(by: byHours),
            days: days,
            capacityHours: schedule.capacityHours(in: filter.interval),
            capacityToDate: isInProgress ? schedule.elapsedWorkdays(in: filter.interval, at: now) * schedule.dailyTarget
                                         : schedule.capacityHours(in: filter.interval),
            isInProgress: isInProgress,
            tolerance: settings.tolerancePercent / 100,
            currencyCode: settings.currencyCode,
            rounding: settings.rounding,
            userName: settings.userName,
            singleClientName: singleClient
        )
    }
}
