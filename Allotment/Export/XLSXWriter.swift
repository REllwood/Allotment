import Foundation

/// A small Office Open XML spreadsheet writer. It covers text, numbers, dates, formulas and a few styles,
/// which is everything a timesheet needs, without any third-party dependency.
struct XLSXWriter {
    enum Style: Int {
        case normal = 0
        case header = 1
        case date = 2
        case time = 3
        case hours = 4
        case money = 5
        case title = 6
        case totalHours = 7
        case totalMoney = 8
        case percent = 9
        case bold = 10
        case muted = 11
    }

    enum Cell {
        case text(String, Style = .normal)
        case number(Double, Style = .hours)
        case date(Date)
        case time(Date)
        /// A formula with its value worked out in advance, for apps that show the file without recalculating.
        case formula(String, cached: Double, Style = .totalHours)
        case empty
    }

    struct Sheet {
        var name: String
        var rows: [[Cell]]
        var columnWidths: [Double] = []
        /// Rows kept visible at the top while scrolling.
        var frozenRows = 0
    }

    static func workbook(_ sheets: [Sheet], date: Date = .now) -> Data {
        var zip = ZipArchive(date: date)
        zip.add("[Content_Types].xml", contentTypes(sheetCount: sheets.count))
        zip.add("_rels/.rels", rootRelationships)
        zip.add("docProps/app.xml", appProperties)
        zip.add("docProps/core.xml", coreProperties(date: date))
        zip.add("xl/workbook.xml", workbookXML(sheets))
        zip.add("xl/_rels/workbook.xml.rels", workbookRelationships(sheetCount: sheets.count))
        zip.add("xl/styles.xml", styles)
        for (index, sheet) in sheets.enumerated() {
            zip.add("xl/worksheets/sheet\(index + 1).xml", sheetXML(sheet))
        }
        return zip.finish()
    }

    // MARK: - Cells

    static func columnName(_ index: Int) -> String {
        var name = ""
        var n = index + 1
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// Excel counts days from 30 December 1899, in local time.
    static func serialDate(_ date: Date) -> Double {
        let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        return local / 86_400 + 25_569
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                // XML 1.0 does not allow other control characters at all.
                if scalar.value >= 0x20 && !(0xFFFE...0xFFFF).contains(scalar.value) {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    private static func cellXML(_ cell: Cell, ref: String) -> String {
        switch cell {
        case .empty:
            return ""
        case let .text(text, style):
            return "<c r=\"\(ref)\" t=\"inlineStr\" s=\"\(style.rawValue)\"><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
        case let .number(value, style):
            guard value.isFinite else { return "" }
            return "<c r=\"\(ref)\" s=\"\(style.rawValue)\"><v>\(value)</v></c>"
        case let .date(date):
            return "<c r=\"\(ref)\" s=\"\(Style.date.rawValue)\"><v>\(serialDate(date).rounded(.down))</v></c>"
        case let .time(date):
            let fraction = serialDate(date) - serialDate(date).rounded(.down)
            return "<c r=\"\(ref)\" s=\"\(Style.time.rawValue)\"><v>\(fraction)</v></c>"
        case let .formula(formula, cached, style):
            return "<c r=\"\(ref)\" s=\"\(style.rawValue)\"><f>\(escape(formula))</f><v>\(cached)</v></c>"
        }
    }

    // MARK: - Parts

    private static func sheetXML(_ sheet: Sheet) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        """
        if sheet.frozenRows > 0 {
            xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"\(sheet.frozenRows)\" topLeftCell=\"A\(sheet.frozenRows + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        } else {
            xml += "<sheetViews><sheetView workbookViewId=\"0\"/></sheetViews>"
        }
        if !sheet.columnWidths.isEmpty {
            xml += "<cols>"
            for (index, width) in sheet.columnWidths.enumerated() {
                xml += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (rowIndex, row) in sheet.rows.enumerated() {
            xml += "<row r=\"\(rowIndex + 1)\">"
            for (columnIndex, cell) in row.enumerated() {
                xml += cellXML(cell, ref: "\(columnName(columnIndex))\(rowIndex + 1)")
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    /// Sheet names must be unique, at most 31 characters, and free of a few reserved characters.
    static func safeSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { name in
            let cleaned = String(name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            var candidate = cleaned.isEmpty ? "Sheet" : cleaned
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " \(counter)"
                candidate = String(cleaned.prefix(31 - suffix.count)) + suffix
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    private static func workbookXML(_ sheets: [Sheet]) -> String {
        let names = safeSheetNames(sheets.map(\.name))
        let entries = names.enumerated().map { index, name in
            "<sheet name=\"\(escape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>\(entries)</sheets></workbook>
        """
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        var rels = (1...max(1, sheetCount)).map { i in
            "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }.joined()
        rels += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
        """
    }

    private static func contentTypes(sheetCount: Int) -> String {
        let sheets = (1...max(1, sheetCount)).map { i in
            "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\(sheets)<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
        """
    }

    private static let rootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
    """

    private static let appProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Allotment</Application></Properties>
    """

    private static func coreProperties(date: Date) -> String {
        let stamp = date.formatted(.iso8601)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>Timesheet</dc:title><dc:creator>Allotment</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created></cp:coreProperties>
        """
    }

    /// Style indexes line up with `Style`.
    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <numFmts count="3"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="hh:mm"/><numFmt numFmtId="166" formatCode="0.00"/></numFmts>\
    <fonts count="4"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="16"/><name val="Calibri"/><family val="2"/></font><font><sz val="11"/><color rgb="FF6E6E73"/><name val="Calibri"/><family val="2"/></font></fonts>\
    <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFEDEDF2"/><bgColor indexed="64"/></patternFill></fill></fills>\
    <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top style="thin"><color rgb="FF8E8E93"/></top><bottom/><diagonal/></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="12">\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>\
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
    <xf numFmtId="166" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1"/>\
    <xf numFmtId="4" fontId="1" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1"/>\
    <xf numFmtId="9" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>\
    <xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
    </cellXfs>\
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
    </styleSheet>
    """
}
