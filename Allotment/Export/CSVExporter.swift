import Foundation

enum CSVExporter {
    static let detailHeader = ["Date", "Start", "End", "Client", "Project", "Activity", "Notes", "Billable", "Hours", "Rate", "Amount", "Source"]

    /// One row per time entry, using column names most timesheet tools accept on import.
    static func detailed(_ report: Report) -> Data {
        var lines = [detailHeader]
        for row in report.rows {
            lines.append([
                Fmt.isoDay(row.start),
                timeString(row.start),
                row.end.map(timeString) ?? "",
                row.clientName,
                row.projectName,
                row.activityName,
                row.notes,
                row.isBillable ? "Yes" : "No",
                number(row.hours),
                row.rate > 0 ? number(row.rate) : "",
                row.amount > 0 ? number(row.amount) : "",
                row.source.rawValue,
            ])
        }
        return encode(lines)
    }

    /// One row per client with allocation and variance.
    static func summary(_ report: Report) -> Data {
        var lines = [["Client", "Hours", "Billable hours", report.allocationLabel, "Variance", "Amount (\(report.currencyCode))"]]
        for group in report.byClient {
            lines.append([
                group.name,
                number(group.hours),
                number(group.billableHours),
                group.allocated.map(number) ?? "",
                group.variance.map(number) ?? "",
                number(group.amount),
            ])
        }
        lines.append(["Total", number(report.totalHours), number(report.billableHours), "", "", number(report.amount)])
        return encode(lines)
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func encode(_ lines: [[String]]) -> Data {
        let text = lines.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        // The byte order mark tells Excel the file is UTF-8, so accented names survive.
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func timeString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
