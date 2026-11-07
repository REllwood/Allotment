import CryptoKit
import Foundation

/// One row of a Workday timesheet: a time entry code, project and task, with hours for each day.
struct WorkdayLine: Identifiable, Sendable {
    let id: String
    let timeCode: String
    let project: String
    let task: String
    /// The Allotment clients and projects whose time makes up this line.
    var sources: [String] = []
    /// Rounded hours, keyed by the start of each day.
    var hours: [Date: Double] = [:]
    var comments: [Date: String] = [:]
    var rawSeconds: [Date: Double] = [:]

    var total: Double { hours.values.reduce(0, +) }
    var title: String { sources.isEmpty ? "Unassigned" : sources.joined(separator: ", ") }

    /// Identifies one day's time block, including its hours, so a changed value is treated as new.
    func blockKey(for day: Date) -> String {
        "\(id)@\(Fmt.isoDay(day))=\(hours[day] ?? 0)"
    }
}

struct WorkdayIssue: Identifiable, Sendable {
    enum Severity: Sendable { case warning, info }
    let id: String
    let message: String
    let severity: Severity
}

/// Allotment's time over a period, shaped the way Workday wants it.
struct WorkdayPeriod: Sendable {
    let interval: DateInterval
    let days: [Date]
    let lines: [WorkdayLine]
    let issues: [WorkdayIssue]
    let rawTotal: Double
    let hasRunningTimer: Bool
    let employeeID: String

    var total: Double { lines.reduce(0) { $0 + $1.total } }
    var isEmpty: Bool { lines.isEmpty }

    func dayTotal(_ day: Date) -> Double {
        lines.reduce(0) { $0 + ($1.hours[day] ?? 0) }
    }

    /// Changes whenever any hours, code or project in the period changes.
    var fingerprint: String {
        let text = lines.sorted { $0.id < $1.id }
            .flatMap { line in days.compactMap { day in line.hours[day].map { _ in line.blockKey(for: day) } } }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Every non-empty day of every line, the unit Workday stores as a time block.
    var blocks: [(line: WorkdayLine, day: Date)] {
        days.flatMap { day in lines.filter { ($0.hours[day] ?? 0) > 0 }.map { ($0, day) } }
    }

    /// Tab separated, so it pastes into a spreadsheet or reads clearly as text.
    var tableText: String {
        var rows = [["Time entry code", "Project", "Task"] + days.map { Fmt.shortDay($0) } + ["Total", "Allotment"]]
        for line in lines {
            rows.append([line.timeCode, line.project, line.task]
                + days.map { line.hours[$0].map { Fmt.decimal($0) } ?? "" }
                + [Fmt.decimal(line.total), line.title])
        }
        rows.append(["Total", "", ""] + days.map { Fmt.decimal(dayTotal($0)) } + [Fmt.decimal(total), ""])
        return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
}

enum WorkdayBuilder {
    @MainActor
    static func build(_ interval: DateInterval, store: TimeStore, now: Date = .now) -> WorkdayPeriod {
        let config = store.workday
        let schedule = store.schedule
        let entries = store.entries(in: interval)

        var lines: [String: WorkdayLine] = [:]
        var notes: [String: [Date: [String]]] = [:]
        var missingCodes = Set<String>()
        var missingProjects = Set<String>()

        for entry in entries {
            let day = schedule.calendar.startOfDay(for: entry.start)
            let code = config.timeCode(for: entry.activityID)
            let target = config.projectAndTask(clientID: entry.clientID, projectID: entry.projectID)
            let key = "\(code)|\(target.project)|\(target.task)"
            let client = store.client(entry.clientID)
            let activity = store.activity(entry.activityID)

            if code.isEmpty { missingCodes.insert(activity?.name ?? "Time with no activity") }
            if let client, target.project.isEmpty, activity?.isAdmin != true { missingProjects.insert(client.name) }

            var line = lines[key] ?? WorkdayLine(id: key, timeCode: code, project: target.project, task: target.task)
            let source = [client?.name ?? (activity?.isAdmin == true ? "Internal admin" : "No client"), store.project(entry.projectID)?.name]
                .compactMap { $0 }
                .joined(separator: ": ")
            if !line.sources.contains(source) { line.sources.append(source) }
            line.rawSeconds[day, default: 0] += entry.duration(at: now)
            lines[key] = line

            let note: String? = switch config.commentStyle {
            case .none: nil
            case .notes: entry.notes.isEmpty ? nil : entry.notes
            case .clientAndNotes: entry.notes.isEmpty ? client?.name : "\(client?.name ?? "Internal"): \(entry.notes)"
            }
            if let note, !(notes[key]?[day]?.contains(note) ?? false) {
                notes[key, default: [:]][day, default: []].append(note)
            }
        }

        var result: [WorkdayLine] = []
        for var line in lines.values {
            for (day, seconds) in line.rawSeconds {
                let hours = config.round(seconds / 3600)
                if hours > 0 { line.hours[day] = hours }
                if let dayNotes = notes[line.id]?[day] {
                    // Workday comments are short, so keep them to a sentence or two.
                    line.comments[day] = String(dayNotes.joined(separator: "; ").prefix(250))
                }
            }
            if !line.hours.isEmpty { result.append(line) }
        }
        result.sort { ($0.project, $0.timeCode, $0.task) < ($1.project, $1.timeCode, $1.task) }

        let rawTotal = entries.reduce(0) { $0 + $1.duration(at: now) } / 3600
        let total = result.reduce(0) { $0 + $1.total }
        var issues: [WorkdayIssue] = []
        for name in missingCodes.sorted() {
            issues.append(WorkdayIssue(id: "code-\(name)", message: "\(name) has no Workday time entry code. Add one in Workday setup.", severity: .warning))
        }
        for name in missingProjects.sorted() {
            issues.append(WorkdayIssue(id: "project-\(name)", message: "\(name) has no Workday project, so its time is listed without one.", severity: .info))
        }
        let running = entries.contains(where: \.isRunning)
        if running {
            issues.append(WorkdayIssue(id: "running", message: "A timer is still running, so these hours will change.", severity: .info))
        }
        if abs(total - rawTotal) >= 0.01 && !entries.isEmpty {
            let difference = total - rawTotal
            issues.append(WorkdayIssue(id: "rounding",
                                       message: "Rounding each day to \(Fmt.decimal(config.incrementHours)) hour changes the total by \(difference > 0 ? "+" : "")\(Fmt.decimal(difference)) h.",
                                       severity: .info))
        }

        return WorkdayPeriod(interval: interval, days: schedule.days(in: interval), lines: result, issues: issues,
                             rawTotal: rawTotal, hasRunningTimer: running, employeeID: config.employeeID)
    }

    /// Recent weeks that have time but have not gone into Workday, or changed after they did.
    @MainActor
    static func outstandingWeeks(store: TimeStore, lookback: Int = 4, now: Date = .now) -> [WorkdayPeriod] {
        let schedule = store.schedule
        return (1...lookback).compactMap { back in
            let week = schedule.period(.week, containing: now, offset: -back)
            let period = build(week, store: store, now: now)
            guard !period.isEmpty else { return nil }
            guard let submission = store.workdaySubmission(forWeekStarting: week.start) else { return period }
            return submission.fingerprint == period.fingerprint ? nil : period
        }
    }
}
