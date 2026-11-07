import Foundation

/// An import sheet in the column order of Workday's "Import Reported Time Blocks" EIB, one row per day and line,
/// as hours-only time blocks. Templates differ between tenants, so an admin pastes these columns into their own.
enum WorkdayExporter {
    static let header = ["Spreadsheet Key", "Worker", "Date", "Time Entry Code", "Quantity", "Project", "Project Task", "Comment"]

    static func csv(_ period: WorkdayPeriod) -> Data {
        var lines = [header]
        for (index, block) in period.blocks.enumerated() {
            lines.append([
                "\(index + 1)",
                period.employeeID,
                Fmt.isoDay(block.day),
                block.line.timeCode,
                String(format: "%.2f", block.line.hours[block.day] ?? 0),
                block.line.project,
                block.line.task,
                block.line.comments[block.day] ?? "",
            ])
        }
        return CSVExporter.encode(lines)
    }

    static func excel(_ period: WorkdayPeriod) -> Data {
        typealias C = XLSXWriter.Cell
        var rows: [[C]] = [header.map { C.text($0, .header) }]
        for (index, block) in period.blocks.enumerated() {
            rows.append([
                .number(Double(index + 1), .normal),
                .text(period.employeeID),
                .date(block.day),
                .text(block.line.timeCode),
                .number(block.line.hours[block.day] ?? 0),
                .text(block.line.project),
                .text(block.line.task),
                .text(block.line.comments[block.day] ?? ""),
            ])
        }
        if !period.blocks.isEmpty {
            let last = period.blocks.count + 1
            rows.append([.text("Total", .bold), .empty, .empty, .empty, .formula("SUM(E2:E\(last))", cached: period.total)])
        }
        let blocks = XLSXWriter.Sheet(name: "Time Blocks", rows: rows, columnWidths: [15, 12, 12, 22, 10, 16, 16, 50], frozenRows: 1)

        let about: [[C]] = [
            [.text("Workday time import", .title)],
            [.text("Period", .muted), .text(Fmt.range(period.interval))],
            [.text("Employee ID", .muted), .text(period.employeeID.isEmpty ? "Not set" : period.employeeID)],
            [.text("Total hours", .muted), .number(period.total)],
            [],
            [.text("Each row is one hours-only time block for one day, in the column order of the Import Reported Time Blocks EIB.")],
            [.text("Copy the rows into the EIB template downloaded from your Workday tenant, then load it as usual.")],
            [.text("Time entry codes and projects are the reference IDs set in Allotment's Workday setup.")],
        ]
        let aboutSheet = XLSXWriter.Sheet(name: "About", rows: about, columnWidths: [16, 60])
        return XLSXWriter.workbook([blocks, aboutSheet])
    }

    static func suggestedName(_ period: WorkdayPeriod, fileExtension: String) -> String {
        "Workday time \(Fmt.isoDay(period.interval.start)) to \(Fmt.isoDay(period.interval.end.addingTimeInterval(-1))).\(fileExtension)"
    }
}
