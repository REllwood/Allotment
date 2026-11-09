import AppKit
import Observation
import ServiceManagement

/// Publishes the current time once a second for live timers. Kept apart from the store so
/// only the views that show a running clock redraw every second.
@MainActor
@Observable
final class Ticker {
    private(set) var now = Date.now
    /// Changes only when the minute changes, for summaries that do not need to redraw every second.
    private(set) var minute = Ticker.startOfMinute(.now)
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        now = .now
        let minute = Self.startOfMinute(now)
        if minute != self.minute { self.minute = minute }
    }

    private static func startOfMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview
    case timesheet
    case calendar
    case workday
    case reports
    case forecast
    case clients
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .timesheet: "Timesheet"
        case .calendar: "Calendar"
        case .workday: "Workday"
        case .reports: "Reports"
        case .forecast: "Forecast"
        case .clients: "Clients"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .timesheet: "list.bullet.rectangle"
        case .calendar: "calendar"
        case .workday: "briefcase"
        case .reports: "chart.bar.xaxis"
        case .forecast: "gauge.with.dots.needle.67percent"
        case .clients: "person.2"
        case .settings: "gearshape"
        }
    }
}

/// Navigation shared between the menu bar panel and the main window.
@MainActor
@Observable
final class Router {
    var selection: SidebarItem = .overview
    var timesheetDate = Date.now
    /// Set to open the entry editor. A new entry when the inner value is `nil`.
    var editing: EntryEditTarget?
}

struct EntryEditTarget: Identifiable, Hashable {
    let id = UUID()
    var entryID: UUID?
    var day: Date = .now
}

/// Whether Allotment opens when you log in.
///
///     off ──turn on──▶ on, or needsApproval when macOS wants you to allow it in System Settings › Login Items
///     needsApproval ──you allow it there──▶ on
///     on or needsApproval ──turn off──▶ off
enum LoginItem {
    enum State: Equatable, Sendable {
        case off
        case on
        case needsApproval

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .on
            case .requiresApproval: self = .needsApproval
            default: self = .off
            }
        }
    }

    static var state: State { State(SMAppService.mainApp.status) }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum AppWindow {
    static let main = "main"

    /// Shows the Dock icon while a window is open, and hides it again when the last one closes.
    @MainActor
    static func updateActivationPolicy() {
        let hasVisibleWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
    }
}
