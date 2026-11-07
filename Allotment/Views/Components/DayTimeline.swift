import SwiftUI

/// One day as a strip of hours: time entries as coloured blocks, calendar events as a faint lane above them,
/// and a line for now. Gaps in the day are easy to spot, and clicking a block opens the entry.
struct DayTimeline: View {
    let day: DateInterval
    let entries: [TimeEntry]
    var events: [CalendarEvent] = []
    let now: Date
    @Environment(TimeStore.self) private var store
    @Environment(Router.self) private var router

    private let eventLane: CGFloat = 10
    private let entryLane: CGFloat = 30
    private let labelHeight: CGFloat = 14
    private let gap: CGFloat = 6

    var body: some View {
        let calendar = store.schedule.calendar
        let range = visibleRange(calendar)
        let span = max(3600, range.end.timeIntervalSince(range.start))
        let hours = hourMarks(from: range.start, to: range.end, calendar: calendar)
        let step = hours.count > 13 ? 2 : 1
        let eventsTop: CGFloat = 0
        let entriesTop = events.isEmpty ? 0 : eventLane + gap
        let labelsTop = entriesTop + entryLane + gap
        let height = labelsTop + labelHeight

        GeometryReader { proxy in
            let width = proxy.size.width
            let x: (Date) -> CGFloat = { width * CGFloat(min(span, max(0, $0.timeIntervalSince(range.start))) / span) }

            ZStack(alignment: .topLeading) {
                ForEach(hours, id: \.self) { hour in
                    Rectangle()
                        .fill(.primary.opacity(0.07))
                        .frame(width: 1, height: labelsTop)
                        .offset(x: x(hour))
                }

                ForEach(events) { event in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(hex: event.calendarColorHex).opacity(0.45))
                        .frame(width: max(3, x(event.end) - x(event.start) - 1), height: eventLane)
                        .offset(x: x(event.start), y: eventsTop)
                        .help("\(event.title) · \(Fmt.time(event.start)) to \(Fmt.time(event.end))")
                }

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.045))
                    .frame(width: width, height: entryLane)
                    .offset(y: entriesTop)

                ForEach(entries) { entry in
                    let end = entry.end ?? now
                    let color = store.color(for: entry.clientID)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.gradient)
                        .overlay(alignment: .leading) {
                            if x(end) - x(entry.start) > 70 {
                                Text(store.title(for: entry))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                            }
                        }
                        .frame(width: max(4, x(end) - x(entry.start) - 1.5), height: entryLane - 6)
                        .offset(x: x(entry.start) + 0.75, y: entriesTop + 3)
                        .help(helpText(for: entry, end: end))
                        .onTapGesture { router.editing = EntryEditTarget(entryID: entry.id, day: entry.start) }
                }

                if day.contains(now) {
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 2, height: labelsTop + 2)
                        .offset(x: x(now) - 1, y: -1)
                        .help("Now")
                }

                ForEach(Array(hours.enumerated()), id: \.element) { index, hour in
                    if index % step == 0 {
                        Text(hour.formatted(.dateTime.hour()))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .position(x: min(width - 16, max(16, x(hour))), y: labelsTop + labelHeight / 2)
                    }
                }
            }
        }
        .frame(height: height)
    }

    /// Working hours, stretched to take in anything tracked or booked outside them.
    private func visibleRange(_ calendar: Calendar) -> (start: Date, end: Date) {
        let dayStart = day.start
        var start = calendar.date(byAdding: .hour, value: 8, to: dayStart) ?? dayStart
        var end = calendar.date(byAdding: .hour, value: 18, to: dayStart) ?? day.end
        for entry in entries {
            start = min(start, entry.start)
            end = max(end, entry.end ?? now)
        }
        for event in events {
            start = min(start, event.start)
            end = max(end, event.end)
        }
        if day.contains(now) { end = max(end, now) }
        let roundedStart = calendar.dateInterval(of: .hour, for: max(dayStart, start))?.start ?? start
        let endHour = calendar.dateInterval(of: .hour, for: min(day.end, end))
        let roundedEnd = endHour.map { $0.start == min(day.end, end) ? $0.start : $0.end } ?? end
        return (roundedStart, min(day.end, roundedEnd))
    }

    private func hourMarks(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var marks: [Date] = []
        var cursor = start
        while cursor <= end {
            marks.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return marks
    }

    private func helpText(for entry: TimeEntry, end: Date) -> String {
        let detail = [store.subtitle(for: entry), entry.notes].filter { !$0.isEmpty }.joined(separator: " · ")
        let times = entry.isRunning ? "\(Fmt.time(entry.start)) to now" : "\(Fmt.time(entry.start)) to \(Fmt.time(end))"
        return "\(store.title(for: entry))\(detail.isEmpty ? "" : " · \(detail)")\n\(times) · \(Fmt.hm(end.timeIntervalSince(entry.start)))\nClick to edit"
    }
}
