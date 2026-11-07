import Foundation

enum ExcelExporter {
    static func workbook(_ report: Report) -> Data {
        XLSXWriter.workbook([summarySheet(report), entriesSheet(report), dailySheet(report)], date: report.generatedAt)
    }

    private static func summarySheet(_ report: Report) -> XLSXWriter.Sheet {
        typealias C = XLSXWriter.Cell
        var rows: [[C]] = [
            [.text(report.title, .title)],
            [.text("Period", .muted), .text(Fmt.range(report.filter.interval))],
            [.text("Prepared by", .muted), .text(report.userName)],
            [.text("Generated", .muted), .text(report.generatedAt.formatted(date: .abbreviated, time: .shortened))],
        ]
        if report.rounding != .none {
            rows.append([.text("Rounding", .muted), .text(report.rounding.title)])
        }
        rows.append([])

        let headerRow = rows.count + 1
        rows.append([.text("Client", .header), .text("Hours", .header), .text("Billable hours", .header),
                     .text(report.allocationLabel, .header), .text("Variance", .header), .text("Amount (\(report.currencyCode))", .header)])
        for group in report.byClient {
            rows.append([
                .text(group.name),
                .number(group.hours),
                .number(group.billableHours),
                group.allocated.map { .number($0) } ?? .empty,
                group.variance.map { .number($0) } ?? .empty,
                .number(group.amount, .money),
            ])
        }
        let first = headerRow + 1
        let last = headerRow + report.byClient.count
        if !report.byClient.isEmpty {
            rows.append([
                .text("Total", .bold),
                .formula("SUM(B\(first):B\(last))", cached: report.totalHours),
                .formula("SUM(C\(first):C\(last))", cached: report.billableHours),
                .empty, .empty,
                .formula("SUM(F\(first):F\(last))", cached: report.amount, .totalMoney),
            ])
        }

        rows.append([])
        rows.append([.text("Activity", .header), .text("Hours", .header), .text("Billable hours", .header)])
        for group in report.byActivity {
            rows.append([.text(group.name), .number(group.hours), .number(group.billableHours)])
        }

        rows.append([])
        rows.append([.text("Key figures", .header), .text("", .header)])
        rows.append([.text("Total hours"), .number(report.totalHours)])
        rows.append([.text("Billable hours"), .number(report.billableHours)])
        rows.append([.text("Admin hours"), .number(report.adminHours)])
        rows.append([.text(report.isInProgress ? "Capacity to date" : "Capacity hours"), .number(report.capacityToDate)])
        rows.append([.text("Utilisation (billable over capacity)"), .number(report.utilization, .percent)])

        return XLSXWriter.Sheet(name: "Summary", rows: rows, columnWidths: [34, 12, 15, 16, 12, 18])
    }

    private static func entriesSheet(_ report: Report) -> XLSXWriter.Sheet {
        typealias C = XLSXWriter.Cell
        var rows: [[C]] = [CSVExporter.detailHeader.dropLast().map { C.text($0, .header) }]
        for row in report.rows {
            rows.append([
                .date(row.start),
                .time(row.start),
                row.end.map { .time($0) } ?? .text("Running"),
                .text(row.clientName),
                .text(row.projectName),
                .text(row.activityName),
                .text(row.notes),
                .text(row.isBillable ? "Yes" : "No"),
                .number(row.hours),
                row.rate > 0 ? .number(row.rate, .money) : .empty,
                row.amount > 0 ? .number(row.amount, .money) : .empty,
            ])
        }
        if !report.rows.isEmpty {
            let last = report.rows.count + 1
            rows.append([.text("Total", .bold), .empty, .empty, .empty, .empty, .empty, .empty, .empty,
                         .formula("SUM(I2:I\(last))", cached: report.totalHours), .empty,
                         .formula("SUM(K2:K\(last))", cached: report.amount, .totalMoney)])
        }
        return XLSXWriter.Sheet(name: "Entries", rows: rows, columnWidths: [12, 8, 8, 22, 22, 16, 40, 9, 9, 10, 12], frozenRows: 1)
    }

    private static func dailySheet(_ report: Report) -> XLSXWriter.Sheet {
        typealias C = XLSXWriter.Cell
        let clients = report.byClient.filter { $0.hours > 0 }.map(\.name)
        var rows: [[C]] = [[.text("Date", .header)] + clients.map { .text($0, .header) } + [.text("Total", .header)]]
        for day in report.days where day.hours > 0 {
            rows.append([.date(day.date)] + clients.map { name in
                day.byClient[name].map { .number($0) } ?? .empty
            } + [.number(day.hours)])
        }
        return XLSXWriter.Sheet(name: "Daily", rows: rows, columnWidths: [12] + clients.map { _ in 16 } + [10], frozenRows: 1)
    }
}
