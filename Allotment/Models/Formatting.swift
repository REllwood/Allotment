import Foundation

enum Fmt {
    /// "1:05" or, with seconds, "1:05:09".
    static func clock(_ seconds: TimeInterval, showSeconds: Bool = false) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if showSeconds {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", h, m)
    }

    /// "2h 05m", "16h", "45m" or "0m". Every duration on screen uses this, apart from running timers and Workday hours.
    static func hm(_ seconds: TimeInterval) -> String {
        let total = Int((max(0, seconds) / 60).rounded())
        let h = total / 60
        let m = total % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return String(format: "%dh %02dm", h, m)
    }

    /// Decimal hours such as "1.25".
    static func decimal(_ hours: Double, digits: Int = 2) -> String {
        hours.formatted(.number.precision(.fractionLength(digits)))
    }

    /// A number of hours written like any other duration, such as "12h 30m".
    static func hours(_ hours: Double) -> String {
        hm(hours * 3600)
    }

    /// Hours as Workday wants them, such as "37.50 h". Only for Workday pages.
    static func decimalHours(_ hours: Double) -> String {
        decimal(hours) + " h"
    }

    static func money(_ amount: Double, code: String) -> String {
        amount.formatted(.currency(code: code).precision(.fractionLength(2)))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "2026-11-02" for the local calendar day. ISO 8601 format styles default to UTC, which shifts the date
    /// for anyone far from Greenwich.
    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "3 to 9 Nov 2026", with the end shown inclusively.
    static func range(_ interval: DateInterval) -> String {
        let lastDay = interval.end.addingTimeInterval(-1)
        let sameYear = Calendar.current.isDate(interval.start, equalTo: lastDay, toGranularity: .year)
        let startStyle: Date.FormatStyle = sameYear
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year()
        if Calendar.current.isDate(interval.start, inSameDayAs: lastDay) {
            return lastDay.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return "\(interval.start.formatted(startStyle)) to \(lastDay.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    /// Parses "1:30", "1.5", "90m" or "1h 30m" into seconds.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let h = parts[0], let m = parts[1], m < 60 else { return nil }
            return (h * 60 + m) * 60
        }
        if trimmed.contains("h") || trimmed.contains("m") {
            var seconds = 0.0
            var number = ""
            for ch in trimmed {
                if ch.isNumber || ch == "." || ch == "," {
                    number.append(ch == "," ? "." : ch)
                } else if ch == "h" || ch == "m" {
                    guard let value = Double(number) else { return nil }
                    seconds += ch == "h" ? value * 3600 : value * 60
                    number = ""
                }
            }
            if let trailing = Double(number) { seconds += trailing * 60 }
            return seconds
        }
        guard let hours = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return hours * 3600
    }
}
