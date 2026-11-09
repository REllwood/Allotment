import EventKit
import Foundation
import ServiceManagement
import Testing
@testable import Allotment

/// The away tracker on its own, fed events by hand, so no Mac has to sleep for these to run.
struct AwayTrackerTests {
    let t0 = Fixture.date(2026, 11, 9, 9)
    let threshold: TimeInterval = 10 * 60

    func context(timerStart: Date? = nil, threshold: TimeInterval? = nil) -> AwayTracker.Context {
        AwayTracker.Context(threshold: threshold ?? self.threshold, timerStart: timerStart ?? t0)
    }

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    @Test func asksAboutTimeAwayWhenYouComeBack() {
        var tracker = AwayTracker()
        // 30 minutes in, no input for 12 minutes: you left at minute 18.
        #expect(tracker.handle(.inputIdle(seconds: 12 * 60, at: at(30)), context: context()) == nil)
        #expect(tracker.state == .away(since: at(18)))
        // Still away a little later.
        #expect(tracker.handle(.inputIdle(seconds: 20 * 60, at: at(38)), context: context()) == nil)
        // Input again 5 seconds before minute 45.
        let period = tracker.handle(.inputIdle(seconds: 5, at: at(45)), context: context())
        #expect(period == AwayPeriod(start: at(18), end: at(45).addingTimeInterval(-5)))
        #expect(tracker.state == .asking(period!))
    }

    @Test func shortBreaksAreIgnored() {
        var tracker = AwayTracker()
        #expect(tracker.handle(.inputIdle(seconds: 4 * 60, at: at(30)), context: context()) == nil)
        #expect(tracker.state == .present)
    }

    @Test func sleepKeepsTheMomentYouLeft() {
        var tracker = AwayTracker()
        _ = tracker.handle(.inputIdle(seconds: 15 * 60, at: at(40)), context: context())
        _ = tracker.handle(.willSleep(at: at(50)), context: context())
        #expect(tracker.state == .asleep(since: at(25)))
        let period = tracker.handle(.didWake(at: at(120)), context: context())
        #expect(period == AwayPeriod(start: at(25), end: at(120)))
    }

    @Test func aShortSleepDoesNotAsk() {
        var tracker = AwayTracker()
        _ = tracker.handle(.willSleep(at: at(30)), context: context())
        #expect(tracker.state == .asleep(since: at(30)))
        #expect(tracker.handle(.didWake(at: at(35)), context: context()) == nil)
        #expect(tracker.state == .present)
    }

    @Test func nothingReplacesAQuestionOnScreen() {
        var tracker = AwayTracker()
        _ = tracker.handle(.inputIdle(seconds: 15 * 60, at: at(30)), context: context())
        let period = tracker.handle(.inputIdle(seconds: 1, at: at(40)), context: context())
        #expect(period != nil)
        // Away again and back again while the first question is still showing.
        #expect(tracker.handle(.inputIdle(seconds: 20 * 60, at: at(70)), context: context()) == nil)
        #expect(tracker.handle(.willSleep(at: at(71)), context: context()) == nil)
        #expect(tracker.handle(.didWake(at: at(200)), context: context()) == nil)
        #expect(tracker.state == .asking(period!))
        _ = tracker.handle(.answered, context: context())
        #expect(tracker.state == .present)
    }

    @Test func stoppingTheTimerOrTurningItOffResets() {
        var tracker = AwayTracker()
        _ = tracker.handle(.inputIdle(seconds: 15 * 60, at: at(30)), context: context())
        #expect(tracker.state != .present)
        _ = tracker.handle(.inputIdle(seconds: 16 * 60, at: at(31)),
                           context: AwayTracker.Context(threshold: threshold, timerStart: nil))
        #expect(tracker.state == .present)

        _ = tracker.handle(.willSleep(at: at(40)), context: context(threshold: 0))
        #expect(tracker.state == .present)
    }

    @Test func timeAwayNeverStartsBeforeTheTimer() {
        var tracker = AwayTracker()
        // The timer started at minute 25, after you had already been idle since minute 20.
        _ = tracker.handle(.inputIdle(seconds: 15 * 60, at: at(35)), context: context(timerStart: at(25)))
        #expect(tracker.state == .away(since: at(25)))
    }

    @Test func aTimerStartedAfterYouCameBackIsLeftAlone() {
        var tracker = AwayTracker()
        _ = tracker.handle(.inputIdle(seconds: 15 * 60, at: at(30)), context: context())
        // You came back at minute 40 and started a new timer at minute 41 before the next sample.
        let period = tracker.handle(.inputIdle(seconds: 60, at: at(41)), context: context(timerStart: at(41)))
        #expect(period == nil)
        #expect(tracker.state == .present)
    }
}

struct WorkdayConnectionTests {
    func config(rest: String = "https://wd.example.com/ccx/api/v1/acme", token: String = "https://wd.example.com/token",
                authorize: String = "", client: String = "client-1", workerID: String = "", workerName: String = "") -> WorkdayAPIConfig {
        var config = WorkdayAPIConfig()
        config.restEndpoint = rest
        config.tokenEndpoint = token
        config.authorizationEndpoint = authorize
        config.clientID = client
        config.workerID = workerID
        config.workerName = workerName
        return config
    }

    @Test func listsWhatIsMissingInOrder() {
        let connection = WorkdayConnection(config: config(rest: "", client: " "), hasClientSecret: false, hasRefreshToken: true)
        #expect(connection.stage == .incomplete(missing: ["REST API endpoint", "client ID", "client secret"]))
        #expect(!connection.canSignIn)
        #expect(!connection.isSignedIn)
        #expect(connection.summary == "To connect, add the REST API endpoint, client ID and client secret.")
    }

    @Test func signedOutUntilThereIsARefreshToken() {
        let withoutSignInPage = WorkdayConnection(config: config(), hasClientSecret: true, hasRefreshToken: false)
        #expect(withoutSignInPage.stage == .signedOut)
        #expect(!withoutSignInPage.canSignIn)

        let withSignInPage = WorkdayConnection(config: config(authorize: "https://wd.example.com/authorize"),
                                               hasClientSecret: true, hasRefreshToken: false)
        #expect(withSignInPage.canSignIn)
        #expect(withSignInPage.summary == "Ready to sign in with Workday.")
    }

    @Test func signedInNamesTheWorkerWhenKnown() {
        let named = WorkdayConnection(config: config(workerID: "w1", workerName: "Rhys"), hasClientSecret: true, hasRefreshToken: true)
        #expect(named.stage == .signedIn(worker: "Rhys"))
        let idOnly = WorkdayConnection(config: config(workerID: "w1"), hasClientSecret: true, hasRefreshToken: true)
        #expect(idOnly.stage == .signedIn(worker: "w1"))
        let unknown = WorkdayConnection(config: config(), hasClientSecret: true, hasRefreshToken: true)
        #expect(unknown.stage == .signedIn(worker: nil))
        #expect(unknown.isSignedIn)
    }

    @Test func partialSendsAreMarkedByTheirFingerprint() {
        let week = Fixture.date(2026, 11, 2)
        let partial = WorkdaySubmission(weekStart: week, submittedAt: week, method: .api, hours: 8, fingerprint: "")
        let complete = WorkdaySubmission(weekStart: week, submittedAt: week, method: .api, hours: 8, fingerprint: "abc")
        let exported = WorkdaySubmission(weekStart: week, submittedAt: week, method: .export, hours: 8, fingerprint: "")
        #expect(partial.isPartial)
        #expect(!complete.isPartial)
        #expect(!exported.isPartial)
    }
}

struct CalendarStateTests {
    let now = Fixture.date(2026, 11, 9, 12)

    func event(_ id: String, from start: Int, to end: Int) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: now.addingTimeInterval(Double(start) * 60), end: now.addingTimeInterval(Double(end) * 60),
                      isAllDay: false, calendarTitle: "", calendarColorHex: "", location: "", attendeeEmails: [], isDeclined: false)
    }

    func state(_ event: CalendarEvent, logged: Set<String> = [], skipped: Set<String> = []) -> CalendarEventState {
        CalendarEventState(event: event, at: now, logged: logged, skipped: skipped)
    }

    @Test func followsTheClock() {
        #expect(state(event("later", from: 30, to: 60)) == .upcoming)
        #expect(state(event("now", from: 0, to: 30)) == .happening)
        #expect(state(event("earlier", from: -60, to: 0)) == .finished)
        #expect(!CalendarEventState.upcoming.canLog)
        #expect(CalendarEventState.happening.canLog)
        #expect(CalendarEventState.finished.canLog)
    }

    @Test func loggedAndSkippedWinOverTheClock() {
        let meeting = event("standup", from: -30, to: -15)
        #expect(state(meeting, logged: ["standup"]) == .logged)
        #expect(state(meeting, skipped: ["standup"]) == .skipped)
        #expect(state(meeting, logged: ["standup"], skipped: ["standup"]) == .logged)
        #expect(!CalendarEventState.logged.canLog)
        #expect(!CalendarEventState.skipped.canLog)
    }

    @Test func accessFollowsThePermission() {
        #expect(CalendarAccess(.fullAccess) == .granted)
        #expect(CalendarAccess(.notDetermined) == .notAsked)
        #expect(CalendarAccess(.denied) == .denied)
        #expect(CalendarAccess(.restricted) == .denied)
        #expect(CalendarAccess(.writeOnly) == .denied)
    }
}

struct LoginItemTests {
    @Test func followsTheSystemStatus() {
        #expect(LoginItem.State(.enabled) == .on)
        #expect(LoginItem.State(.requiresApproval) == .needsApproval)
        #expect(LoginItem.State(.notRegistered) == .off)
        #expect(LoginItem.State(.notFound) == .off)
    }
}
