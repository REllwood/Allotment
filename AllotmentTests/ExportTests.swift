import Foundation
import PDFKit
import Testing
@testable import Allotment

@MainActor
struct ExportTests {
    /// A month of sample data with awkward characters added, to exercise escaping.
    private func makeReport() -> Report {
        let store = TimeStore(fileURL: nil)
        store.replaceAll(with: SampleData.make(now: Fixture.localDate(2026, 11, 20, 15)))
        let acme = store.activeClients[0]
        store.save(TimeEntry(clientID: acme.id, notes: "Quote \"draft\", v2 & <final>\nsecond line \u{1}",
                             start: Fixture.localDate(2026, 11, 19, 18), end: Fixture.localDate(2026, 11, 19, 19, 30), isBillable: true, source: .manual))
        let month = DateInterval(start: Fixture.localDate(2026, 11, 1), end: Fixture.localDate(2026, 12, 1))
        return ReportBuilder.build(ReportFilter(interval: month), store: store, now: Fixture.localDate(2026, 11, 20, 15))
    }

    /// Where exported samples are written, so they can be opened and checked outside the tests.
    private var outputFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AllotmentExportCheck")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func reportTotalsAddUp() {
        let report = makeReport()
        #expect(report.rows.count > 40)
        #expect(abs(report.byClient.reduce(0) { $0 + $1.hours } - report.totalHours) < 0.0001)
        #expect(abs(report.byActivity.reduce(0) { $0 + $1.hours } - report.totalHours) < 0.0001)
        #expect(abs(report.days.reduce(0) { $0 + $1.hours } - report.totalHours) < 0.0001)
        #expect(report.billableHours <= report.totalHours)
        #expect(report.isInProgress)
    }

    @Test func csvEscapesAndHasOneRowPerEntry() throws {
        let report = makeReport()
        let data = CSVExporter.detailed(report)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("Date,Start,End,Client,Project,Activity,Notes,Billable,Hours,Rate,Amount,Source\r\n"))
        #expect(text.contains("\"Quote \"\"draft\"\", v2 & <final>\nsecond line \u{1}\""))
        // Embedded newlines are quoted, so count record separators instead of lines.
        #expect(text.components(separatedBy: "\r\n").count - 2 == report.rows.count)
        try data.write(to: outputFolder.appending(path: "detailed.csv"))
        try CSVExporter.summary(report).write(to: outputFolder.appending(path: "summary.csv"))
    }

    @Test func excelWorkbookIsAValidZip() throws {
        let report = makeReport()
        let data = ExcelExporter.workbook(report)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(data.suffix(22).prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
        try data.write(to: outputFolder.appending(path: "timesheet.xlsx"))
    }

    @Test func pdfHasPagesAndText() throws {
        let report = makeReport()
        let data = PDFExporter.render(report)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount >= 2)
        let text = document.string ?? ""
        #expect(text.contains("Timesheet"))
        #expect(text.contains("Acme Studio"))
        #expect(text.contains("Page 1 of \(document.pageCount)"))
        try data.write(to: outputFolder.appending(path: "timesheet.pdf"))
    }

    @Test func crcMatchesKnownValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func columnNames() {
        #expect(XLSXWriter.columnName(0) == "A")
        #expect(XLSXWriter.columnName(25) == "Z")
        #expect(XLSXWriter.columnName(26) == "AA")
        #expect(XLSXWriter.columnName(701) == "ZZ")
    }

    @Test func sheetNamesAreMadeSafe() {
        let names = XLSXWriter.safeSheetNames(["Summary", "summary", "A/B:C*", String(repeating: "x", count: 40)])
        #expect(names[0] == "Summary")
        #expect(names[1] == "summary 2")
        #expect(names[2] == "ABC")
        #expect(names[3].count == 31)
    }

    @Test func xmlEscapingDropsControlCharacters() {
        #expect(XLSXWriter.escape("a<b & \"c\"\u{1}") == "a&lt;b &amp; &quot;c&quot;")
    }
}
