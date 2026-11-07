import Foundation

enum AllocationPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case week
    case month

    var id: Self { self }
    var title: String { self == .week ? "Week" : "Month" }
    var perLabel: String { self == .week ? "per week" : "per month" }
}

struct Client: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var colorHex: String
    /// Hourly rate in the app currency. `nil` falls back to the default rate in Settings.
    var hourlyRate: Double?
    /// Hours allocated to this client for each `allocationPeriod`. `nil` means no allocation.
    var allocationHours: Double?
    var allocationPeriod: AllocationPeriod = .week
    /// Words or email domains used to match calendar events to this client.
    var matchKeywords: [String] = []
    /// Favourites appear as one-click buttons in the menu bar.
    var isFavorite = true
    var isArchived = false
    var notes = ""
}

extension Client {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? Palette.fallback
        hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate)
        allocationHours = try c.decodeIfPresent(Double.self, forKey: .allocationHours)
        allocationPeriod = try c.decodeIfPresent(AllocationPeriod.self, forKey: .allocationPeriod) ?? .week
        matchKeywords = try c.decodeIfPresent([String].self, forKey: .matchKeywords) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? true
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

struct Project: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var clientID: UUID
    var name: String
    /// Total hours budgeted for the life of the project.
    var budgetHours: Double?
    var isBillable = true
    var isArchived = false
}

extension Project {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clientID = try c.decode(UUID.self, forKey: .clientID)
        name = try c.decode(String.self, forKey: .name)
        budgetHours = try c.decodeIfPresent(Double.self, forKey: .budgetHours)
        isBillable = try c.decodeIfPresent(Bool.self, forKey: .isBillable) ?? true
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

/// The kind of work being done, such as a meeting or admin. Harvest calls these tasks.
struct Activity: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var isBillable: Bool
    /// Admin activities are reported separately so overhead is easy to see.
    var isAdmin: Bool
    var isArchived = false

    static let clientWorkID = UUID(uuidString: "7A1E0000-0000-4000-8000-000000000001")!
    static let meetingID = UUID(uuidString: "7A1E0000-0000-4000-8000-000000000002")!
    static let adminID = UUID(uuidString: "7A1E0000-0000-4000-8000-000000000003")!

    static let defaults: [Activity] = [
        Activity(id: clientWorkID, name: "Client work", symbol: "hammer", isBillable: true, isAdmin: false),
        Activity(id: meetingID, name: "Meeting", symbol: "person.2", isBillable: true, isAdmin: false),
        Activity(id: adminID, name: "Admin", symbol: "tray.full", isBillable: false, isAdmin: true),
        Activity(name: "Email and comms", symbol: "envelope", isBillable: false, isAdmin: true),
        Activity(name: "Research", symbol: "magnifyingglass", isBillable: true, isAdmin: false),
        Activity(name: "Travel", symbol: "car", isBillable: false, isAdmin: false),
    ]
}

extension Activity {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "circle"
        isBillable = try c.decodeIfPresent(Bool.self, forKey: .isBillable) ?? true
        isAdmin = try c.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

enum EntrySource: String, Codable, Sendable {
    case timer
    case manual
    case calendar
}

struct TimeEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var clientID: UUID?
    var projectID: UUID?
    var activityID: UUID?
    var notes = ""
    var start: Date
    /// `nil` while the timer is running.
    var end: Date?
    var isBillable: Bool
    var source: EntrySource = .timer
    /// Identifies the calendar event occurrence this entry was logged from.
    var calendarEventKey: String?

    var isRunning: Bool { end == nil }

    func duration(at now: Date = .now) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

extension TimeEntry {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clientID = try c.decodeIfPresent(UUID.self, forKey: .clientID)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        activityID = try c.decodeIfPresent(UUID.self, forKey: .activityID)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
        isBillable = try c.decodeIfPresent(Bool.self, forKey: .isBillable) ?? false
        source = try c.decodeIfPresent(EntrySource.self, forKey: .source) ?? .manual
        calendarEventKey = try c.decodeIfPresent(String.self, forKey: .calendarEventKey)
    }
}

enum RoundingRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case nearest5
    case nearest6
    case nearest15
    case up6
    case up15

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "No rounding"
        case .nearest5: "Nearest 5 minutes"
        case .nearest6: "Nearest 6 minutes (0.1 h)"
        case .nearest15: "Nearest 15 minutes"
        case .up6: "Up to 6 minutes (0.1 h)"
        case .up15: "Up to 15 minutes"
        }
    }

    func apply(_ seconds: TimeInterval) -> TimeInterval {
        switch self {
        case .none: seconds
        case .nearest5: (seconds / 300).rounded() * 300
        case .nearest6: (seconds / 360).rounded() * 360
        case .nearest15: (seconds / 900).rounded() * 900
        case .up6: (seconds / 360).rounded(.up) * 360
        case .up15: (seconds / 900).rounded(.up) * 900
        }
    }
}

struct AppSettings: Codable, Hashable, Sendable {
    var weeklyCapacityHours: Double = 37.5
    /// Calendar weekday numbers, where 1 is Sunday and 7 is Saturday.
    var workdays: Set<Int> = [2, 3, 4, 5, 6]
    var workdayStartMinutes = 9 * 60
    var workdayEndMinutes = 17 * 60 + 30
    var firstWeekday = 2
    var currencyCode = Locale.current.currency?.identifier ?? "GBP"
    var defaultHourlyRate: Double = 0
    var rounding: RoundingRule = .none
    /// Minutes without keyboard or mouse input before Allotment asks about idle time. 0 turns it off.
    var idleThresholdMinutes = 10
    var showTimerInMenuBar = true
    /// How far over or under an allocation counts as on track, as a percentage.
    var tolerancePercent: Double = 10
    var userName = NSFullUserName()
    /// Calendar identifiers to read. `nil` reads every calendar.
    var includedCalendarIDs: [String]?
    var ignoreAllDayEvents = true

    var dailyTargetHours: Double {
        weeklyCapacityHours / Double(max(1, workdays.count))
    }

    init() {}
}

extension AppSettings {
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weeklyCapacityHours = try c.decodeIfPresent(Double.self, forKey: .weeklyCapacityHours) ?? weeklyCapacityHours
        workdays = try c.decodeIfPresent(Set<Int>.self, forKey: .workdays) ?? workdays
        workdayStartMinutes = try c.decodeIfPresent(Int.self, forKey: .workdayStartMinutes) ?? workdayStartMinutes
        workdayEndMinutes = try c.decodeIfPresent(Int.self, forKey: .workdayEndMinutes) ?? workdayEndMinutes
        firstWeekday = try c.decodeIfPresent(Int.self, forKey: .firstWeekday) ?? firstWeekday
        currencyCode = try c.decodeIfPresent(String.self, forKey: .currencyCode) ?? currencyCode
        defaultHourlyRate = try c.decodeIfPresent(Double.self, forKey: .defaultHourlyRate) ?? defaultHourlyRate
        rounding = try c.decodeIfPresent(RoundingRule.self, forKey: .rounding) ?? rounding
        idleThresholdMinutes = try c.decodeIfPresent(Int.self, forKey: .idleThresholdMinutes) ?? idleThresholdMinutes
        showTimerInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showTimerInMenuBar) ?? showTimerInMenuBar
        tolerancePercent = try c.decodeIfPresent(Double.self, forKey: .tolerancePercent) ?? tolerancePercent
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? userName
        includedCalendarIDs = try c.decodeIfPresent([String].self, forKey: .includedCalendarIDs)
        ignoreAllDayEvents = try c.decodeIfPresent(Bool.self, forKey: .ignoreAllDayEvents) ?? ignoreAllDayEvents
    }
}

/// Everything Allotment stores. Saved as one JSON file in Application Support.
struct AppData: Codable, Sendable {
    var version = 1
    var clients: [Client] = []
    var projects: [Project] = []
    var activities: [Activity] = Activity.defaults
    var entries: [TimeEntry] = []
    var settings = AppSettings()
    /// Calendar event occurrences the user chose not to log.
    var dismissedEventKeys: Set<String> = []
    var workday = WorkdayConfig()

    init() {}
}

extension AppData {
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        clients = try c.decodeIfPresent([Client].self, forKey: .clients) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        activities = try c.decodeIfPresent([Activity].self, forKey: .activities) ?? Activity.defaults
        entries = try c.decodeIfPresent([TimeEntry].self, forKey: .entries) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        dismissedEventKeys = try c.decodeIfPresent(Set<String>.self, forKey: .dismissedEventKeys) ?? []
        workday = try c.decodeIfPresent(WorkdayConfig.self, forKey: .workday) ?? WorkdayConfig()
    }
}

enum Palette {
    static let colors = [
        "#FF6B6B", "#F59E0B", "#10B981", "#3B82F6", "#8B5CF6", "#EC4899",
        "#14B8A6", "#F97316", "#6366F1", "#84CC16", "#06B6D4", "#A855F7",
    ]
    static let fallback = "#3B82F6"
    /// Used for time with no client, such as internal admin.
    static let internalHex = "#8E8E93"

    static func next(after used: [String]) -> String {
        colors.first { !used.contains($0) } ?? colors[used.count % colors.count]
    }
}
