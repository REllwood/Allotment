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
    private(set) var status: EKAuthorizationStatus
    private(set) var calendars: [CalendarSource] = []
    /// Bumped whenever the calendar database changes, so views know to refetch.
    private(set) var revision = 0

    @ObservationIgnored private let eventStore = EKEventStore()
    @ObservationIgnored private var cache: (key: String, events: [CalendarEvent])?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        status = EKEventStore.authorizationStatus(for: .event)
        if hasAccess { reloadCalendars() }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadCalendars()
                self?.revision += 1
            }
        }
    }

    var hasAccess: Bool { status == .fullAccess }
    var canRequestAccess: Bool { status == .notDetermined }

    func requestAccess() {
        eventStore.requestFullAccessToEvents { @Sendable _, _ in
            Task { @MainActor in
                self.refreshStatus()
            }
        }
    }

    func refreshStatus() {
        status = EKEventStore.authorizationStatus(for: .event)
        if hasAccess {
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
        guard hasAccess else { return [] }
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
