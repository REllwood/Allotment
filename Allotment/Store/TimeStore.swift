import Foundation
import Observation

/// Whether the data file is being read and written. Shown in the menu bar panel when something went wrong.
///
///     healthy ──file cannot be read at launch──▶ couldNotRead   (the file is moved aside, the app starts empty)
///     any ──a save fails──▶ couldNotSave
///     couldNotSave ──a later save works──▶ healthy
///     couldNotRead ──you dismiss it──▶ healthy   (saving works, so it stays until you have seen it)
enum StorageStatus: Equatable, Sendable {
    case healthy
    case couldNotRead(reason: String, keptAs: URL)
    case couldNotSave(reason: String)

    /// What to tell you, or nil when all is well.
    var message: String? {
        switch self {
        case .healthy:
            nil
        case .couldNotRead(let reason, let keptAs):
            "Your saved data could not be read (\(reason)). It was kept as \(keptAs.lastPathComponent)."
        case .couldNotSave(let reason):
            "Saving failed: \(reason)"
        }
    }
}

/// The single source of truth for clients, projects, activities, entries and settings.
/// Data lives in one JSON file and is saved shortly after every change.
@MainActor
@Observable
final class TimeStore {
    private(set) var data: AppData {
        didSet { scheduleSave() }
    }

    private(set) var storage: StorageStatus = .healthy

    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Pass `nil` for an in-memory store that never touches the disk.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        data = AppData()
        guard let fileURL else { return }
        switch Self.load(from: fileURL) {
        case .success(let loaded?):
            data = loaded
        case .success(nil):
            break
        case .failure(let error):
            // Keep the unreadable file so nothing is lost, then start fresh.
            let keep = fileURL.deletingLastPathComponent().appending(path: "data.unreadable.json")
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.moveItem(at: fileURL, to: keep)
            storage = .couldNotRead(reason: error.localizedDescription, keptAs: keep)
        }
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The folder keeps the app's original name, TimeTraka, so data saved before the rename is still found.
        return base.appending(path: "TimeTraka", directoryHint: .isDirectory).appending(path: "data.json")
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> Result<AppData?, Error> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
        do {
            let raw = try Data(contentsOf: url)
            return .success(try decoder.decode(AppData.self, from: raw))
        } catch {
            return .failure(error)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(data).write(to: fileURL, options: .atomic)
            if case .couldNotSave = storage { storage = .healthy }
        } catch {
            storage = .couldNotSave(reason: error.localizedDescription)
        }
    }

    /// Clears a read problem once you have seen it. A save problem clears itself when saving works again.
    func dismissStorageProblem() {
        if case .couldNotRead = storage { storage = .healthy }
    }

    func exportBackup(to url: URL) throws {
        try Self.encoder.encode(data).write(to: url, options: .atomic)
    }

    /// Replaces everything with a backup. The current data is kept beside the data file first.
    func importBackup(from url: URL) throws {
        let imported = try Self.decoder.decode(AppData.self, from: Data(contentsOf: url))
        if let fileURL {
            let keep = fileURL.deletingLastPathComponent().appending(path: "data.before-import.json")
            try? Self.encoder.encode(data).write(to: keep, options: .atomic)
        }
        data = imported
    }

    func replaceAll(with newData: AppData) {
        data = newData
    }

    func eraseAllData() {
        var fresh = AppData()
        fresh.settings = data.settings
        data = fresh
    }

    // MARK: - Lookups

    var settings: AppSettings {
        get { data.settings }
        set { data.settings = newValue }
    }

    var schedule: WorkSchedule { WorkSchedule(settings: data.settings) }

    var workday: WorkdayConfig {
        get { data.workday }
        set { data.workday = newValue }
    }

    func workdaySubmission(forWeekStarting start: Date) -> WorkdaySubmission? {
        data.workday.submissions[Fmt.isoDay(start)]
    }

    func recordWorkdaySubmission(_ submission: WorkdaySubmission) {
        data.workday.submissions[Fmt.isoDay(submission.weekStart)] = submission
    }

    func clearWorkdaySubmission(forWeekStarting start: Date) {
        data.workday.submissions[Fmt.isoDay(start)] = nil
    }

    var clients: [Client] { data.clients }

    var activeClients: [Client] {
        data.clients.filter { !$0.isArchived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var favoriteClients: [Client] { activeClients.filter(\.isFavorite) }

    var activities: [Activity] { data.activities.filter { !$0.isArchived } }

    var allActivities: [Activity] { data.activities }

    var entries: [TimeEntry] { data.entries }

    var adminActivity: Activity? {
        activities.first { $0.id == Activity.adminID } ?? activities.first(where: \.isAdmin)
    }

    var meetingActivity: Activity? {
        activities.first { $0.id == Activity.meetingID }
    }

    func client(_ id: UUID?) -> Client? {
        guard let id else { return nil }
        return data.clients.first { $0.id == id }
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return data.projects.first { $0.id == id }
    }

    func activity(_ id: UUID?) -> Activity? {
        guard let id else { return nil }
        return data.activities.first { $0.id == id }
    }

    func projects(for clientID: UUID?, includeArchived: Bool = false) -> [Project] {
        guard let clientID else { return [] }
        return data.projects
            .filter { $0.clientID == clientID && (includeArchived || !$0.isArchived) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func entry(_ id: UUID?) -> TimeEntry? {
        guard let id else { return nil }
        return data.entries.first { $0.id == id }
    }

    var runningEntry: TimeEntry? { data.entries.last(where: \.isRunning) }

    /// Entries that start inside the interval, oldest first.
    func entries(in interval: DateInterval) -> [TimeEntry] {
        data.entries
            .filter { $0.start >= interval.start && $0.start < interval.end }
            .sorted { $0.start < $1.start }
    }

    func entries(for clientID: UUID?) -> [TimeEntry] {
        data.entries.filter { $0.clientID == clientID }
    }

    func hours(clientID: UUID?, in interval: DateInterval, now: Date = .now) -> Double {
        entries(in: interval)
            .filter { $0.clientID == clientID }
            .reduce(0) { $0 + $1.duration(at: now) } / 3600
    }

    func totalHours(in interval: DateInterval, now: Date = .now) -> Double {
        entries(in: interval).reduce(0) { $0 + $1.duration(at: now) } / 3600
    }

    func projectHours(_ projectID: UUID, now: Date = .now) -> Double {
        data.entries.filter { $0.projectID == projectID }.reduce(0) { $0 + $1.duration(at: now) } / 3600
    }

    /// The most recent distinct pieces of work, for one-click resume.
    func recentWork(limit: Int = 5) -> [TimeEntry] {
        var seen = Set<String>()
        var result: [TimeEntry] = []
        for entry in data.entries.sorted(by: { $0.start > $1.start }) where !entry.isRunning {
            let key = "\(entry.clientID?.uuidString ?? "-")|\(entry.projectID?.uuidString ?? "-")|\(entry.activityID?.uuidString ?? "-")|\(entry.notes)"
            if seen.insert(key).inserted {
                result.append(entry)
                if result.count == limit { break }
            }
        }
        return result
    }

    var loggedEventKeys: Set<String> { Set(data.entries.compactMap(\.calendarEventKey)) }

    var dismissedEventKeys: Set<String> { data.dismissedEventKeys }

    func rate(for clientID: UUID?) -> Double {
        client(clientID)?.hourlyRate ?? data.settings.defaultHourlyRate
    }

    func defaultBillable(clientID: UUID?, projectID: UUID?, activityID: UUID?) -> Bool {
        guard clientID != nil else { return false }
        if let activity = activity(activityID), !activity.isBillable { return false }
        return project(projectID)?.isBillable ?? true
    }

    // MARK: - Timer

    @discardableResult
    func startTimer(clientID: UUID?, projectID: UUID? = nil, activityID: UUID? = nil, notes: String = "", at start: Date = .now) -> TimeEntry {
        stopTimer(at: start)
        let entry = TimeEntry(
            clientID: clientID,
            projectID: projectID,
            activityID: activityID,
            notes: notes,
            start: start,
            end: nil,
            isBillable: defaultBillable(clientID: clientID, projectID: projectID, activityID: activityID),
            source: .timer
        )
        data.entries.append(entry)
        return entry
    }

    func stopTimer(at end: Date = .now) {
        guard let index = data.entries.lastIndex(where: \.isRunning) else { return }
        let stopAt = max(end, data.entries[index].start)
        // A timer stopped within a few seconds was almost certainly started by accident.
        if stopAt.timeIntervalSince(data.entries[index].start) < 5 {
            data.entries.remove(at: index)
        } else {
            data.entries[index].end = stopAt
        }
    }

    func discardRunningTimer() {
        data.entries.removeAll(where: \.isRunning)
    }

    func resume(_ entry: TimeEntry) {
        startTimer(clientID: entry.clientID, projectID: entry.projectID, activityID: entry.activityID, notes: entry.notes)
    }

    func updateRunning(_ change: (inout TimeEntry) -> Void) {
        guard let index = data.entries.lastIndex(where: \.isRunning) else { return }
        change(&data.entries[index])
    }

    // MARK: - Entries

    func save(_ entry: TimeEntry) {
        var entry = entry
        if let end = entry.end, end < entry.start { entry.end = entry.start }
        if entry.isRunning {
            // Only one timer can run at a time.
            for i in data.entries.indices where data.entries[i].isRunning && data.entries[i].id != entry.id {
                data.entries[i].end = max(entry.start, data.entries[i].start)
            }
        }
        if let index = data.entries.firstIndex(where: { $0.id == entry.id }) {
            data.entries[index] = entry
        } else {
            data.entries.append(entry)
        }
    }

    func deleteEntry(_ id: UUID) {
        data.entries.removeAll { $0.id == id }
    }

    func logEvent(_ event: CalendarEvent, clientID: UUID?, projectID: UUID? = nil) {
        guard !loggedEventKeys.contains(event.id) else { return }
        let activityID = meetingActivity?.id
        data.entries.append(TimeEntry(
            clientID: clientID,
            projectID: projectID,
            activityID: activityID,
            notes: event.title,
            start: event.start,
            end: event.end,
            isBillable: defaultBillable(clientID: clientID, projectID: projectID, activityID: activityID),
            source: .calendar,
            calendarEventKey: event.id
        ))
    }

    func dismissEvent(_ key: String) {
        data.dismissedEventKeys.insert(key)
    }

    func restoreEvent(_ key: String) {
        data.dismissedEventKeys.remove(key)
    }

    // MARK: - Clients, projects and activities

    func save(_ client: Client) {
        if let index = data.clients.firstIndex(where: { $0.id == client.id }) {
            data.clients[index] = client
        } else {
            data.clients.append(client)
        }
    }

    func newClient(named name: String = "New client") -> Client {
        let client = Client(name: name, colorHex: Palette.next(after: data.clients.map(\.colorHex)))
        save(client)
        return client
    }

    /// Deletes a client, its projects and its time. Prefer archiving when the client has time logged.
    func deleteClient(_ id: UUID) {
        for project in data.projects where project.clientID == id {
            data.workday.projectCodes[project.id.uuidString] = nil
        }
        data.workday.clientProjects[id.uuidString] = nil
        data.clients.removeAll { $0.id == id }
        data.projects.removeAll { $0.clientID == id }
        data.entries.removeAll { $0.clientID == id }
    }

    func save(_ project: Project) {
        if let index = data.projects.firstIndex(where: { $0.id == project.id }) {
            data.projects[index] = project
        } else {
            data.projects.append(project)
        }
    }

    func deleteProject(_ id: UUID) {
        data.workday.projectCodes[id.uuidString] = nil
        data.projects.removeAll { $0.id == id }
        for i in data.entries.indices where data.entries[i].projectID == id {
            data.entries[i].projectID = nil
        }
    }

    func save(_ activity: Activity) {
        if let index = data.activities.firstIndex(where: { $0.id == activity.id }) {
            data.activities[index] = activity
        } else {
            data.activities.append(activity)
        }
    }

    func deleteActivity(_ id: UUID) {
        data.workday.activityCodes[id.uuidString] = nil
        data.activities.removeAll { $0.id == id }
        for i in data.entries.indices where data.entries[i].activityID == id {
            data.entries[i].activityID = nil
        }
    }
}
