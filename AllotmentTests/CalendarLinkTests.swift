import Foundation
import Testing
@testable import Allotment

/// Calendar files shaped like the ones Outlook and Google publish.
enum CalendarFixture {
    static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    static func interval(_ start: String, _ end: String) -> DateInterval {
        DateInterval(start: utc(start), end: utc(end))
    }

    static let london = TimeZone(identifier: "Europe/London")!

    static func file(_ lines: [String]) -> String {
        lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Outlook sends Windows time zone names and spells out their rules in VTIMEZONE.
    static let outlook = file([
        "BEGIN:VCALENDAR",
        "METHOD:PUBLISH",
        "PRODID:Microsoft Exchange Server 2010",
        "VERSION:2.0",
        "X-WR-CALNAME:Calendar",
        "BEGIN:VTIMEZONE",
        "TZID:AUS Eastern Standard Time",
        "BEGIN:STANDARD",
        "DTSTART:16010101T030000",
        "TZOFFSETFROM:+1100",
        "TZOFFSETTO:+1000",
        "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=4",
        "END:STANDARD",
        "BEGIN:DAYLIGHT",
        "DTSTART:16010101T020000",
        "TZOFFSETFROM:+1000",
        "TZOFFSETTO:+1100",
        "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=10",
        "END:DAYLIGHT",
        "END:VTIMEZONE",
        "BEGIN:VTIMEZONE",
        "TZID:GMT Standard Time",
        "BEGIN:STANDARD",
        "DTSTART:16010101T020000",
        "TZOFFSETFROM:+0100",
        "TZOFFSETTO:+0000",
        "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10",
        "END:STANDARD",
        "BEGIN:DAYLIGHT",
        "DTSTART:16010101T010000",
        "TZOFFSETFROM:+0000",
        "TZOFFSETTO:+0100",
        "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3",
        "END:DAYLIGHT",
        "END:VTIMEZONE",
        "BEGIN:VTIMEZONE",
        "TZID:Singapore Standard Time",
        "BEGIN:STANDARD",
        "DTSTART:16010101T000000",
        "TZOFFSETFROM:+0800",
        "TZOFFSETTO:+0800",
        "END:STANDARD",
        "END:VTIMEZONE",
        // A weekly Teams meeting across the October clock change, with one week skipped.
        "BEGIN:VEVENT",
        "RRULE:FREQ=WEEKLY;UNTIL=20261231T000000Z;INTERVAL=1;BYDAY=MO;WKST=SU",
        "EXDATE;TZID=AUS Eastern Standard Time:20261123T090000",
        "UID:040000008200E00074C5B7101A82E00800000000AAAA",
        "SUMMARY;LANGUAGE=en-AU:Weekly standup\\, product an",
        " d design",
        "DTSTART;TZID=AUS Eastern Standard Time:20260907T090000",
        "DTEND;TZID=AUS Eastern Standard Time:20260907T091500",
        "LOCATION;LANGUAGE=en-AU:Microsoft Teams Meeting",
        "STATUS:CONFIRMED",
        "END:VEVENT",
        // The last weekday of each month, as Outlook writes it.
        "BEGIN:VEVENT",
        "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
        "UID:month-end",
        "SUMMARY:Month-end review",
        "DTSTART;TZID=AUS Eastern Standard Time:20261030T160000",
        "DTEND;TZID=AUS Eastern Standard Time:20261030T170000",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:summer",
        "SUMMARY:London call in summer",
        "DTSTART;TZID=GMT Standard Time:20260715T090000",
        "DTEND;TZID=GMT Standard Time:20260715T100000",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:winter",
        "SUMMARY:London call in winter",
        "DTSTART;TZID=GMT Standard Time:20270115T090000",
        "DTEND;TZID=GMT Standard Time:20270115T100000",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:singapore",
        "SUMMARY:Singapore call",
        "DTSTART;TZID=Singapore Standard Time:20261125T090000",
        "DTEND;TZID=Singapore Standard Time:20261125T093000",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:holiday",
        "SUMMARY:Public holiday",
        "DTSTART;VALUE=DATE:20261126",
        "DTEND;VALUE=DATE:20261127",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:cancelled",
        "SUMMARY:Cancelled meeting",
        "STATUS:CANCELLED",
        "DTSTART:20261125T120000Z",
        "DTEND:20261125T130000Z",
        "END:VEVENT",
        "END:VCALENDAR",
    ])

    /// Google sends IANA time zone names, UTC times and separate entries for moved or cancelled repeats.
    static let google = file([
        "BEGIN:VCALENDAR",
        "PRODID:-//Google Inc//Google Calendar 70.9054//EN",
        "VERSION:2.0",
        "X-WR-CALNAME:Work",
        "X-WR-TIMEZONE:Europe/London",
        "BEGIN:VEVENT",
        "DTSTART;TZID=Europe/London:20261006T100000",
        "DTEND;TZID=Europe/London:20261006T110000",
        "RRULE:FREQ=WEEKLY;WKST=MO;BYDAY=TU",
        "EXDATE;TZID=Europe/London:20261117T100000",
        "UID:client-sync@google.com",
        "ORGANIZER;CN=Me:mailto:me@example.com",
        "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Pat;X-NUM-GUESTS=0:mailto:Pat@Acme.com",
        "SUMMARY:Client sync",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "DTSTART;TZID=Europe/London:20261124T140000",
        "DTEND;TZID=Europe/London:20261124T150000",
        "RECURRENCE-ID;TZID=Europe/London:20261124T100000",
        "UID:client-sync@google.com",
        "SUMMARY:Client sync (moved)",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "DTSTART;TZID=Europe/London:20261201T100000",
        "DTEND;TZID=Europe/London:20261201T110000",
        "RECURRENCE-ID;TZID=Europe/London:20261201T100000",
        "UID:client-sync@google.com",
        "STATUS:CANCELLED",
        "SUMMARY:Client sync",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "DTSTART:20261125T093000Z",
        "DTEND:20261125T101500Z",
        "UID:review@google.com",
        "SUMMARY:Design review",
        "LOCATION:Room 4\\; level 2",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "DTSTART:20261125T150000Z",
        "DURATION:PT45M",
        "UID:duration@google.com",
        "SUMMARY:Quick check-in",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "DTSTART:20261013T150000Z",
        "DTEND:20261013T160000Z",
        "RRULE:FREQ=MONTHLY;BYDAY=2TU;COUNT=3",
        "UID:monthly@google.com",
        "SUMMARY:Monthly planning",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "DTSTART;TZID=Europe/London:20260609T090000",
        "DTEND;TZID=Europe/London:20260609T100000",
        "RRULE:FREQ=YEARLY;BYMONTH=6;BYDAY=2TU",
        "UID:yearly@google.com",
        "SUMMARY:Annual review",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "DTSTART:20261201T080000Z",
        "DTEND:20261201T083000Z",
        "RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20261205",
        "UID:daily@google.com",
        "SUMMARY:Every other day",
        "END:VEVENT",
        "END:VCALENDAR",
    ])
}

struct CalendarFileTests {
    let outlook = try! CalendarFile.parse(CalendarFixture.outlook, localZone: CalendarFixture.london)
    let google = try! CalendarFile.parse(CalendarFixture.google, localZone: CalendarFixture.london)

    func starts(_ file: CalendarFile, titled title: String, _ start: String, _ end: String) -> [Date] {
        file.occurrences(in: CalendarFixture.interval(start, end)).filter { $0.title.hasPrefix(title) }.map(\.start)
    }

    @Test func readsTheCalendarNameAndFoldedEscapedText() throws {
        #expect(outlook.name == "Calendar")
        #expect(google.name == "Work")
        // 9:00 on Monday 7 September in Sydney is 23:00 on Sunday in UTC.
        let standup = try #require(outlook.occurrences(in: CalendarFixture.interval("2026-09-06T00:00:00Z", "2026-09-08T00:00:00Z")).first)
        #expect(standup.start == CalendarFixture.utc("2026-09-06T23:00:00Z"))
        #expect(standup.title == "Weekly standup, product and design")
        #expect(standup.location == "Microsoft Teams Meeting")
        #expect(standup.end.timeIntervalSince(standup.start) == 15 * 60)
    }

    @Test func keepsOutlookMeetingsAtTheSameWallTimeWhenTheClocksChange() {
        // Sydney moves from +10 to +11 on 4 October 2026. The meeting stays at 9:00 there.
        let found = starts(outlook, titled: "Weekly standup", "2026-09-27T00:00:00Z", "2026-10-06T00:00:00Z")
        #expect(found == [CalendarFixture.utc("2026-09-27T23:00:00Z"), CalendarFixture.utc("2026-10-04T22:00:00Z")])
    }

    @Test func leavesOutSkippedRepeatsAndStopsAtUntil() {
        // Mondays 16, 23 and 30 November in Sydney. The 23rd is skipped.
        let november = starts(outlook, titled: "Weekly standup", "2026-11-15T00:00:00Z", "2026-11-30T00:00:00Z")
        #expect(november == [CalendarFixture.utc("2026-11-15T22:00:00Z"), CalendarFixture.utc("2026-11-29T22:00:00Z")])
        let around = starts(outlook, titled: "Weekly standup", "2026-12-20T00:00:00Z", "2027-01-10T00:00:00Z")
        #expect(around == [CalendarFixture.utc("2026-12-20T22:00:00Z"), CalendarFixture.utc("2026-12-27T22:00:00Z")])
    }

    @Test func findsTheLastWeekdayOfEachMonth() {
        let found = starts(outlook, titled: "Month-end", "2026-11-01T00:00:00Z", "2027-02-01T00:00:00Z")
        #expect(found == [
            CalendarFixture.utc("2026-11-30T05:00:00Z"),
            CalendarFixture.utc("2026-12-31T05:00:00Z"),
            CalendarFixture.utc("2027-01-29T05:00:00Z"),
        ])
    }

    @Test func readsWindowsTimeZoneNamesFromTheirRules() {
        #expect(starts(outlook, titled: "London call in summer", "2026-07-15T00:00:00Z", "2026-07-16T00:00:00Z")
                == [CalendarFixture.utc("2026-07-15T08:00:00Z")])
        #expect(starts(outlook, titled: "London call in winter", "2027-01-15T00:00:00Z", "2027-01-16T00:00:00Z")
                == [CalendarFixture.utc("2027-01-15T09:00:00Z")])
        #expect(starts(outlook, titled: "Singapore", "2026-11-25T00:00:00Z", "2026-11-26T00:00:00Z")
                == [CalendarFixture.utc("2026-11-25T01:00:00Z")])
    }

    @Test func treatsAllDayEventsAsLocalDays() throws {
        let holiday = try #require(outlook.occurrences(in: CalendarFixture.interval("2026-11-26T00:00:00Z", "2026-11-27T00:00:00Z"))
            .first { $0.title == "Public holiday" })
        #expect(holiday.isAllDay)
        #expect(holiday.start == CalendarFixture.utc("2026-11-26T00:00:00Z"))
        #expect(holiday.end == CalendarFixture.utc("2026-11-27T00:00:00Z"))
    }

    @Test func leavesOutCancelledMeetings() {
        #expect(starts(outlook, titled: "Cancelled", "2026-11-25T00:00:00Z", "2026-11-26T00:00:00Z").isEmpty)
    }

    @Test func handlesGoogleMovedSkippedAndCancelledRepeats() {
        let found = google.occurrences(in: CalendarFixture.interval("2026-11-16T00:00:00Z", "2026-12-09T00:00:00Z"))
            .filter { $0.uid == "client-sync@google.com" }
        #expect(found.map(\.start) == [CalendarFixture.utc("2026-11-24T14:00:00Z"), CalendarFixture.utc("2026-12-08T10:00:00Z")])
        #expect(found.first?.title == "Client sync (moved)")
    }

    @Test func followsLondonSummerTime() {
        let found = starts(google, titled: "Client sync", "2026-10-19T00:00:00Z", "2026-10-28T00:00:00Z")
        #expect(found == [CalendarFixture.utc("2026-10-20T09:00:00Z"), CalendarFixture.utc("2026-10-27T10:00:00Z")])
    }

    @Test func readsAttendeesInLowerCase() throws {
        let sync = try #require(google.occurrences(in: CalendarFixture.interval("2026-10-06T00:00:00Z", "2026-10-07T00:00:00Z")).first)
        #expect(sync.attendeeEmails == ["pat@acme.com", "me@example.com"])
    }

    @Test func readsUTCTimesDurationsAndEscapedSemicolons() throws {
        let day = google.occurrences(in: CalendarFixture.interval("2026-11-25T00:00:00Z", "2026-11-26T00:00:00Z"))
        let review = try #require(day.first { $0.title == "Design review" })
        #expect(review.start == CalendarFixture.utc("2026-11-25T09:30:00Z"))
        #expect(review.location == "Room 4; level 2")
        let checkIn = try #require(day.first { $0.title == "Quick check-in" })
        #expect(checkIn.end.timeIntervalSince(checkIn.start) == 45 * 60)
    }

    @Test func stopsAfterCount() {
        let found = starts(google, titled: "Monthly planning", "2026-10-01T00:00:00Z", "2027-03-01T00:00:00Z")
        #expect(found == [
            CalendarFixture.utc("2026-10-13T15:00:00Z"),
            CalendarFixture.utc("2026-11-10T15:00:00Z"),
            CalendarFixture.utc("2026-12-08T15:00:00Z"),
        ])
    }

    @Test func findsTheSecondTuesdayOfJuneEachYear() {
        #expect(starts(google, titled: "Annual review", "2027-06-01T00:00:00Z", "2027-07-01T00:00:00Z")
                == [CalendarFixture.utc("2027-06-08T08:00:00Z")])
    }

    @Test func repeatsEveryOtherDayUntilADate() {
        let found = starts(google, titled: "Every other day", "2026-11-30T00:00:00Z", "2026-12-12T00:00:00Z")
        #expect(found == [
            CalendarFixture.utc("2026-12-01T08:00:00Z"),
            CalendarFixture.utc("2026-12-03T08:00:00Z"),
            CalendarFixture.utc("2026-12-05T08:00:00Z"),
        ])
    }

    @Test func includesMeetingsThatStartedBeforeTheRange() {
        // The 9:30 to 10:15 review overlaps a range that starts at 10:00.
        let found = google.occurrences(in: CalendarFixture.interval("2026-11-25T10:00:00Z", "2026-11-25T11:00:00Z")).map(\.title)
        #expect(found == ["Design review"])
    }

    @Test func readsAFileThatStartsWithAByteOrderMark() throws {
        let file = try CalendarFile.parse("\u{FEFF}" + CalendarFixture.google, localZone: CalendarFixture.london)
        #expect(file.name == "Work")
        #expect(!file.events.isEmpty)
    }

    /// About the size of a busy work calendar published from Outlook: 3,000 meetings, 300 of them repeating.
    @Test func readsALargeCalendarQuickly() throws {
        var lines = Array(CalendarFixture.outlook.components(separatedBy: "\r\n").prefix { $0 != "BEGIN:VEVENT" })
        for index in 0..<3_000 {
            let day = 1 + index % 28
            let month = 1 + (index / 28) % 12
            let year = 2024 + (index / 336) % 3
            let stamp = String(format: "%04d%02d%02dT%02d0000", year, month, day, 8 + index % 9)
            lines += ["BEGIN:VEVENT", "UID:event-\(index)", "SUMMARY:Meeting \(index)",
                      "DTSTART;TZID=AUS Eastern Standard Time:\(stamp)",
                      "DURATION:PT30M"]
            if index % 10 == 0 { lines.append("RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR") }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        let text = lines.joined(separator: "\r\n")

        let clock = ContinuousClock()
        var file: CalendarFile?
        let reading = try clock.measure { file = try CalendarFile.parse(text, localZone: CalendarFixture.london) }
        var found: [CalendarFile.Occurrence] = []
        let day = clock.measure { found = file!.occurrences(in: CalendarFixture.interval("2026-11-24T13:00:00Z", "2026-11-25T13:00:00Z")) }
        let week = clock.measure { _ = file!.occurrences(in: CalendarFixture.interval("2026-11-22T13:00:00Z", "2026-11-29T13:00:00Z")) }
        print("Large calendar: read in \(reading), one day in \(day), one week in \(week), \(found.count) meetings that day")
        #expect(file?.events.count == 3_000)
        // Nearly all of the 300 repeating meetings started before this Wednesday, so they fall on it.
        #expect(found.count >= 250)
        #expect(reading < .seconds(3))
        #expect(day < .milliseconds(500))
    }

    @Test func recognisesWebPagesAndOtherFiles() {
        #expect(throws: CalendarFile.Problem.webPage) {
            try CalendarFile.parse("<!DOCTYPE html><html><body>Calendar</body></html>")
        }
        #expect(throws: CalendarFile.Problem.notACalendar) {
            try CalendarFile.parse("Not found")
        }
    }
}

struct CalendarLinkAddressTests {
    @Test func turnsWebcalLinksIntoSecureOnes() throws {
        #expect(try CalendarLinkAddress.url(from: "webcal://calendar.example.com/a.ics").absoluteString == "https://calendar.example.com/a.ics")
        #expect(try CalendarLinkAddress.url(from: "http://example.com/cal.ics").absoluteString == "https://example.com/cal.ics")
    }

    @Test func swapsOutlooksWebPageLinkForItsCalendarFile() throws {
        let url = try CalendarLinkAddress.url(from: "  https://outlook.office365.com/owa/calendar/abc@example.com/def/calendar.html \n")
        #expect(url.absoluteString == "https://outlook.office365.com/owa/calendar/abc@example.com/def/calendar.ics")
    }

    @Test func refusesThingsThatAreNotLinks() {
        #expect(throws: CalendarLinkAddress.Problem.empty) { try CalendarLinkAddress.url(from: "   ") }
        #expect(throws: CalendarLinkAddress.Problem.notALink) { try CalendarLinkAddress.url(from: "my calendar") }
        #expect(throws: CalendarLinkAddress.Problem.notALink) { try CalendarLinkAddress.url(from: "ftp://example.com/a.ics") }
    }

    @Test func suggestsANameFromTheHost() throws {
        #expect(CalendarLinkAddress.suggestedName(for: URL(string: "https://outlook.office365.com/a.ics")!) == "Outlook")
        #expect(CalendarLinkAddress.suggestedName(for: URL(string: "https://calendar.google.com/a.ics")!) == "Google Calendar")
    }
}

struct CalendarLinkStateTests {
    let first = CalendarFixture.utc("2026-11-25T09:00:00Z")
    let second = CalendarFixture.utc("2026-11-25T09:15:00Z")

    @Test func becomesCurrentWhenADownloadWorks() {
        var state = CalendarLinkState.waiting
        state.downloaded(at: first)
        #expect(state == .current(updated: first))
        state.downloaded(at: second)
        #expect(state == .current(updated: second))
    }

    @Test func remembersTheLastGoodDownloadWhenOneFails() {
        var state = CalendarLinkState.waiting
        state.failed("Offline")
        #expect(state == .failing(reason: "Offline", lastUpdated: nil))

        state = .current(updated: first)
        state.failed("Offline")
        #expect(state == .failing(reason: "Offline", lastUpdated: first))
        state.failed("Still offline")
        #expect(state == .failing(reason: "Still offline", lastUpdated: first))
        #expect(state.isFailing)

        state.downloaded(at: second)
        #expect(state == .current(updated: second))
    }
}

/// Answers downloads from memory, so no test touches the network.
final class FakeCalendarServer: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = CalendarFixture.google
    private(set) var requests: [URL] = []

    func answer(status: Int, body: String = CalendarFixture.google) {
        lock.withLock {
            self.status = status
            self.body = body
        }
    }

    var downloader: CalendarDownloader {
        CalendarDownloader { [self] url in
            lock.withLock {
                requests.append(url)
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        }
    }
}

@MainActor
struct CalendarLinksTests {
    let server = FakeCalendarServer()
    let secrets = MemorySecretStore()
    let week = CalendarFixture.interval("2026-11-23T00:00:00Z", "2026-11-30T00:00:00Z")

    func addedLink(_ links: CalendarLinks) async throws -> CalendarLink {
        let (url, file) = try await links.check("webcal://calendar.example.com/work.ics", against: [])
        let link = CalendarLink(name: file.name ?? "Calendar", colorHex: "#3B82F6")
        try links.add(link, url: url, file: file)
        return link
    }

    @Test func keepsTheLinkInTheKeychainAndShowsItsMeetings() async throws {
        let links = CalendarLinks(secrets: secrets, downloader: server.downloader)
        let link = try await addedLink(links)
        #expect(link.name == "Work")
        #expect(server.requests.map(\.absoluteString) == ["https://calendar.example.com/work.ics"])
        #expect(secrets.value(for: .calendarLink(link.id)) == "https://calendar.example.com/work.ics")
        let events = links.events(for: link, in: week)
        #expect(events.map(\.title).contains("Client sync (moved)"))
        #expect(events.allSatisfy { $0.calendarTitle == "Work" && $0.calendarColorHex == "#3B82F6" })
    }

    @Test func refusesTheSameLinkTwice() async throws {
        let links = CalendarLinks(secrets: secrets, downloader: server.downloader)
        let link = try await addedLink(links)
        await #expect(throws: CalendarLinkAddress.Problem.alreadyAdded("Work")) {
            try await links.check("https://calendar.example.com/work.ics", against: [link])
        }
    }

    @Test func keepsShowingTheLastEventsWhenALinkStopsWorking() async throws {
        let links = CalendarLinks(secrets: secrets, downloader: server.downloader)
        let link = try await addedLink(links)
        server.answer(status: 404)
        await links.refresh(link)
        guard case .failing(let reason, let lastUpdated) = links.state(of: link) else {
            Issue.record("Expected the link to be failing")
            return
        }
        #expect(reason == CalendarDownloader.Problem.notFound.errorDescription)
        #expect(lastUpdated != nil)
        #expect(!links.events(for: link, in: week).isEmpty)

        server.answer(status: 200)
        await links.refresh(link)
        #expect(!links.state(of: link).isFailing)
    }

    @Test func leavesRecentlyDownloadedLinksAlone() async throws {
        let links = CalendarLinks(secrets: secrets, downloader: server.downloader)
        let link = try await addedLink(links)
        await links.refresh([link], olderThan: 300)
        #expect(server.requests.count == 1)
    }

    @Test func forgetsARemovedLink() async throws {
        let links = CalendarLinks(secrets: secrets, downloader: server.downloader)
        let link = try await addedLink(links)
        links.remove(link)
        #expect(secrets.value(for: .calendarLink(link.id)) == nil)
        #expect(links.events(for: link, in: week).isEmpty)
        await links.refresh(link)
        #expect(links.state(of: link).isFailing)
        #expect(!links.hasAddress(for: link))
    }

    @Test func refusesALinkTheKeychainDidNotKeep() async throws {
        let links = CalendarLinks(secrets: ForgetfulSecretStore(), downloader: server.downloader)
        let (url, file) = try await links.check("https://calendar.example.com/work.ics", against: [])
        let link = CalendarLink(name: "Work", colorHex: "#3B82F6")
        #expect(throws: CalendarLinkAddress.Problem.notSaved) { try links.add(link, url: url, file: file) }
        #expect(links.events(for: link, in: week).isEmpty)
    }

    @Test func explainsAWebPageLink() async {
        server.answer(status: 200, body: "<!doctype html><html></html>")
        let links = CalendarLinks(secrets: secrets, downloader: server.downloader)
        await #expect(throws: CalendarFile.Problem.webPage) {
            try await links.check("https://calendar.example.com/page", against: [])
        }
    }
}

/// A Keychain that never keeps anything, as when a save fails.
struct ForgetfulSecretStore: SecretStore {
    func value(for key: SecretKey) -> String? { nil }
    func set(_ value: String?, for key: SecretKey) {}
}

struct CalendarMergeTests {
    func event(_ id: String, _ title: String, _ start: String, calendar: String = "Mac") -> CalendarEvent {
        let date = CalendarFixture.utc(start)
        return CalendarEvent(id: id, title: title, start: date, end: date.addingTimeInterval(3600), isAllDay: false,
                             calendarTitle: calendar, calendarColorHex: "#000000", location: "", attendeeEmails: [], isDeclined: false)
    }

    @Test func showsAMeetingFromBothSourcesOnce() {
        let fromMac = [event("a@1", "Standup", "2026-11-25T09:00:00Z"), event("b@1", "Review", "2026-11-25T11:00:00Z")]
        let fromLinks = [
            event("a@1", "Standup", "2026-11-25T09:00:00Z", calendar: "Link"),
            event("other-id", "review ", "2026-11-25T11:00:00Z", calendar: "Link"),
            event("c@1", "Planning", "2026-11-25T10:00:00Z", calendar: "Link"),
        ]
        let merged = CalendarService.merge(fromMac, fromLinks)
        #expect(merged.map(\.title) == ["Standup", "Planning", "Review"])
        #expect(merged.map(\.calendarTitle) == ["Mac", "Link", "Mac"])
    }

    @Test func oldDataFilesHaveNoLinks() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.calendarLinks.isEmpty)
    }
}
