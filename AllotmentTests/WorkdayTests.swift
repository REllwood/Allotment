import Foundation
import Testing
@testable import Allotment

@MainActor
struct WorkdayBuilderTests {
    /// One client with a mapped project, plus internal admin, over a Monday and Tuesday.
    private func makeStore() -> (TimeStore, Client, Project) {
        let store = TimeStore(fileURL: nil)
        let acme = store.newClient(named: "Acme")
        let site = Project(clientID: acme.id, name: "Website")
        store.save(site)
        var config = WorkdayConfig()
        config.isEnabled = true
        config.employeeID = "21004"
        config.defaultTimeCode = "REG"
        config.activityCodes[Activity.adminID.uuidString] = "ADM"
        config.clientProjects[acme.id.uuidString] = "PRJ-1"
        config.projectCodes[site.id.uuidString] = WorkdayProjectCode(project: "PRJ-2", task: "Build")
        store.workday = config

        let mon = { (h: Int, m: Int) in Fixture.localDate(2026, 11, 2, h, m) }
        let tue = { (h: Int, m: Int) in Fixture.localDate(2026, 11, 3, h, m) }
        store.save(TimeEntry(clientID: acme.id, projectID: site.id, activityID: Activity.clientWorkID, notes: "Header",
                             start: mon(9, 0), end: mon(10, 7), isBillable: true))
        store.save(TimeEntry(clientID: acme.id, projectID: site.id, activityID: Activity.clientWorkID, notes: "Footer",
                             start: mon(10, 7), end: mon(11, 0), isBillable: true))
        store.save(TimeEntry(clientID: nil, activityID: Activity.adminID, notes: "Invoices",
                             start: mon(13, 0), end: mon(13, 20), isBillable: false))
        store.save(TimeEntry(clientID: acme.id, activityID: Activity.meetingID, notes: "Weekly sync",
                             start: tue(9, 0), end: tue(9, 50), isBillable: true))
        return (store, acme, site)
    }

    private var week: DateInterval { WorkSchedule(settings: AppSettings()).week(containing: Fixture.localDate(2026, 11, 4)) }

    @Test func groupsByCodeProjectAndTask() {
        let (store, _, _) = makeStore()
        let period = WorkdayBuilder.build(week, store: store, now: Fixture.localDate(2026, 11, 9))
        let monday = Fixture.localDate(2026, 11, 2)
        let tuesday = Fixture.localDate(2026, 11, 3)

        let build = period.lines.first { $0.id == "REG|PRJ-2|Build" }
        #expect(build?.hours[monday] == 2)
        #expect(build?.comments[monday] == "Header; Footer")
        #expect(build?.title == "Acme: Website")

        // 20 minutes rounds to a quarter hour.
        let admin = period.lines.first { $0.id == "ADM||" }
        #expect(admin?.hours[monday] == 0.25)
        #expect(admin?.title == "Internal admin")

        // A project-less entry falls back to the client's Workday project, and Meeting falls back to the default code.
        let meeting = period.lines.first { $0.id == "REG|PRJ-1|" }
        #expect(meeting?.hours[tuesday] == 0.75)

        #expect(period.lines.count == 3)
        #expect(period.total == 3)
        #expect(period.blocks.count == 3)
        #expect(period.issues.contains { $0.id == "rounding" })
        #expect(!period.issues.contains { $0.severity == .warning })
    }

    @Test func missingCodesAreFlagged() {
        let (store, _, _) = makeStore()
        store.workday.defaultTimeCode = ""
        let period = WorkdayBuilder.build(week, store: store, now: Fixture.localDate(2026, 11, 9))
        #expect(period.issues.contains { $0.severity == .warning && $0.message.hasPrefix("Client work") })
        #expect(period.issues.contains { $0.severity == .warning && $0.message.hasPrefix("Meeting") })
    }

    @Test func fingerprintFollowsTheHours() {
        let (store, acme, _) = makeStore()
        let now = Fixture.localDate(2026, 11, 9)
        let first = WorkdayBuilder.build(week, store: store, now: now).fingerprint
        #expect(WorkdayBuilder.build(week, store: store, now: now).fingerprint == first)
        store.save(TimeEntry(clientID: acme.id, activityID: Activity.clientWorkID, start: Fixture.localDate(2026, 11, 4, 9),
                             end: Fixture.localDate(2026, 11, 4, 10), isBillable: true))
        #expect(WorkdayBuilder.build(week, store: store, now: now).fingerprint != first)
    }

    @Test func weekStatusTracksSubmissions() {
        let (store, _, _) = makeStore()
        let now = Fixture.localDate(2026, 11, 9)
        let period = WorkdayBuilder.build(week, store: store, now: now)
        #expect(WorkdayWeekStatus(period: period, submission: nil) == .notSubmitted)

        let manual = WorkdaySubmission(weekStart: week.start, submittedAt: now, method: .manual, hours: 3, fingerprint: period.fingerprint)
        #expect(WorkdayWeekStatus(period: period, submission: manual) == .submitted(manual))

        var changed = manual
        changed.fingerprint = "old"
        #expect(WorkdayWeekStatus(period: period, submission: changed) == .changedSinceSubmitted(changed))

        let partial = WorkdaySubmission(weekStart: week.start, submittedAt: now, method: .api, hours: 3, fingerprint: "", sentBlocks: ["x"])
        #expect(WorkdayWeekStatus(period: period, submission: partial) == .partlySent(partial))
    }

    @Test func outstandingWeeksSkipSubmittedOnes() {
        let (store, _, _) = makeStore()
        let now = Fixture.localDate(2026, 11, 11, 12)
        #expect(WorkdayBuilder.outstandingWeeks(store: store, now: now).count == 1)
        let period = WorkdayBuilder.build(week, store: store, now: now)
        store.recordWorkdaySubmission(WorkdaySubmission(weekStart: week.start, submittedAt: now, method: .manual,
                                                        hours: period.total, fingerprint: period.fingerprint))
        #expect(WorkdayBuilder.outstandingWeeks(store: store, now: now).isEmpty)
    }

    @Test func importSheetHasOneRowPerBlock() throws {
        let (store, _, _) = makeStore()
        let period = WorkdayBuilder.build(week, store: store, now: Fixture.localDate(2026, 11, 9))
        let text = String(decoding: WorkdayExporter.csv(period).dropFirst(3), as: UTF8.self)
        let rows = text.split(separator: "\r\n")
        #expect(rows.first == "Spreadsheet Key,Worker,Date,Time Entry Code,Quantity,Project,Project Task,Comment")
        #expect(rows.count == period.blocks.count + 1)
        #expect(rows.contains { $0.contains("21004,2026-11-02,REG,2.00,PRJ-2,Build,Header; Footer") })

        let excel = WorkdayExporter.excel(period)
        #expect(excel.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        let folder = FileManager.default.temporaryDirectory.appending(path: "AllotmentExportCheck")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try excel.write(to: folder.appending(path: "workday.xlsx"))
    }

    @Test func roundingSteps() {
        var config = WorkdayConfig()
        config.incrementHours = 0.25
        #expect(config.round(0.33) == 0.25)
        #expect(config.round(0.38) == 0.5)
        config.incrementHours = 0.1
        #expect(config.round(0.34) == 0.3)
        config.incrementHours = 0
        #expect(config.round(1.23456) == 1.23)
    }

    @Test func isoDayUsesTheLocalDate() {
        // Just after local midnight is the previous day in UTC for anyone east of Greenwich.
        let date = Fixture.localDate(2026, 11, 2, 0, 30)
        #expect(Fmt.isoDay(date) == "2026-11-02")
    }
}

struct WorkdayTemplateTests {
    @Test func fillsValuesAndDropsEmptyOnes() throws {
        let data = try WorkdayTemplate.render(WorkdayAPIConfig.defaultBodyTemplate, values: [
            "date": "2026-11-02", "timeCode": "REG", "project": "", "task": "", "comment": "Header \"v2\"",
        ], hours: 2.5)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["date"] as? String == "2026-11-02")
        #expect(json["quantity"] as? Double == 2.5)
        #expect((json["timeEntryCode"] as? [String: Any])?["id"] as? String == "REG")
        #expect(json["project"] == nil)
        #expect(json["projectPlanTask"] == nil)
        #expect(json["comment"] as? String == "Header \"v2\"")
    }

    @Test func rejectsBrokenTemplates() {
        #expect(throws: WorkdayError.self) {
            try WorkdayTemplate.render("{ not json", values: [:], hours: 1)
        }
    }

    @Test func parsesEndpoints() throws {
        let endpoint = try WorkdayEndpoint(restEndpoint: " https://wd2-impl-services1.workday.com/ccx/api/v1/acme ")
        #expect(endpoint.tenant == "acme")
        #expect(endpoint.base.absoluteString == "https://wd2-impl-services1.workday.com")
        #expect(try endpoint.url(for: "/timeTracking/v5/{tenant}/workers/{worker}/timeBlocks", worker: "w1").absoluteString
            == "https://wd2-impl-services1.workday.com/ccx/api/timeTracking/v5/acme/workers/w1/timeBlocks")
        #expect(throws: WorkdayError.self) { try WorkdayEndpoint(restEndpoint: "http://insecure.example.com/ccx/api/v1/acme") }
        #expect(throws: WorkdayError.self) { try WorkdayEndpoint(restEndpoint: "https://example.com/somewhere") }
    }

    @Test func readsWorkdayErrors() {
        let body = Data(#"{"error":"Validation error occurred.","errors":[{"error":"Invalid time entry code","field":"timeEntryCode"}]}"#.utf8)
        #expect(WorkdayClient.errorMessage(from: body) == "Validation error occurred. timeEntryCode: Invalid time entry code")
    }
}

/// A pretend Workday server. Requests are recorded so tests can check exactly what was sent.
final class FakeWorkday: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var failingDate: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = body
        }
        Self.requests.append(recorded)

        let path = request.url?.path() ?? ""
        let body = String(decoding: recorded.httpBody ?? Data(), as: UTF8.self)
        let (status, json): (Int, String) = if path.hasSuffix("/token") {
            (200, #"{"access_token":"access-1","refresh_token":"refresh-2","token_type":"Bearer"}"#)
        } else if path.hasSuffix("/workers/me") {
            (200, #"{"id":"w123","descriptor":"Rhys Ellwood"}"#)
        } else if let failing = Self.failingDate, body.contains(failing) {
            (400, #"{"error":"Validation error occurred.","errors":[{"error":"Day is locked"}]}"#)
        } else {
            (201, #"{"id":"tb-1"}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
@Suite(.serialized)
struct WorkdaySyncTests {
    private func makeSync() -> (WorkdaySync, TimeStore, MemorySecretStore, WorkdayPeriod) {
        let now = Fixture.localDate(2026, 11, 20, 15)
        let store = TimeStore(fileURL: nil)
        var data = SampleData.make(now: now)
        data.workday = SampleData.workday(for: data, keeping: WorkdayConfig())
        data.workday.api.restEndpoint = "https://wd.example.com/ccx/api/v1/acme"
        data.workday.api.tokenEndpoint = "https://wd.example.com/ccx/oauth2/acme/token"
        data.workday.api.clientID = "client-1"
        store.replaceAll(with: data)
        store.stopTimer(at: now)

        let secrets = MemorySecretStore()
        secrets.set("secret-1", for: .clientSecret)
        secrets.set("refresh-1", for: .refreshToken)
        let sync = WorkdaySync(secrets: secrets)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeWorkday.self]
        sync.session = URLSession(configuration: configuration)

        let week = store.schedule.week(containing: Fixture.localDate(2026, 11, 11))
        FakeWorkday.requests = []
        FakeWorkday.failingDate = nil
        return (sync, store, secrets, WorkdayBuilder.build(week, store: store, now: now))
    }

    @Test func sendsEachBlockAndRecordsTheWeek() async throws {
        let (sync, store, secrets, period) = makeSync()
        await sync.send(period, store: store)

        guard case .succeeded = sync.phase else {
            Issue.record("Expected success, got \(sync.phase)")
            return
        }
        let token = try #require(FakeWorkday.requests.first)
        #expect(token.url?.absoluteString == "https://wd.example.com/ccx/oauth2/acme/token")
        #expect(token.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("client-1:secret-1".utf8).base64EncodedString())
        #expect(String(decoding: token.httpBody ?? Data(), as: UTF8.self) == "grant_type=refresh_token&refresh_token=refresh-1")
        #expect(secrets.value(for: .refreshToken) == "refresh-2")
        #expect(store.workday.api.workerID == "w123")

        let blocks = FakeWorkday.requests.filter { $0.url?.path().hasSuffix("/timeBlocks") == true }
        #expect(blocks.count == period.blocks.count)
        let first = try #require(blocks.first)
        #expect(first.url?.absoluteString == "https://wd.example.com/ccx/api/timeTracking/v5/acme/workers/w123/timeBlocks")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        let json = try #require(try JSONSerialization.jsonObject(with: first.httpBody ?? Data()) as? [String: Any])
        #expect(json["date"] is String)
        #expect(json["quantity"] is Double)
        #expect((json["timeEntryCode"] as? [String: Any])?["id"] is String)

        let submission = try #require(store.workdaySubmission(forWeekStarting: period.interval.start))
        #expect(submission.method == .api)
        #expect(submission.fingerprint == period.fingerprint)
        #expect(submission.sentBlocks.count == period.blocks.count)
    }

    @Test func retryOnlySendsWhatFailed() async throws {
        let (sync, store, _, period) = makeSync()
        let failingDay = try #require(period.blocks.first?.day)
        FakeWorkday.failingDate = Fmt.isoDay(failingDay)
        await sync.send(period, store: store)

        guard case .failed = sync.phase else {
            Issue.record("Expected a partial failure, got \(sync.phase)")
            return
        }
        let failedCount = period.blocks.filter { $0.day == failingDay }.count
        #expect(sync.failures.count == failedCount)
        #expect(sync.failures.first?.contains("Day is locked") == true)
        let partial = try #require(store.workdaySubmission(forWeekStarting: period.interval.start))
        #expect(partial.isPartial)
        #expect(partial.sentBlocks.count == period.blocks.count - failedCount)

        FakeWorkday.requests = []
        FakeWorkday.failingDate = nil
        await sync.send(period, store: store)
        #expect(FakeWorkday.requests.filter { $0.url?.path().hasSuffix("/timeBlocks") == true }.count == failedCount)
        #expect(store.workdaySubmission(forWeekStarting: period.interval.start)?.fingerprint == period.fingerprint)
        #expect(store.workdaySubmission(forWeekStarting: period.interval.start)?.isPartial == false)
    }

    @Test func dismissingAFailureClearsItsDetails() async throws {
        let (sync, store, _, period) = makeSync()
        FakeWorkday.failingDate = Fmt.isoDay(try #require(period.blocks.first?.day))
        await sync.send(period, store: store)
        #expect(!sync.failures.isEmpty)
        sync.dismissMessage()
        #expect(sync.phase == .idle)
        #expect(sync.failures.isEmpty)
    }

    @Test func missingSecretsStopBeforeAnyRequest() async {
        let (sync, store, secrets, period) = makeSync()
        secrets.set(nil, for: .refreshToken)
        await sync.send(period, store: store)
        guard case .failed(let message, _) = sync.phase else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message.contains("refresh token"))
        #expect(FakeWorkday.requests.isEmpty)
    }
}
