#if DEBUG
import Foundation

/// Every state machine in the app, one line each, for `--state-report`. Lets an agent or a script check where
/// the app stands without driving its windows. It reads data and never writes it, and the Keychain is only asked
/// whether secrets exist, never for the secrets themselves. With `--demo`, calendar links are kept in memory and
/// downloaded once first, so their state is current. With your own data they are not downloaded, because that
/// would mean reading their addresses from the Keychain.
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
            "calendar links: \(linkReport(store.settings.calendarLinks, links: calendar.links))",
            "workday connection: \(sync.connection(for: store.workday.api).stage)",
            "workday sync: \(sync.phase)",
            "workday this week: \(weekStatus.shortTitle)",
            "away tracker: \(away.map { "\($0)" } ?? "not running")",
            "login item: \(LoginItem.state)",
        ]
    }

    /// Each link's name and state, plus whether its address is saved. The address itself is never printed,
    /// because anyone with it can read the calendar.
    @MainActor
    private static func linkReport(_ list: [CalendarLink], links: CalendarLinks) -> String {
        guard !list.isEmpty else { return "none" }
        return list.map { link in
            let saved = links.hasAddress(for: link) ? "" : ", address missing"
            return "\(link.name) \(links.state(of: link))\(saved)"
        }.joined(separator: "; ")
    }
}
#endif
