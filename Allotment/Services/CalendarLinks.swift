import Foundation
import Observation

/// Where one calendar link stands. A link that stops working keeps showing the events it last read.
///
///     waiting ──download works──▶ current
///     waiting ──download fails──▶ failing
///     current ──download works──▶ current, with the new time
///     current ──download fails──▶ failing, keeping the time of the last download that worked
///     failing ──download works──▶ current
enum CalendarLinkState: Equatable, Sendable {
    case waiting
    case current(updated: Date)
    case failing(reason: String, lastUpdated: Date?)

    mutating func downloaded(at date: Date) {
        self = .current(updated: date)
    }

    mutating func failed(_ reason: String) {
        switch self {
        case .waiting: self = .failing(reason: reason, lastUpdated: nil)
        case .current(let updated): self = .failing(reason: reason, lastUpdated: updated)
        case .failing(_, let lastUpdated): self = .failing(reason: reason, lastUpdated: lastUpdated)
        }
    }

    var isFailing: Bool {
        if case .failing = self { true } else { false }
    }

    /// One line for Settings.
    var summary: String {
        switch self {
        case .waiting:
            "Downloading for the first time…"
        case .current(let updated):
            "Updated \(Fmt.when(updated))"
        case .failing(let reason, let lastUpdated):
            "Could not update. \(reason)\(lastUpdated.map { " Showing what it read \(Fmt.when($0))." } ?? "")"
        }
    }
}

/// Turns what someone pastes into the address Allotment downloads.
enum CalendarLinkAddress {
    enum Problem: LocalizedError, Equatable {
        case empty
        case notALink
        case alreadyAdded(String)
        case notSaved

        var errorDescription: String? {
            switch self {
            case .empty: "Paste the calendar's link first."
            case .notALink: "That is not a web link. Copy the calendar's .ics link and paste it again."
            case .alreadyAdded(let name): "That calendar is already added, as \(name)."
            case .notSaved: "Allotment could not save the link in your Keychain, so it was not added. Try again."
            }
        }
    }

    static func url(from text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Problem.empty }
        // Calendar apps hand out webcal:// links, which are https:// links underneath.
        for prefix in ["webcals://", "webcal://"] where text.lowercased().hasPrefix(prefix) {
            text = "https://" + text.dropFirst(prefix.count)
        }
        guard var parts = URLComponents(string: text), let host = parts.host?.lowercased(), !host.isEmpty,
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http" else { throw Problem.notALink }

        // Calendar links are private, so they always go over an encrypted connection. Debug builds may read
        // a test calendar served from this Mac.
        var keepsPlainHTTP = false
        #if DEBUG
        keepsPlainHTTP = host == "localhost" || host == "127.0.0.1"
        #endif
        if !keepsPlainHTTP { parts.scheme = "https" }

        // Outlook publishes an HTML link and an ICS link for the same calendar. The HTML one is a web page.
        if host.contains("outlook") || host.contains("office365") || host.contains("office.com"),
           parts.path.lowercased().hasSuffix("/calendar.html") {
            parts.path = String(parts.path.dropLast(".html".count)) + ".ics"
        }
        guard let url = parts.url else { throw Problem.notALink }
        return url
    }

    /// A name for a new link when the calendar does not give one.
    static func suggestedName(for url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        if host.contains("outlook") || host.contains("office") { return "Outlook" }
        if host.contains("google") { return "Google Calendar" }
        if host.contains("icloud") { return "iCloud" }
        return "Calendar"
    }
}

/// Downloads calendar files. The session is ephemeral, so nothing from your calendar is cached on disk.
struct CalendarDownloader: Sendable {
    enum Problem: LocalizedError, Equatable {
        case refused
        case notFound
        case server(Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .refused:
                "The calendar refused the link. It may have been turned off or replaced, so publish the calendar again and add the new link."
            case .notFound:
                "There is no calendar at this link any more. Publish the calendar again and add the new link."
            case .server(let status):
                "The calendar's server answered with error \(status). Allotment tries again every 15 minutes."
            case .tooLarge:
                "That calendar file is too large to read."
            }
        }
    }

    var fetch: @Sendable (URL) async throws -> (Data, URLResponse)

    static let live = CalendarDownloader { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/calendar, */*;q=0.5", forHTTPHeaderField: "Accept")
        return try await session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func file(at url: URL, localZone: TimeZone = .current) async throws -> CalendarFile {
        let (data, response) = try await fetch(url)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            switch status {
            case 401, 403, 410: throw Problem.refused
            case 404: throw Problem.notFound
            default: throw Problem.server(status)
            }
        }
        guard data.count <= 30_000_000 else { throw Problem.tooLarge }
        // Reading a large calendar takes a moment, so it happens away from the main thread.
        return try await Task.detached(priority: .utility) {
            try CalendarFile.parse(String(decoding: data, as: UTF8.self), localZone: localZone)
        }.value
    }
}

/// The calendars Allotment downloads from links. Each link is read when the app starts and every 15 minutes
/// after that, and its events stay in memory only.
@MainActor
@Observable
final class CalendarLinks {
    private(set) var states: [UUID: CalendarLinkState] = [:]
    private(set) var refreshing: Set<UUID> = []
    /// Bumped whenever a link brings new events, so views know to refetch.
    private(set) var revision = 0

    @ObservationIgnored private var files: [UUID: CalendarFile] = [:]
    @ObservationIgnored private var addresses: [UUID: URL] = [:]
    @ObservationIgnored private var lastAttempt: [UUID: Date] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let downloader: CalendarDownloader

    static let refreshInterval: TimeInterval = 15 * 60

    init(secrets: SecretStore, downloader: CalendarDownloader = .live) {
        self.secrets = secrets
        self.downloader = downloader
    }

    func state(of link: CalendarLink) -> CalendarLinkState {
        states[link.id] ?? .waiting
    }

    /// Whether the link is saved in the Keychain, checked without reading it.
    func hasAddress(for link: CalendarLink) -> Bool {
        addresses[link.id] != nil || secrets.contains(.calendarLink(link.id))
    }

    /// Downloads and reads a link before it is added, so a wrong link is caught while the sheet is still open.
    func check(_ text: String, against existing: [CalendarLink]) async throws -> (url: URL, file: CalendarFile) {
        let url = try CalendarLinkAddress.url(from: text)
        if let duplicate = existing.first(where: { address(for: $0) == url }) {
            throw CalendarLinkAddress.Problem.alreadyAdded(duplicate.name)
        }
        return (url, try await downloader.file(at: url))
    }

    /// Saves a link that `check` read, along with what it read. Throws if the Keychain did not keep the link,
    /// rather than seeming to work until the next launch.
    func add(_ link: CalendarLink, url: URL, file: CalendarFile, at now: Date = .now) throws {
        secrets.set(url.absoluteString, for: .calendarLink(link.id))
        guard secrets.contains(.calendarLink(link.id)) else { throw CalendarLinkAddress.Problem.notSaved }
        addresses[link.id] = url
        files[link.id] = file
        lastAttempt[link.id] = now
        var state = CalendarLinkState.waiting
        state.downloaded(at: now)
        states[link.id] = state
        revision += 1
    }

    /// Forgets a link and deletes it from the Keychain.
    func remove(_ link: CalendarLink) {
        secrets.set(nil, for: .calendarLink(link.id))
        addresses[link.id] = nil
        files[link.id] = nil
        states[link.id] = nil
        lastAttempt[link.id] = nil
        revision += 1
    }

    /// Downloads every link again. Links tried within `maxAge` seconds are left alone.
    func refresh(_ links: [CalendarLink], olderThan maxAge: TimeInterval = 0) async {
        await withTaskGroup(of: Void.self) { group in
            for link in links {
                group.addTask { await self.refresh(link, olderThan: maxAge) }
            }
        }
    }

    func refresh(_ link: CalendarLink, olderThan maxAge: TimeInterval = 0, now: Date = .now) async {
        if let last = lastAttempt[link.id], now.timeIntervalSince(last) < maxAge { return }
        guard !refreshing.contains(link.id) else { return }
        guard let url = address(for: link) else {
            states[link.id, default: .waiting].failed("The link is missing from this Mac's Keychain. Remove this calendar and add it again.")
            return
        }
        refreshing.insert(link.id)
        lastAttempt[link.id] = now
        defer { refreshing.remove(link.id) }
        do {
            let file = try await downloader.file(at: url)
            files[link.id] = file
            states[link.id, default: .waiting].downloaded(at: .now)
            revision += 1
        } catch {
            states[link.id, default: .waiting].failed(error.localizedDescription)
        }
    }

    /// Keeps every link fresh: now, then every 15 minutes, for as long as the app runs.
    func keepFresh(_ links: @escaping @MainActor () -> [CalendarLink]) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(links())
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    /// The link's meetings that overlap `interval`, as calendar events.
    func events(for link: CalendarLink, in interval: DateInterval) -> [CalendarEvent] {
        guard let file = files[link.id] else { return [] }
        return file.occurrences(in: interval).map { occurrence in
            CalendarEvent(
                id: occurrence.key,
                title: occurrence.title.isEmpty ? "Untitled event" : occurrence.title,
                start: occurrence.start,
                end: occurrence.end,
                isAllDay: occurrence.isAllDay,
                calendarTitle: link.name,
                calendarColorHex: link.colorHex,
                location: occurrence.location,
                attendeeEmails: occurrence.attendeeEmails,
                isDeclined: false
            )
        }
    }

    private func address(for link: CalendarLink) -> URL? {
        if let known = addresses[link.id] { return known }
        guard let text = secrets.value(for: .calendarLink(link.id)), let url = URL(string: text) else { return nil }
        addresses[link.id] = url
        return url
    }
}
