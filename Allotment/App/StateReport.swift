#if DEBUG
import Foundation

/// Every state machine in the app, one line each, for `--state-report`. Lets an agent or a script check where
/// the app stands without driving its windows. It reads data and never writes it, and the Keychain is only asked
/// whether secrets exist, never for the secrets themselves.
enum StateReport {
    @MainActor
    static func lines(store: TimeStore, calendar: CalendarService, sync: WorkdaySync, away: AwayTracker.State?) -> [String] {
        let timer = store.runningEntry.map { "running, \(store.title(for: $0)) since \(Fmt.time($0.start))" } ?? "stopped"
        let week = store.schedule.week(containing: .now)
        let weekStatus = WorkdayWeekStatus(period: WorkdayBuilder.build(week, store: store),
                                           submission: store.workdaySubmission(forWeekStarting: week.start))
        return [
            "timer: \(timer)",
            "storage: \(store.storage)",
            "calendar access: \(calendar.access)",
            "workday connection: \(sync.connection(for: store.workday.api).stage)",
            "workday sync: \(sync.phase)",
            "workday this week: \(weekStatus.shortTitle)",
            "away tracker: \(away.map { "\($0)" } ?? "not running")",
            "login item: \(LoginItem.state)",
        ]
    }
}
#endif
