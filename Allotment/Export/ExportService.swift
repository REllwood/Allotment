import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case excel
    case pdf
    case csvDetailed
    case csvSummary

    var id: Self { self }

    var title: String {
        switch self {
        case .excel: "Excel workbook (.xlsx)"
        case .pdf: "PDF timesheet"
        case .csvDetailed: "CSV, one row per entry"
        case .csvSummary: "CSV, totals by client"
        }
    }

    var symbol: String {
        switch self {
        case .excel: "tablecells"
        case .pdf: "doc.richtext"
        case .csvDetailed, .csvSummary: "doc.plaintext"
        }
    }

    var fileExtension: String {
        switch self {
        case .excel: "xlsx"
        case .pdf: "pdf"
        case .csvDetailed, .csvSummary: "csv"
        }
    }

    var contentType: UTType {
        switch self {
        case .excel: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
        case .pdf: .pdf
        case .csvDetailed, .csvSummary: .commaSeparatedText
        }
    }

    @MainActor
    func data(for report: Report) -> Data {
        switch self {
        case .excel: ExcelExporter.workbook(report)
        case .pdf: PDFExporter.render(report)
        case .csvDetailed: CSVExporter.detailed(report)
        case .csvSummary: CSVExporter.summary(report)
        }
    }
}

@MainActor
enum ExportService {
    static func suggestedName(for report: Report, format: ExportFormat) -> String {
        let interval = report.filter.interval
        let last = interval.end.addingTimeInterval(-1)
        let who = report.singleClientName.map { " \($0)" } ?? ""
        let suffix = format == .csvSummary ? " summary" : ""
        let name = "Timesheet\(who) \(Fmt.isoDay(interval.start)) to \(Fmt.isoDay(last))\(suffix)"
        return name.replacingOccurrences(of: "/", with: "-") + "." + format.fileExtension
    }

    /// Asks where to save, writes the file and reveals it in Finder. Returns the saved location,
    /// or nil when you cancel. Throws when the file cannot be written.
    @discardableResult
    static func export(_ report: Report, as format: ExportFormat) throws -> URL? {
        try save(title: "Export Timesheet", name: suggestedName(for: report, format: format), type: format.contentType) {
            format.data(for: report)
        }
    }

    /// Exports a Workday import sheet as Excel or CSV.
    @discardableResult
    static func exportWorkday(_ period: WorkdayPeriod, excel: Bool) throws -> URL? {
        let format: ExportFormat = excel ? .excel : .csvDetailed
        return try save(title: "Export for Workday", name: WorkdayExporter.suggestedName(period, fileExtension: format.fileExtension),
                    type: format.contentType) {
            excel ? WorkdayExporter.excel(period) : WorkdayExporter.csv(period)
        }
    }

    @discardableResult
    static func save(title: String, name: String, type: UTType, data: () -> Data) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data().write(to: url, options: .atomic)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }
}
