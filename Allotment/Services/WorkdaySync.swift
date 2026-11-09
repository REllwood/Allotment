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
        if submission.isPartial {
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

/// How far the Workday API connection is set up, worked out from the saved settings and the Keychain.
///
///     incomplete ──endpoints, client ID and client secret all filled in──▶ signedOut
///     signedOut ──sign in, or paste a refresh token──▶ signedIn
///     signedIn ──sign out──▶ signedOut
///
/// Clearing a field moves back to incomplete from either of the others.
struct WorkdayConnection: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Lists what still has to be filled in, in the order the setup screen shows it.
        case incomplete(missing: [String])
        case signedOut
        /// `worker` is the name or ID found by the last connection test, if there has been one.
        case signedIn(worker: String?)
    }

    var stage: Stage
    /// Whether "Sign in with Workday" can open Workday's sign-in page, which also needs the authorization endpoint.
    var canSignIn: Bool

    init(config: WorkdayAPIConfig, hasClientSecret: Bool, hasRefreshToken: Bool) {
        let filled = { (text: String) in !text.trimmingCharacters(in: .whitespaces).isEmpty }
        var missing: [String] = []
        if !filled(config.restEndpoint) { missing.append("REST API endpoint") }
        if !filled(config.tokenEndpoint) { missing.append("token endpoint") }
        if !filled(config.clientID) { missing.append("client ID") }
        if !hasClientSecret { missing.append("client secret") }

        if !missing.isEmpty {
            stage = .incomplete(missing: missing)
        } else if hasRefreshToken {
            let worker = filled(config.workerName) ? config.workerName : filled(config.workerID) ? config.workerID : nil
            stage = .signedIn(worker: worker)
        } else {
            stage = .signedOut
        }
        canSignIn = missing.isEmpty && filled(config.authorizationEndpoint)
    }

    var isSignedIn: Bool {
        if case .signedIn = stage { return true }
        return false
    }

    /// One line for the setup screen.
    var summary: String {
        switch stage {
        case .incomplete(let missing):
            "To connect, add the \(Self.list(missing))."
        case .signedOut:
            canSignIn ? "Ready to sign in with Workday." : "Paste a refresh token, or add the authorization endpoint to sign in with Workday."
        case .signedIn(let worker?):
            "Signed in as \(worker)."
        case .signedIn(nil):
            "Signed in. Test the connection to check it works."
        }
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Runs Workday sign-in, connection tests and sending, and reports progress to the UI.
///
///     idle / succeeded / failed ──start sign-in, a test or a send──▶ working(progress)
///     working ──finished──▶ succeeded(message) or failed(message, details)
///     succeeded / failed ──dismiss──▶ idle
///
/// Only one operation runs at a time: starting another while working does nothing.
@MainActor
@Observable
final class WorkdaySync {
    enum Phase: Equatable {
        case idle
        case working(String)
        case succeeded(String)
        /// `details` lists each time block Workday did not accept, when a send fails part way.
        case failed(String, details: [String] = [])
    }

    private(set) var phase: Phase = .idle
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

    /// The time blocks that failed in the last send.
    var failures: [String] {
        if case .failed(_, let details) = phase { return details }
        return []
    }

    func connection(for config: WorkdayAPIConfig) -> WorkdayConnection {
        WorkdayConnection(config: config, hasClientSecret: hasSecret(.clientSecret), hasRefreshToken: hasSecret(.refreshToken))
    }

    func hasSecret(_ key: SecretKey) -> Bool {
        _ = secretsRevision
        return secrets.contains(key)
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
        guard !isWorking else { return }
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
            await checkWorker(store: store)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func testConnection(store: TimeStore) async {
        guard !isWorking else { return }
        await checkWorker(store: store)
    }

    /// Fetches the signed-in worker, which proves the connection works end to end.
    private func checkWorker(store: TimeStore) async {
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
        guard !isWorking else { return }
        var rejected: [String] = []
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
                    rejected.append("\(Fmt.shortDay(block.day)), \(block.line.timeCode): \(error.localizedDescription)")
                    // Sign-in and set-up problems will fail every block the same way, so stop early.
                    if case .http(let status, _) = error, [401, 403, 404].contains(status) { break }
                    if case .invalidTemplate = error { break }
                    if case .invalidEndpoint = error { break }
                } catch {
                    rejected.append("\(Fmt.shortDay(block.day)), \(block.line.timeCode): \(error.localizedDescription)")
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let complete = period.blocks.allSatisfy { sent.contains($0.line.blockKey(for: $0.day)) }
        if !sent.isEmpty {
            // An empty fingerprint marks the week as partly sent (see `WorkdaySubmission.isPartial`).
            store.recordWorkdaySubmission(WorkdaySubmission(
                weekStart: period.interval.start, submittedAt: .now, method: .api, hours: period.total,
                fingerprint: complete ? period.fingerprint : "", sentBlocks: Array(sent).sorted()
            ))
        }
        if complete {
            phase = .succeeded("Sent \(blocks.count) time \(blocks.count == 1 ? "block" : "blocks") to Workday. Submit the week for approval in Workday when you are ready.")
        } else {
            phase = .failed("\(rejected.count) of \(blocks.count) time blocks were not accepted. Fix the problem and send again. Blocks already accepted are not sent twice.",
                            details: rejected)
        }
    }

    func dismissMessage() {
        if !isWorking { phase = .idle }
    }
}
