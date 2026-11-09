import AppKit
import EventKit
import Observation
import SwiftUI

/// A calendar event occurrence copied out of EventKit.
struct CalendarEvent: Identifiable, Hashable, Sendable {
    /// Unique per occurrence, so each instance of a repeating meeting can be logged once.
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let calendarColorHex: String
    let location: String
    let attendeeEmails: [String]
    let isDeclined: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func isHappening(at now: Date) -> Bool { start <= now && now < end }
}

/// Whether Allotment may read the calendars on this Mac.
///
///     notAsked ──you allow access──▶ granted
///     notAsked ──you decline──▶ denied
///     denied ──you turn it on in System Settings, then Check again──▶ granted
enum CalendarAccess: Equatable, Sendable {
    case notAsked
    case granted
    case denied

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess: self = .granted
        case .notDetermined: self = .notAsked
        // Denied, restricted and write-only access all mean events cannot be read.
        default: self = .denied
        }
    }
}

/// Where one calendar event stands for logging. Worked out in one place, so the Calendar page, Log all matched
/// and the menu bar panel always agree.
///
///     upcoming ──it starts──▶ happening ──it ends──▶ finished
///     happening or finished ──Log──▶ logged
///     upcoming, happening or finished ──Skip──▶ skipped ──Restore──▶ its time-based state again
///
/// Declining an event is a separate fact about the event (`CalendarEvent.isDeclined`), not a state here.
enum CalendarEventState: Equatable, Sendable {
    case upcoming
    case happening
    case finished
    case logged
    case skipped

    init(event: CalendarEvent, at now: Date, logged: Set<String>, skipped: Set<String>) {
        if logged.contains(event.id) {
            self = .logged
        } else if skipped.contains(event.id) {
            self = .skipped
        } else if event.start > now {
            self = .upcoming
        } else if event.end > now {
            self = .happening
        } else {
            self = .finished
        }
    }

    /// An event can be logged once it has started.
    var canLog: Bool { self == .happening || self == .finished }
}

struct CalendarSource: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    let colorHex: String
}

/// Reads calendars through EventKit. Allotment never writes to your calendar.
@MainActor
@Observable
final class CalendarService {
    private(set) var access: CalendarAccess
    private(set) var calendars: [CalendarSource] = []
    /// Bumped whenever the calendar database changes, so views know to refetch.
    private(set) var revision = 0

    @ObservationIgnored private let eventStore = EKEventStore()
    @ObservationIgnored private var cache: (key: String, events: [CalendarEvent])?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        access = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
        if access == .granted { reloadCalendars() }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadCalendars()
                self?.revision += 1
            }
        }
    }

    func requestAccess() {
        eventStore.requestFullAccessToEvents { @Sendable _, _ in
            Task { @MainActor in
                self.refreshStatus()
            }
        }
    }

    func refreshStatus() {
        access = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
        if access == .granted {
            eventStore.reset()
            reloadCalendars()
            revision += 1
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reloadCalendars() {
        calendars = eventStore.calendars(for: .event)
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "", colorHex: $0.color.hexString) }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func events(in interval: DateInterval, settings: AppSettings) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let key = "\(interval.start.timeIntervalSince1970)|\(interval.end.timeIntervalSince1970)|\(settings.includedCalendarIDs?.sorted() ?? [])|\(settings.ignoreAllDayEvents)|\(revision)"
        if let cache, cache.key == key { return cache.events }
        let events = fetchEvents(in: interval, settings: settings)
        cache = (key, events)
        return events
    }

    /// Events worth drawing on a day timeline: timed ones you have not declined.
    func timelineEvents(in interval: DateInterval, settings: AppSettings) -> [CalendarEvent] {
        events(in: interval, settings: settings).filter { !$0.isAllDay && !$0.isDeclined }
    }

    private func fetchEvents(in interval: DateInterval, settings: AppSettings) -> [CalendarEvent] {
        var selected: [EKCalendar]?
        if let ids = settings.includedCalendarIDs {
            selected = eventStore.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
            if selected?.isEmpty == true { return [] }
        }
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: selected)
        return eventStore.events(matching: predicate)
            .filter { !(settings.ignoreAllDayEvents && $0.isAllDay) }
            .map(Self.makeEvent)
            .sorted { $0.start < $1.start }
    }

    private static func makeEvent(_ event: EKEvent) -> CalendarEvent {
        let attendees = event.attendees ?? []
        let emails = attendees.compactMap { participant -> String? in
            let text = participant.url.absoluteString
            return text.lowercased().hasPrefix("mailto:") ? String(text.dropFirst(7)).lowercased() : nil
        }
        let declined = attendees.first(where: \.isCurrentUser)?.participantStatus == .declined
        let identifier = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
        return CalendarEvent(
            id: "\(identifier)@\(Int(event.startDate.timeIntervalSince1970))",
            title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? "",
            calendarColorHex: event.calendar?.color.hexString ?? Palette.internalHex,
            location: event.location ?? "",
            attendeeEmails: emails,
            isDeclined: declined
        )
    }
}

enum EventMatcher {
    /// Finds the client an event most likely belongs to, from its title, location and attendees.
    static func client(for event: CalendarEvent, in clients: [Client]) -> Client? {
        let haystack = "\(event.title) \(event.location)".lowercased()
        for client in clients where !client.isArchived {
            let keys = client.matchKeywords.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            for key in keys {
                if key.contains(".") || key.contains("@") {
                    let domain = key.hasPrefix("@") ? String(key.dropFirst()) : key
                    if event.attendeeEmails.contains(where: { $0.hasSuffix("@\(domain)") || $0 == domain }) { return client }
                }
                if haystack.contains(key) { return client }
            }
        }
        // Fall back to the client name itself when it is long enough to be meaningful.
        return clients.first { client in
            !client.isArchived && client.name.count >= 3 && haystack.contains(client.name.lowercased())
        }
    }
}

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return Palette.internalHex }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}
