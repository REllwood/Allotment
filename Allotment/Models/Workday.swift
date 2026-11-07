import Foundation

enum WorkdayCommentStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case notes
    case clientAndNotes
    case none

    var id: Self { self }

    var title: String {
        switch self {
        case .notes: "Your notes"
        case .clientAndNotes: "Client and notes"
        case .none: "No comment"
        }
    }
}

/// The Workday project and task that an Allotment project's time goes to.
struct WorkdayProjectCode: Codable, Hashable, Sendable {
    var project = ""
    var task = ""
}

enum WorkdaySubmissionMethod: String, Codable, Sendable {
    /// You entered the time in Workday yourself and ticked the week off.
    case manual
    /// Allotment sent the time through the Workday API.
    case api
    /// An import sheet was exported for a Workday admin.
    case export
}

/// A record that a week's time has gone into Workday, so changes made afterwards can be spotted.
struct WorkdaySubmission: Codable, Hashable, Sendable {
    var weekStart: Date
    var submittedAt: Date
    var method: WorkdaySubmissionMethod
    var hours: Double
    var fingerprint: String
    /// Time blocks already accepted by the API, so a retry only sends what failed.
    var sentBlocks: [String] = []
}

extension WorkdaySubmission {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekStart = try c.decode(Date.self, forKey: .weekStart)
        submittedAt = try c.decode(Date.self, forKey: .submittedAt)
        method = try c.decodeIfPresent(WorkdaySubmissionMethod.self, forKey: .method) ?? .manual
        hours = try c.decodeIfPresent(Double.self, forKey: .hours) ?? 0
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        sentBlocks = try c.decodeIfPresent([String].self, forKey: .sentBlocks) ?? []
    }
}

/// Connection details for sending time through the Workday REST API. Secrets live in the Keychain, not here.
struct WorkdayAPIConfig: Codable, Hashable, Sendable {
    /// The "Workday REST API Endpoint" shown when the API client is registered, such as
    /// https://wd2-impl-services1.workday.com/ccx/api/v1/acme
    var restEndpoint = ""
    var tokenEndpoint = ""
    var authorizationEndpoint = ""
    var clientID = ""
    /// The worker's Workday ID, found with "Test connection" or typed in.
    var workerID = ""
    var workerName = ""
    /// Path after /ccx/api/ used to look up the signed-in worker.
    var workerPath = WorkdayAPIConfig.defaultWorkerPath
    /// Path after /ccx/api/ used to create one time block. {tenant} and {worker} are filled in.
    var timeBlockPath = WorkdayAPIConfig.defaultTimeBlockPath
    /// JSON sent for each time block. See `WorkdayTemplate` for the placeholders.
    var bodyTemplate = WorkdayAPIConfig.defaultBodyTemplate

    static let redirectURI = "allotment://workday/callback"
    static let callbackScheme = "allotment"
    static let defaultWorkerPath = "common/v1/{tenant}/workers/me"
    static let defaultTimeBlockPath = "timeTracking/v5/{tenant}/workers/{worker}/timeBlocks"
    static let defaultBodyTemplate = """
    {
      "date": "{{date}}",
      "quantity": "{{hours}}",
      "timeEntryCode": { "id": "{{timeCode}}" },
      "project": { "id": "{{project}}" },
      "projectPlanTask": { "id": "{{task}}" },
      "comment": "{{comment}}"
    }
    """

    var isConfigured: Bool {
        !restEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !tokenEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {}
}

extension WorkdayAPIConfig {
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restEndpoint = try c.decodeIfPresent(String.self, forKey: .restEndpoint) ?? ""
        tokenEndpoint = try c.decodeIfPresent(String.self, forKey: .tokenEndpoint) ?? ""
        authorizationEndpoint = try c.decodeIfPresent(String.self, forKey: .authorizationEndpoint) ?? ""
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        workerID = try c.decodeIfPresent(String.self, forKey: .workerID) ?? ""
        workerName = try c.decodeIfPresent(String.self, forKey: .workerName) ?? ""
        workerPath = try c.decodeIfPresent(String.self, forKey: .workerPath) ?? Self.defaultWorkerPath
        timeBlockPath = try c.decodeIfPresent(String.self, forKey: .timeBlockPath) ?? Self.defaultTimeBlockPath
        bodyTemplate = try c.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? Self.defaultBodyTemplate
    }
}

/// How Allotment's clients, projects and activities line up with Workday's time entry codes and projects.
struct WorkdayConfig: Codable, Hashable, Sendable {
    var isEnabled = false
    /// Employee ID, used in the import sheet for admins.
    var employeeID = ""
    /// Used for activities without a code of their own.
    var defaultTimeCode = ""
    /// Hours are rounded to this step per day and line, as Workday time entry codes usually require. 0 keeps two decimals.
    var incrementHours = 0.25
    var commentStyle: WorkdayCommentStyle = .notes
    /// Keyed by activity ID.
    var activityCodes: [String: String] = [:]
    /// Keyed by client ID. Used when a project has no Workday project of its own.
    var clientProjects: [String: String] = [:]
    /// Keyed by project ID.
    var projectCodes: [String: WorkdayProjectCode] = [:]
    /// Keyed by the first day of the week, as yyyy-MM-dd.
    var submissions: [String: WorkdaySubmission] = [:]
    var api = WorkdayAPIConfig()

    init() {}

    static let increments: [(title: String, hours: Double)] = [
        ("0.1 hour (6 minutes)", 0.1), ("0.25 hour (15 minutes)", 0.25), ("0.5 hour (30 minutes)", 0.5), ("Exact, two decimals", 0),
    ]

    func timeCode(for activityID: UUID?) -> String {
        let own = activityID.flatMap { activityCodes[$0.uuidString] }?.trimmingCharacters(in: .whitespaces) ?? ""
        return own.isEmpty ? defaultTimeCode.trimmingCharacters(in: .whitespaces) : own
    }

    func projectAndTask(clientID: UUID?, projectID: UUID?) -> WorkdayProjectCode {
        let own = projectID.flatMap { projectCodes[$0.uuidString] } ?? WorkdayProjectCode()
        let project = own.project.trimmingCharacters(in: .whitespaces)
        let fallback = clientID.flatMap { clientProjects[$0.uuidString] }?.trimmingCharacters(in: .whitespaces) ?? ""
        return WorkdayProjectCode(project: project.isEmpty ? fallback : project, task: own.task.trimmingCharacters(in: .whitespaces))
    }

    func round(_ hours: Double) -> Double {
        guard incrementHours > 0 else { return (hours * 100).rounded() / 100 }
        let steps = (hours / incrementHours).rounded()
        // Tidy floating point noise such as 0.30000000000000004.
        return ((steps * incrementHours) * 100).rounded() / 100
    }
}

extension WorkdayConfig {
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        employeeID = try c.decodeIfPresent(String.self, forKey: .employeeID) ?? ""
        defaultTimeCode = try c.decodeIfPresent(String.self, forKey: .defaultTimeCode) ?? ""
        incrementHours = try c.decodeIfPresent(Double.self, forKey: .incrementHours) ?? 0.25
        commentStyle = try c.decodeIfPresent(WorkdayCommentStyle.self, forKey: .commentStyle) ?? .notes
        activityCodes = try c.decodeIfPresent([String: String].self, forKey: .activityCodes) ?? [:]
        clientProjects = try c.decodeIfPresent([String: String].self, forKey: .clientProjects) ?? [:]
        projectCodes = try c.decodeIfPresent([String: WorkdayProjectCode].self, forKey: .projectCodes) ?? [:]
        submissions = try c.decodeIfPresent([String: WorkdaySubmission].self, forKey: .submissions) ?? [:]
        api = try c.decodeIfPresent(WorkdayAPIConfig.self, forKey: .api) ?? WorkdayAPIConfig()
    }
}
