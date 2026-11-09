import Foundation
import Testing
@testable import Allotment

@MainActor
struct StoreTests {
    @Test func onlyOneTimerRunsAtATime() {
        let store = TimeStore(fileURL: nil)
        let acme = store.newClient(named: "Acme")
        let globex = store.newClient(named: "Globex")
        store.startTimer(clientID: acme.id, at: .now.addingTimeInterval(-600))
        store.startTimer(clientID: globex.id)
        #expect(store.entries.filter(\.isRunning).count == 1)
        #expect(store.runningEntry?.clientID == globex.id)
        #expect(store.entries.first { $0.clientID == acme.id }?.end != nil)
    }

    @Test func accidentalTimersAreDiscarded() {
        let store = TimeStore(fileURL: nil)
        store.startTimer(clientID: nil, at: .now.addingTimeInterval(-2))
        store.stopTimer()
        #expect(store.entries.isEmpty)
    }

    @Test func adminAndInternalTimeIsNotBillable() {
        let store = TimeStore(fileURL: nil)
        let acme = store.newClient(named: "Acme")
        #expect(store.defaultBillable(clientID: nil, projectID: nil, activityID: Activity.clientWorkID) == false)
        #expect(store.defaultBillable(clientID: acme.id, projectID: nil, activityID: Activity.adminID) == false)
        #expect(store.defaultBillable(clientID: acme.id, projectID: nil, activityID: Activity.meetingID) == true)
    }

    @Test func calendarEventsAreLoggedOnce() {
        let store = TimeStore(fileURL: nil)
        let event = CalendarEvent(id: "abc@1", title: "Acme weekly sync", start: .now.addingTimeInterval(-3600), end: .now,
                                  isAllDay: false, calendarTitle: "Work", calendarColorHex: "#FF0000", location: "",
                                  attendeeEmails: [], isDeclined: false)
        store.logEvent(event, clientID: nil)
        store.logEvent(event, clientID: nil)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.source == .calendar)
    }

    @Test func dataSurvivesASaveAndReload() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "store-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TimeStore(fileURL: url)
        let acme = store.newClient(named: "Acme")
        store.save(TimeEntry(clientID: acme.id, notes: "Kick-off", start: .now.addingTimeInterval(-3600), end: .now, isBillable: true, source: .manual))
        store.saveNow()

        let reloaded = TimeStore(fileURL: url)
        #expect(reloaded.clients.map(\.name) == ["Acme"])
        #expect(reloaded.entries.first?.notes == "Kick-off")
        #expect(reloaded.storage == .healthy)
    }

    @Test func olderFilesWithMissingFieldsStillLoad() throws {
        let json = """
        {"clients":[{"id":"6F1E3C2A-0000-4000-8000-000000000001","name":"Acme"}],
         "entries":[{"id":"6F1E3C2A-0000-4000-8000-000000000002","start":"2026-11-02T09:00:00Z","end":"2026-11-02T10:00:00Z"}],
         "settings":{"weeklyCapacityHours":30}}
        """
        let data = try TimeStore.decoder.decode(AppData.self, from: Data(json.utf8))
        #expect(data.clients.first?.isFavorite == true)
        #expect(data.entries.first?.duration() == 3600)
        #expect(data.settings.weeklyCapacityHours == 30)
        #expect(data.settings.workdays == [2, 3, 4, 5, 6])
        #expect(data.activities.count == Activity.defaults.count)
    }

    @Test func unreadableFilesAreKeptAside() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "store-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "data.json")
        try Data("not json".utf8).write(to: url)
        let store = TimeStore(fileURL: url)
        let kept = folder.appending(path: "data.unreadable.json")
        guard case .couldNotRead(_, let keptAs) = store.storage else {
            Issue.record("Expected a read problem, got \(store.storage)")
            return
        }
        #expect(keptAs.lastPathComponent == kept.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: kept.path))

        // Saving works again, so the read problem stays until it is dismissed.
        _ = store.newClient(named: "Acme")
        store.saveNow()
        #expect(store.storage != .healthy)
        store.dismissStorageProblem()
        #expect(store.storage == .healthy)
    }

    @Test func saveProblemsClearWhenSavingWorksAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "store-blocked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A file where the data folder should be, so creating the folder fails.
        let blocker = folder.appending(path: "Allotment")
        try Data().write(to: blocker)
        let store = TimeStore(fileURL: blocker.appending(path: "data.json"))
        _ = store.newClient(named: "Acme")
        store.saveNow()
        guard case .couldNotSave = store.storage else {
            Issue.record("Expected a save problem, got \(store.storage)")
            return
        }
        // Dismissing is only for read problems. A save problem goes away by saving.
        store.dismissStorageProblem()
        #expect(store.storage != .healthy)

        try FileManager.default.removeItem(at: blocker)
        store.saveNow()
        #expect(store.storage == .healthy)
    }

    @Test func sampleDataIsRepeatable() {
        let now = Fixture.date(2026, 11, 4, 14)
        let a = SampleData.make(now: now)
        let b = SampleData.make(now: now)
        #expect(a.entries.count == b.entries.count)
        #expect(a.entries.map(\.notes) == b.entries.map(\.notes))
        #expect(a.entries.filter(\.isRunning).count == 1)
    }
}

struct ParsingTests {
    @Test(arguments: [("1:30", 5400.0), ("1.5", 5400), ("90m", 5400), ("1h 30m", 5400), ("2h", 7200), ("0,25", 900)])
    func durations(text: String, seconds: Double) {
        #expect(Fmt.parseDuration(text) == seconds)
    }

    @Test func badDurationsAreRejected() {
        #expect(Fmt.parseDuration("") == nil)
        #expect(Fmt.parseDuration("1:75") == nil)
        #expect(Fmt.parseDuration("soon") == nil)
    }

    @Test func roundingRules() {
        #expect(RoundingRule.up15.apply(60) == 900)
        #expect(RoundingRule.nearest15.apply(7 * 60) == 0)
        #expect(RoundingRule.nearest15.apply(8 * 60) == 900)
        #expect(RoundingRule.up6.apply(361) == 720)
        #expect(RoundingRule.none.apply(123) == 123)
    }

    @Test func clockFormatting() {
        #expect(Fmt.clock(3725) == "1:02")
        #expect(Fmt.clock(3725, showSeconds: true) == "1:02:05")
        #expect(Fmt.hm(45 * 60) == "45m")
        #expect(Fmt.hm(125 * 60) == "2h 05m")
        #expect(Fmt.hm(16 * 3600) == "16h")
        #expect(Fmt.hours(12.5) == "12h 30m")
        #expect(Fmt.hm(0) == "0m")
    }

    @Test func calendarMatching() {
        let acme = Client(name: "Acme Studio", colorHex: "#3B82F6", matchKeywords: ["acmestudio.com"])
        let globex = Client(name: "Globex", colorHex: "#8B5CF6")
        func event(_ title: String, _ emails: [String] = []) -> CalendarEvent {
            CalendarEvent(id: title, title: title, start: .now, end: .now, isAllDay: false, calendarTitle: "", calendarColorHex: "",
                          location: "", attendeeEmails: emails, isDeclined: false)
        }
        #expect(EventMatcher.client(for: event("Sprint review", ["jo@acmestudio.com"]), in: [acme, globex])?.id == acme.id)
        #expect(EventMatcher.client(for: event("Globex standup"), in: [acme, globex])?.id == globex.id)
        #expect(EventMatcher.client(for: event("Dentist"), in: [acme, globex]) == nil)
    }
}
