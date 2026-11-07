import Foundation
import Observation

enum WorkdayWeekStatus: Equatable {
    case empty
    case notSubmitted
    case submitted(WorkdaySubmission)
    case partlySent(WorkdaySubmission)
    case changedSinceSubmitted(WorkdaySubmission)

    init(period: WorkdayPeriod, submission: WorkdaySubmission?) {
        guard let submission else {
            self = period.isEmpty ? .empty : .notSubmitted
            return
        }
        if submission.method == .api && submission.fingerprint.isEmpty {
            self = .partlySent(submission)
        } else if submission.fingerprint != period.fingerprint {
            self = .changedSinceSubmitted(submission)
        } else {
            self = .submitted(submission)
        }
    }

    var title: String {
        switch self {
        case .empty: "No time"
        case .notSubmitted: "Not in Workday yet"
        case .submitted(let s):
            switch s.method {
            case .api: "Sent to Workday \(s.submittedAt.formatted(date: .abbreviated, time: .omitted))"
            case .export: "Exported for Workday \(s.submittedAt.formatted(date: .abbreviated, time: .omitted))"
            case .manual: "Entered in Workday \(s.submittedAt.formatted(date: .abbreviated, time: .omitted))"
            }
        case .partlySent(let s): "Partly sent, \(s.sentBlocks.count) time blocks so far"
        case .changedSinceSubmitted(let s): "Changed since \(s.submittedAt.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// A word or two for the week strip, where there is no room for the full title.
    var shortTitle: String {
        switch self {
        case .empty: "No time"
        case .notSubmitted: "To enter"
        case .submitted(let s): s.method == .api ? "Sent" : s.method == .export ? "Exported" : "Entered"
        case .partlySent: "Partly sent"
        case .changedSinceSubmitted: "Changed"
        }
    }

    var symbol: String {
        switch self {
        case .empty: "minus.circle"
        case .notSubmitted: "circle.dashed"
        case .submitted: "checkmark.circle.fill"
        case .partlySent: "exclamationmark.circle.fill"
        case .changedSinceSubmitted: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .notSubmitted, .partlySent, .changedSinceSubmitted: true
        case .empty, .submitted: false
        }
    }
}

/// Runs Workday sign-in, connection tests and sending, and reports progress to the UI.
@MainActor
@Observable
final class WorkdaySync {
    enum Phase: Equatable {
        case idle
        case working(String)
        case succeeded(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var failures: [String] = []
    /// Bumped when secrets change, because the Keychain is not observable.
    private(set) var secretsRevision = 0

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored var session: URLSession = .shared

    init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    func hasSecret(_ key: SecretKey) -> Bool {
        _ = secretsRevision
        return secrets.value(for: key)?.isEmpty == false
    }

    func saveSecret(_ value: String, for key: SecretKey) {
        secrets.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
        secretsRevision += 1
    }

    func forgetSignIn(store: TimeStore) {
        secrets.set(nil, for: .refreshToken)
        store.workday.api.workerID = ""
        store.workday.api.workerName = ""
        secretsRevision += 1
        phase = .idle
    }

    private func client(_ store: TimeStore) -> WorkdayClient {
        WorkdayClient(config: store.workday.api, secrets: secrets, session: session)
    }

    /// Opens Workday's sign-in page. `authenticate` shows it and returns the callback URL.
    func signIn(store: TimeStore, authenticate: (URL) async throws -> URL) async {
        let state = UUID().uuidString
        phase = .working("Waiting for Workday sign-in…")
        do {
            let callback = try await authenticate(try client(store).authorizationURL(state: state))
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let error = items.first(where: { $0.name == "error" })?.value {
                throw WorkdayError.http(status: 400, message: error)
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw WorkdayError.invalidResponse
            }
            phase = .working("Finishing sign-in…")
            try await client(store).exchange(code: code)
            secretsRevision += 1
            await testConnection(store: store)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func testConnection(store: TimeStore) async {
        phase = .working("Connecting to Workday…")
        do {
            let client = client(store)
            let token = try await client.accessToken()
            secretsRevision += 1
            let worker = try await client.currentWorker(accessToken: token)
            store.workday.api.workerID = worker.id
            store.workday.api.workerName = worker.name
            phase = .succeeded(worker.name.isEmpty ? "Connected to Workday." : "Connected as \(worker.name).")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Time blocks in the week that Workday has not accepted yet.
    func pendingBlocks(in period: WorkdayPeriod, store: TimeStore) -> [(line: WorkdayLine, day: Date)] {
        let sent = Set(store.workdaySubmission(forWeekStarting: period.interval.start)?.sentBlocks ?? [])
        return period.blocks.filter { !sent.contains($0.line.blockKey(for: $0.day)) }
    }

    /// Sends every time block not already accepted, one request each, and records what went through.
    func send(_ period: WorkdayPeriod, store: TimeStore) async {
        failures = []
        let existing = store.workdaySubmission(forWeekStarting: period.interval.start)
        var sent = Set(existing?.method == .api ? existing?.sentBlocks ?? [] : [])
        let blocks = period.blocks.filter { !sent.contains($0.line.blockKey(for: $0.day)) }
        guard !blocks.isEmpty else {
            phase = .succeeded("Everything in this week is already in Workday.")
            return
        }

        phase = .working("Signing in to Workday…")
        do {
            let client = client(store)
            let token = try await client.accessToken()
            var worker = store.workday.api.workerID.trimmingCharacters(in: .whitespaces)
            if worker.isEmpty {
                let found = try await client.currentWorker(accessToken: token)
                store.workday.api.workerID = found.id
                store.workday.api.workerName = found.name
                worker = found.id
            }
            for (index, block) in blocks.enumerated() {
                phase = .working("Sending \(index + 1) of \(blocks.count)…")
                do {
                    let request = try client.timeBlockRequest(line: block.line, day: block.day, worker: worker,
                                                              employeeID: store.workday.employeeID, accessToken: token)
                    try await client.postTimeBlock(request)
                    sent.insert(block.line.blockKey(for: block.day))
                } catch let error as WorkdayError {
                    failures.append("\(Fmt.shortDay(block.day)), \(block.line.timeCode): \(error.localizedDescription)")
                    // Sign-in and set-up problems will fail every block the same way, so stop early.
                    if case .http(let status, _) = error, [401, 403, 404].contains(status) { break }
                    if case .invalidTemplate = error { break }
                    if case .invalidEndpoint = error { break }
                } catch {
                    failures.append("\(Fmt.shortDay(block.day)), \(block.line.timeCode): \(error.localizedDescription)")
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let complete = period.blocks.allSatisfy { sent.contains($0.line.blockKey(for: $0.day)) }
        if !sent.isEmpty {
            store.recordWorkdaySubmission(WorkdaySubmission(
                weekStart: period.interval.start, submittedAt: .now, method: .api, hours: period.total,
                fingerprint: complete ? period.fingerprint : "", sentBlocks: Array(sent).sorted()
            ))
        }
        if complete {
            phase = .succeeded("Sent \(blocks.count) time \(blocks.count == 1 ? "block" : "blocks") to Workday. Submit the week for approval in Workday when you are ready.")
        } else {
            phase = .failed("\(failures.count) of \(blocks.count) time blocks were not accepted. Fix the problem and send again; blocks already accepted are not sent twice.")
        }
    }

    func dismissMessage() {
        if !isWorking { phase = .idle }
        failures = []
    }
}
