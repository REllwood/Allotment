import Foundation

/// Reads an iCalendar (.ics) file, such as a published Outlook calendar or a Google calendar's secret address,
/// and works out when each event happens, repeats included. It covers what Outlook, Teams and Google publish:
/// folded lines, time zones by name or by the rules in the file, all-day events, repeat rules, skipped repeats
/// (EXDATE) and repeats that were moved or cancelled (RECURRENCE-ID).
///
/// Times are worked out on the wall clock first and only then turned into real moments, so a 9:00 meeting
/// stays at 9:00 when the clocks change.
struct CalendarFile: Sendable {
    /// The calendar's own name, when the file gives one.
    var name: String?
    var events: [Event]
    /// For each repeating event, the moments of the repeats that a separate entry moved or cancelled.
    var replaced: [String: Set<Date>]

    enum Problem: LocalizedError, Equatable {
        case webPage
        case notACalendar

        var errorDescription: String? {
            switch self {
            case .webPage: "That link opens a web page, not a calendar file. Copy the link that ends in .ics instead."
            case .notACalendar: "That link did not return a calendar. Copy the calendar's .ics link and try again."
            }
        }
    }

    /// One meeting as Allotment will show it.
    struct Occurrence: Equatable, Sendable {
        var uid: String
        var title: String
        var location: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var attendeeEmails: [String]

        /// Matches the key EventKit events use, so a meeting that also comes through the Mac's Calendar app
        /// is recognised as the same meeting.
        var key: String { "\(uid)@\(Int(start.timeIntervalSince1970))" }
    }

    struct Event: Sendable {
        var uid: String
        var title: String
        var location: String
        var start: Stamp
        /// The real moment of `start`, worked out once when the file is read.
        var startMoment: Date
        var rule: RecurrenceRule?
        var extraStarts: [Stamp]
        var recurrenceID: Stamp?
        var isCancelled: Bool
        var attendeeEmails: [String]
        /// How long it lasts: whole days on the wall clock, plus seconds.
        var lengthDays: Int
        var lengthSeconds: TimeInterval
        /// Repeats to leave out, as moments, and as wall-clock days for date-only exceptions.
        var skippedMoments: Set<Date>
        var skippedDays: Set<Date>

        var isAllDay: Bool { start.isDateOnly }

        func end(startingAt wall: Date, moment: Date) -> Date {
            guard lengthDays > 0 else { return moment.addingTimeInterval(lengthSeconds) }
            let endWall = wallCalendar.date(byAdding: .day, value: lengthDays, to: wall) ?? wall
            return start.zone.date(fromWall: endWall).addingTimeInterval(lengthSeconds)
        }
    }

    /// A time as the file gives it: a wall-clock time and the zone it belongs to.
    struct Stamp: Sendable {
        var wall: Date
        var isDateOnly: Bool
        var zone: EventZone

        var moment: Date { zone.date(fromWall: wall) }
    }

    // MARK: Reading

    /// Reads the text of an .ics file. `localZone` is used for all-day events and times with no zone.
    static func parse(_ text: String, localZone: TimeZone = .current) throws -> CalendarFile {
        let components = ContentLine.components(ContentLine.lines(in: text))
        guard let calendar = components.first(where: { $0.name == "VCALENDAR" }) else {
            let opening = text.prefix(2048).lowercased()
            throw opening.contains("<html") || opening.contains("<!doctype html") ? Problem.webPage : Problem.notACalendar
        }

        let local = EventZone.zone(localZone)
        var zones: [String: EventZone] = [:]
        for timeZone in calendar.children where timeZone.name == "VTIMEZONE" {
            guard let id = timeZone.value("TZID") else { continue }
            if let rules = ZoneRules(timeZone) { zones[id] = .rules(rules) }
        }
        let resolver = StampReader(fileZones: zones, local: local)

        var events: [Event] = []
        var replaced: [String: Set<Date>] = [:]
        for component in calendar.children where component.name == "VEVENT" {
            guard let event = resolver.event(from: component) else { continue }
            if let recurrenceID = event.recurrenceID {
                replaced[event.uid, default: []].insert(recurrenceID.moment)
            }
            events.append(event)
        }
        let name = calendar.value("X-WR-CALNAME").map(ContentLine.unescape)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarFile(name: name?.isEmpty == false ? name : nil, events: events, replaced: replaced)
    }

    // MARK: Occurrences

    /// Every meeting that overlaps `interval`, in start order.
    func occurrences(in interval: DateInterval) -> [Occurrence] {
        var result: [Occurrence] = []
        for event in events where !event.isCancelled {
            if (event.rule == nil && event.extraStarts.isEmpty) || event.recurrenceID != nil {
                add(event, wall: event.start.wall, moment: event.startMoment, to: &result, in: interval)
                continue
            }
            // Wall-clock bounds with two days to spare, which covers any time zone and the event's own length.
            let spare = TimeInterval((event.lengthDays + 2) * 86_400) + event.lengthSeconds
            let lower = interval.start.addingTimeInterval(-spare)
            let upper = interval.end.addingTimeInterval(2 * 86_400)
            let zone = event.start.zone
            var seen = Set<Date>()
            let starts = event.rule?.starts(first: event.start.wall, from: lower, before: upper, toMoment: zone.date(fromWall:))
                ?? (event.start.wall >= lower && event.start.wall < upper ? [event.start.wall] : [])
            let moved = replaced[event.uid] ?? []
            for wall in starts {
                let moment = zone.date(fromWall: wall)
                guard !event.skippedMoments.contains(moment), !event.skippedDays.contains(wallCalendar.startOfDay(for: wall)),
                      !moved.contains(moment), seen.insert(moment).inserted else { continue }
                add(event, wall: wall, moment: moment, to: &result, in: interval)
            }
            for extra in event.extraStarts {
                let moment = extra.moment
                guard !event.skippedMoments.contains(moment), !moved.contains(moment), seen.insert(moment).inserted else { continue }
                add(event, wall: extra.wall, moment: moment, to: &result, in: interval)
            }
        }
        return result.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    private func add(_ event: Event, wall: Date, moment: Date, to result: inout [Occurrence], in interval: DateInterval) {
        let end = max(moment, event.end(startingAt: wall, moment: moment))
        let overlaps = end > moment
            ? moment < interval.end && end > interval.start
            : moment >= interval.start && moment < interval.end
        guard overlaps else { return }
        result.append(Occurrence(uid: event.uid, title: event.title, location: event.location, start: moment, end: end,
                                 isAllDay: event.isAllDay, attendeeEmails: event.attendeeEmails))
    }
}

/// Counts wall-clock time as if it were UTC, so days and months add up without daylight saving getting in the way.
let wallCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

// MARK: - Time zones

/// Turns a wall-clock time into a real moment.
enum EventZone: Sendable {
    case utc
    /// A time zone macOS knows, such as Europe/London, or this Mac's own.
    case known(Calendar)
    /// A time zone defined by the rules in the file, which is how Outlook sends names such as
    /// "AUS Eastern Standard Time".
    case rules(ZoneRules)

    static func zone(_ timeZone: TimeZone) -> EventZone {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return .known(calendar)
    }

    func date(fromWall wall: Date) -> Date {
        switch self {
        case .utc:
            return wall
        case .known(let calendar):
            let parts = wallCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
            return calendar.date(from: parts) ?? wall
        case .rules(let rules):
            return wall.addingTimeInterval(-TimeInterval(rules.offset(atWall: wall)))
        }
    }
}

/// The standard and daylight saving periods of a VTIMEZONE.
struct ZoneRules: Sendable {
    struct Change: Sendable {
        /// When this period first began, on the wall clock.
        var start: Date
        var offsetFrom: Int
        var offsetTo: Int
        var rule: RecurrenceRule?
        var extraStarts: [Date]

        /// The most recent time this period began, at or before `wall`.
        func latestStart(atOrBefore wall: Date) -> Date? {
            var candidates = extraStarts.filter { $0 <= wall }
            if start <= wall { candidates.append(start) }
            if let rule {
                let lower = wallCalendar.date(byAdding: .year, value: -2, to: wall) ?? wall
                candidates += rule.starts(first: start, from: lower, before: wall.addingTimeInterval(1),
                                          toMoment: { $0.addingTimeInterval(-TimeInterval(offsetFrom)) })
            }
            return candidates.max()
        }
    }

    var changes: [Change]
    private let cache = TransitionCache()

    /// Remembers each year's changes, because working them out from a rule that began in 1601 is slow
    /// and the same years come up for every meeting.
    private final class TransitionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var years: [Int: [(start: Date, offset: Int)]] = [:]

        func transitions(_ year: Int, make: () -> [(start: Date, offset: Int)]) -> [(start: Date, offset: Int)] {
            if let known = lock.withLock({ years[year] }) { return known }
            let made = make()
            lock.withLock { years[year] = made }
            return made
        }
    }

    init?(_ component: ContentLine.Component) {
        changes = component.children.compactMap { part -> Change? in
            guard part.name == "STANDARD" || part.name == "DAYLIGHT",
                  let start = part.value("DTSTART").flatMap({ StampReader.wallTime($0)?.wall }),
                  let from = part.value("TZOFFSETFROM").flatMap(Self.offset),
                  let to = part.value("TZOFFSETTO").flatMap(Self.offset) else { return nil }
            let extra = part.all("RDATE").flatMap { line in
                line.value.split(separator: ",").compactMap { StampReader.wallTime(String($0))?.wall }
            }
            return Change(start: start, offsetFrom: from, offsetTo: to,
                          rule: part.value("RRULE").flatMap(RecurrenceRule.init), extraStarts: extra)
        }
        if changes.isEmpty { return nil }
    }

    /// Seconds ahead of UTC at a wall-clock time.
    func offset(atWall wall: Date) -> Int {
        let year = wallCalendar.component(.year, from: wall)
        let recent = (transitions(year - 1) + transitions(year)).filter { $0.start <= wall }
        if let latest = recent.max(by: { $0.start < $1.start }) { return latest.offset }

        // Nothing changed in the last two years, as in zones without daylight saving: search every change.
        var latest: (start: Date, offset: Int)?
        for change in changes {
            guard let start = change.latestStart(atOrBefore: wall) else { continue }
            if latest == nil || start > latest!.start { latest = (start, change.offsetTo) }
        }
        if let latest { return latest.offset }
        // Before any change on record: the offset in force before the earliest one.
        return changes.min { $0.start < $1.start }?.offsetFrom ?? 0
    }

    /// The changes that happen during one year, on the wall clock.
    private func transitions(_ year: Int) -> [(start: Date, offset: Int)] {
        cache.transitions(year) {
            guard let start = wallCalendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = wallCalendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
            return changes.flatMap { change -> [(start: Date, offset: Int)] in
                var starts = change.extraStarts.filter { $0 >= start && $0 < end }
                if change.start >= start && change.start < end { starts.append(change.start) }
                if let rule = change.rule {
                    starts += rule.starts(first: change.start, from: start, before: end,
                                          toMoment: { $0.addingTimeInterval(-TimeInterval(change.offsetFrom)) })
                }
                return starts.map { ($0, change.offsetTo) }
            }
        }
    }

    /// Reads offsets such as +1100, -0500 and +053000.
    static func offset(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy(\.isNumber) else { return nil }
        let number = { (range: Range<Int>) in Int(String(digits[range])) ?? 0 }
        let seconds = number(0..<2) * 3600 + number(2..<4) * 60 + (digits.count == 6 ? number(4..<6) : 0)
        return sign == "-" ? -seconds : seconds
    }
}

// MARK: - Repeat rules

/// An RRULE: how an event repeats. Covers daily, weekly, monthly and yearly repeats with INTERVAL, COUNT, UNTIL,
/// BYDAY (with positions such as 2TU or -1FR), BYMONTHDAY, BYMONTH, BYSETPOS and WKST.
struct RecurrenceRule: Equatable, Sendable {
    enum Frequency: String, Sendable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    struct Weekday: Equatable, Sendable {
        /// Which one in the month or year, such as 2 for the second or -1 for the last. `nil` means every one.
        var position: Int?
        /// 1 is Sunday and 7 is Saturday, as in `Calendar`.
        var weekday: Int
    }

    enum Until: Equatable, Sendable {
        /// A real moment, from a UTC time.
        case moment(Date)
        /// A wall-clock time in the event's own zone.
        case wall(Date)
    }

    var frequency: Frequency
    var interval = 1
    var count: Int?
    var until: Until?
    var byDay: [Weekday] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    var bySetPosition: [Int] = []
    var weekStart = 2

    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    init?(_ text: String) {
        var parts: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let bits = pair.split(separator: "=", maxSplits: 1)
            guard bits.count == 2 else { continue }
            parts[bits[0].trimmingCharacters(in: .whitespaces).uppercased()] = bits[1].trimmingCharacters(in: .whitespaces)
        }
        guard let frequency = parts["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
        self.frequency = frequency
        interval = max(1, parts["INTERVAL"].flatMap { Int($0) } ?? 1)
        count = parts["COUNT"].flatMap { Int($0) }.map { max(1, $0) }
        if let until = parts["UNTIL"], let stamp = StampReader.wallTime(until) {
            if stamp.isUTC {
                self.until = .moment(stamp.wall)
            } else {
                // A date on its own includes the whole of that day.
                self.until = .wall(stamp.isDateOnly ? stamp.wall.addingTimeInterval(86_399) : stamp.wall)
            }
        }
        byDay = Self.list(parts["BYDAY"]).compactMap { item in
            let item = item.uppercased()
            guard item.count >= 2, let weekday = Self.weekdays[String(item.suffix(2))] else { return nil }
            let position = item.dropLast(2)
            return Weekday(position: position.isEmpty ? nil : Int(position), weekday: weekday)
        }
        byMonthDay = Self.list(parts["BYMONTHDAY"]).compactMap { Int($0) }.filter { $0 != 0 && abs($0) <= 31 }
        byMonth = Self.list(parts["BYMONTH"]).compactMap { Int($0) }.filter { (1...12).contains($0) }
        bySetPosition = Self.list(parts["BYSETPOS"]).compactMap { Int($0) }.filter { $0 != 0 }
        weekStart = parts["WKST"].flatMap { Self.weekdays[$0.uppercased()] } ?? 2
    }

    private static func list(_ text: String?) -> [String] {
        text?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }

    /// Wall-clock start times, in order, from `first` up to but not including `upper`. The first start always
    /// counts, as calendar apps do. `lower` skips ahead to save work, and starts before it are left out.
    /// `toMoment` turns a wall-clock time into a real moment, for an UNTIL given in UTC.
    func starts(first: Date, from lower: Date? = nil, before upper: Date, toMoment: (Date) -> Date) -> [Date] {
        let timeOfDay = first.timeIntervalSince(wallCalendar.startOfDay(for: first))
        var results: [Date] = []
        var produced = 0
        var period = 0
        // With a COUNT every repeat has to be counted from the start, so there is no skipping ahead.
        if count == nil, let lower { period = max(0, periodsBetween(first, lower) / interval - 1) }
        if period == 0 {
            guard first < upper, allows(first, toMoment) else { return [] }
            results.append(first)
            produced = 1
        }

        var periodsChecked = 0
        outer: while periodsChecked < 5_000 {
            if let count, produced >= count { break }
            periodsChecked += 1
            guard let candidate = candidateDays(period: period, first: first) else { break }
            let (periodStart, days) = candidate
            if periodStart >= upper { break }
            for day in days {
                let start = day.addingTimeInterval(timeOfDay)
                if start <= first { continue }
                if start >= upper || !allows(start, toMoment) { break outer }
                results.append(start)
                produced += 1
                if let count, produced >= count { break outer }
            }
            period += 1
        }
        guard let lower else { return results }
        return results.filter { $0 >= lower }
    }

    private func allows(_ start: Date, _ toMoment: (Date) -> Date) -> Bool {
        switch until {
        case nil: true
        case .moment(let moment): toMoment(start) <= moment
        case .wall(let wall): start <= wall
        }
    }

    /// Roughly how many whole periods lie between two wall-clock times, for skipping ahead.
    private func periodsBetween(_ first: Date, _ later: Date) -> Int {
        guard later > first else { return 0 }
        let component: Calendar.Component = switch frequency {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
        return wallCalendar.dateComponents([component], from: first, to: later).value(for: component) ?? 0
    }

    /// The days in one period that fit the rule, in order, with the period's own start.
    private func candidateDays(period: Int, first: Date) -> (Date, [Date])? {
        let firstDay = wallCalendar.startOfDay(for: first)
        let step = period * interval
        var days: [Date]
        let periodStart: Date
        switch frequency {
        case .daily:
            guard let day = wallCalendar.date(byAdding: .day, value: step, to: firstDay) else { return nil }
            periodStart = day
            days = [day].filter { candidate in
                (byMonth.isEmpty || byMonth.contains(month(candidate)))
                    && (byMonthDay.isEmpty || resolvedMonthDays(in: candidate).contains(dayOfMonth(candidate)))
                    && (byDay.isEmpty || byDay.contains { $0.weekday == weekday(candidate) })
            }
        case .weekly:
            let back = (weekday(firstDay) - weekStart + 7) % 7
            guard let weekOne = wallCalendar.date(byAdding: .day, value: -back, to: firstDay),
                  let week = wallCalendar.date(byAdding: .day, value: step * 7, to: weekOne) else { return nil }
            periodStart = week
            let wanted = byDay.isEmpty ? [weekday(first)] : byDay.map(\.weekday)
            days = (0..<7).compactMap { wallCalendar.date(byAdding: .day, value: $0, to: week) }
                .filter { wanted.contains(weekday($0)) && (byMonth.isEmpty || byMonth.contains(month($0))) }
        case .monthly:
            guard let monthOne = wallCalendar.date(from: wallCalendar.dateComponents([.year, .month], from: firstDay)),
                  let start = wallCalendar.date(byAdding: .month, value: step, to: monthOne) else { return nil }
            periodStart = start
            days = byMonth.isEmpty || byMonth.contains(month(start)) ? self.days(inMonth: start, first: firstDay) : []
        case .yearly:
            let year = wallCalendar.component(.year, from: firstDay) + step
            guard let start = wallCalendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
            periodStart = start
            if byMonth.isEmpty && !byDay.isEmpty && byMonthDay.isEmpty {
                // Positions such as 20MO count through the whole year when no month is given.
                let end = wallCalendar.date(byAdding: .year, value: 1, to: start) ?? start
                days = matching(byDay, in: dayList(from: start, to: end))
            } else {
                let months = !byMonth.isEmpty ? byMonth.sorted()
                    : (byDay.isEmpty && byMonthDay.isEmpty ? [month(firstDay)] : Array(1...12))
                days = months.flatMap { month -> [Date] in
                    guard let monthStart = wallCalendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return [] }
                    return self.days(inMonth: monthStart, first: firstDay)
                }
            }
        }
        days = Array(Set(days)).sorted()
        if !bySetPosition.isEmpty {
            days = bySetPosition.compactMap { position in
                let index = position > 0 ? position - 1 : days.count + position
                return days.indices.contains(index) ? days[index] : nil
            }
            days = Array(Set(days)).sorted()
        }
        return (periodStart, days)
    }

    private func days(inMonth monthStart: Date, first: Date) -> [Date] {
        let end = wallCalendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let all = dayList(from: monthStart, to: end)
        var chosen: [Date]?
        if !byMonthDay.isEmpty {
            let wanted = resolvedMonthDays(in: monthStart)
            chosen = all.filter { wanted.contains(dayOfMonth($0)) }
        }
        if !byDay.isEmpty {
            let fits = matching(byDay, in: all)
            chosen = chosen.map { picked in picked.filter(fits.contains) } ?? fits
        }
        if let chosen { return chosen }
        // No day given: the same day of the month as the first, skipping months that are too short.
        let day = dayOfMonth(first)
        return all.indices.contains(day - 1) ? [all[day - 1]] : []
    }

    private func matching(_ rules: [Weekday], in scope: [Date]) -> [Date] {
        rules.flatMap { rule -> [Date] in
            let fits = scope.filter { weekday($0) == rule.weekday }
            guard let position = rule.position else { return fits }
            let index = position > 0 ? position - 1 : fits.count + position
            return fits.indices.contains(index) ? [fits[index]] : []
        }
    }

    /// BYMONTHDAY values as days of this month, counting negative values back from the end.
    private func resolvedMonthDays(in date: Date) -> Set<Int> {
        let length = wallCalendar.range(of: .day, in: .month, for: date)?.count ?? 31
        return Set(byMonthDay.compactMap { value in
            let day = value > 0 ? value : length + value + 1
            return (1...length).contains(day) ? day : nil
        })
    }

    private func dayList(from start: Date, to end: Date) -> [Date] {
        var days: [Date] = []
        var day = start
        while day < end {
            days.append(day)
            day = day.addingTimeInterval(86_400)
        }
        return days
    }

    private func weekday(_ date: Date) -> Int { wallCalendar.component(.weekday, from: date) }
    private func month(_ date: Date) -> Int { wallCalendar.component(.month, from: date) }
    private func dayOfMonth(_ date: Date) -> Int { wallCalendar.component(.day, from: date) }
}

// MARK: - Turning lines into events

/// Reads times and events, knowing the file's own time zones.
struct StampReader {
    var fileZones: [String: EventZone]
    var local: EventZone

    struct WallTime {
        var wall: Date
        var isDateOnly: Bool
        var isUTC: Bool
    }

    /// Reads 20261125, 20261125T090000 and 20261125T090000Z.
    static func wallTime(_ text: String) -> WallTime? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let characters = Array(text)
        guard characters.count >= 8, characters[0..<8].allSatisfy(\.isNumber) else { return nil }
        let number = { (range: Range<Int>) in Int(String(characters[range])) ?? 0 }
        var parts = DateComponents(year: number(0..<4), month: number(4..<6), day: number(6..<8))
        var isDateOnly = true
        if characters.count >= 15, characters[8] == "T", characters[9..<15].allSatisfy(\.isNumber) {
            parts.hour = number(9..<11)
            parts.minute = number(11..<13)
            parts.second = number(13..<15)
            isDateOnly = false
        }
        guard let wall = wallCalendar.date(from: parts) else { return nil }
        return WallTime(wall: wall, isDateOnly: isDateOnly, isUTC: !isDateOnly && characters.last == "Z")
    }

    func zone(named id: String?) -> EventZone {
        guard let id = id?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), !id.isEmpty else { return local }
        if let timeZone = TimeZone(identifier: id) { return .zone(timeZone) }
        if let zone = fileZones[id] { return zone }
        // Some apps prefix the zone with a path, such as /citadel.org/20190101_1/Europe/London.
        let pieces = id.split(separator: "/")
        for length in [3, 2] where pieces.count > length {
            if let timeZone = TimeZone(identifier: pieces.suffix(length).joined(separator: "/")) { return .zone(timeZone) }
        }
        return local
    }

    func stamps(_ line: ContentLine) -> [CalendarFile.Stamp] {
        line.value.split(separator: ",").compactMap { piece in
            guard let time = Self.wallTime(String(piece)) else { return nil }
            let zone: EventZone = time.isUTC ? .utc : (time.isDateOnly ? local : self.zone(named: line.parameters["TZID"]))
            return CalendarFile.Stamp(wall: time.wall, isDateOnly: time.isDateOnly, zone: zone)
        }
    }

    func event(from component: ContentLine.Component) -> CalendarFile.Event? {
        guard let startLine = component.first("DTSTART"), let start = stamps(startLine).first else { return nil }
        let title = component.value("SUMMARY").map(ContentLine.unescape)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = component.value("LOCATION").map(ContentLine.unescape)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uid = component.value("UID")?.trimmingCharacters(in: .whitespaces)
            ?? "\(title)|\(Int(start.wall.timeIntervalSince1970))"

        var lengthDays = 0
        var lengthSeconds: TimeInterval = 0
        if let endLine = component.first("DTEND"), let end = stamps(endLine).first {
            if start.isDateOnly {
                lengthDays = max(0, wallCalendar.dateComponents([.day], from: start.wall, to: end.wall).day ?? 0)
            } else {
                lengthSeconds = max(0, end.moment.timeIntervalSince(start.moment))
            }
        } else if let duration = component.value("DURATION").flatMap(Self.duration) {
            lengthDays = duration.days
            lengthSeconds = duration.seconds
        } else if start.isDateOnly {
            lengthDays = 1
        }

        var skippedMoments = Set<Date>()
        var skippedDays = Set<Date>()
        for line in component.all("EXDATE") {
            for stamp in stamps(line) {
                if stamp.isDateOnly && !start.isDateOnly {
                    skippedDays.insert(stamp.wall)
                } else {
                    skippedMoments.insert(stamp.moment)
                }
            }
        }

        var seen = Set<String>()
        let emails = (component.all("ATTENDEE") + component.all("ORGANIZER")).compactMap { line -> String? in
            let value = line.value.trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("mailto:") else { return nil }
            let address = value.dropFirst(7).trimmingCharacters(in: .whitespaces).lowercased()
            return address.isEmpty ? nil : address
        }.filter { seen.insert($0).inserted }

        return CalendarFile.Event(
            uid: uid,
            title: title,
            location: location,
            start: start,
            startMoment: start.moment,
            rule: component.value("RRULE").flatMap(RecurrenceRule.init),
            extraStarts: component.all("RDATE").flatMap(stamps),
            recurrenceID: component.first("RECURRENCE-ID").flatMap { stamps($0).first },
            isCancelled: component.value("STATUS")?.uppercased() == "CANCELLED",
            attendeeEmails: emails,
            lengthDays: lengthDays,
            lengthSeconds: lengthSeconds,
            skippedMoments: skippedMoments,
            skippedDays: skippedDays
        )
    }

    /// Reads durations such as PT45M, PT1H30M, P1D and P2W.
    static func duration(_ text: String) -> (days: Int, seconds: TimeInterval)? {
        var text = text.trimmingCharacters(in: .whitespaces).uppercased()
        if text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        var days = 0
        var seconds: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in text.dropFirst() {
            if character.isNumber {
                number.append(character)
                continue
            }
            let value = Int(number) ?? 0
            number = ""
            switch character {
            case "T": inTime = true
            case "W": days += value * 7
            case "D": days += value
            case "H" where inTime: seconds += TimeInterval(value * 3600)
            case "M" where inTime: seconds += TimeInterval(value * 60)
            case "S" where inTime: seconds += TimeInterval(value)
            default: return nil
            }
        }
        return (days, seconds)
    }
}

/// One line of an iCalendar file, such as `DTSTART;TZID=Europe/London:20261125T090000`.
struct ContentLine: Sendable {
    var name: String
    var parameters: [String: String]
    var value: String

    struct Component: Sendable {
        var name: String
        var properties: [ContentLine] = []
        var children: [Component] = []

        func first(_ name: String) -> ContentLine? { properties.first { $0.name == name } }
        func all(_ name: String) -> [ContentLine] { properties.filter { $0.name == name } }
        func value(_ name: String) -> String? { first(name)?.value }
    }

    /// Splits the file into lines, joining the folded ones that carry on with a leading space or tab.
    static func lines(in text: String) -> [ContentLine] {
        var unfolded: [String] = []
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                unfolded.append(String(raw))
            }
        }
        return unfolded.compactMap(ContentLine.init)
    }

    init?(_ text: String) {
        var head = ""
        var value: Substring?
        var inQuotes = false
        for index in text.indices {
            let character = text[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":" && !inQuotes {
                value = text[text.index(after: index)...]
                break
            }
            head.append(character)
        }
        guard let value else { return nil }

        var pieces: [String] = []
        var current = ""
        inQuotes = false
        for character in head {
            if character == "\"" { inQuotes.toggle() }
            if character == ";" && !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)

        guard let name = pieces.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        self.name = name.uppercased()
        self.value = String(value)
        parameters = [:]
        for piece in pieces.dropFirst() {
            let bits = piece.split(separator: "=", maxSplits: 1)
            guard bits.count == 2 else { continue }
            parameters[bits[0].trimmingCharacters(in: .whitespaces).uppercased()] =
                bits[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
    }

    /// Nests lines into components by their BEGIN and END lines. A file that was cut short still counts.
    static func components(_ lines: [ContentLine]) -> [Component] {
        var stack = [Component(name: "")]
        for line in lines {
            switch line.name {
            case "BEGIN":
                stack.append(Component(name: line.value.trimmingCharacters(in: .whitespaces).uppercased()))
            case "END":
                guard stack.count > 1 else { continue }
                let finished = stack.removeLast()
                stack[stack.count - 1].children.append(finished)
            default:
                stack[stack.count - 1].properties.append(line)
            }
        }
        while stack.count > 1 {
            let finished = stack.removeLast()
            stack[stack.count - 1].children.append(finished)
        }
        return stack[0].children
    }

    /// Undoes the escaping of text values: \n, \, and \; and \\.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
