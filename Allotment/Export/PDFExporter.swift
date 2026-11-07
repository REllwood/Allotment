import AppKit

/// Draws a paginated timesheet PDF: a summary by client followed by every entry, grouped by day.
@MainActor
enum PDFExporter {
    private struct Block {
        var height: CGFloat
        /// Entry rows repeat the column headings when they continue on a new page.
        var isEntryRow = false
        var keepWithNext = false
        var draw: (CGFloat) -> Void
    }

    private static let ink = NSColor(white: 0.1, alpha: 1)
    private static let muted = NSColor(white: 0.42, alpha: 1)
    private static let rule = NSColor(white: 0.86, alpha: 1)
    private static let band = NSColor(white: 0.955, alpha: 1)

    static func render(_ report: Report) -> Data {
        let usesLetter = Locale.current.region?.identifier == "US" || Locale.current.region?.identifier == "CA"
        let page = usesLetter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
        let margin: CGFloat = 44
        let width = page.width - margin * 2

        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        let info = [kCGPDFContextTitle: report.title, kCGPDFContextCreator: "Allotment", kCGPDFContextAuthor: report.userName] as CFDictionary
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return Data() }

        var blocks = headerBlocks(report, x: margin, width: width)
        blocks += summaryBlocks(report, x: margin, width: width)
        blocks += entryBlocks(report, x: margin, width: width)
        let entryHeading = entryHeaderBlock(x: margin, width: width)

        // Lay blocks out into pages first, so the footer can say "Page 2 of 5".
        let top = margin
        let bottom = page.height - margin - 24
        var pages: [[(Block, CGFloat)]] = [[]]
        var y = top
        for (index, block) in blocks.enumerated() {
            var needed = block.height
            if block.keepWithNext, index + 1 < blocks.count { needed += blocks[index + 1].height }
            if y + needed > bottom, !(pages.last?.isEmpty ?? true) {
                pages.append([])
                y = top
                if block.isEntryRow {
                    pages[pages.count - 1].append((entryHeading, y))
                    y += entryHeading.height
                }
            }
            pages[pages.count - 1].append((block, y))
            y += block.height
        }

        for (pageIndex, items) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            for (block, y) in items { block.draw(y) }
            text("\(report.userName) · \(report.title) · \(Fmt.range(report.filter.interval))",
                 in: CGRect(x: margin, y: page.height - margin + 4, width: width * 0.75, height: 14), size: 8, color: muted)
            text("Page \(pageIndex + 1) of \(pages.count)",
                 in: CGRect(x: margin + width * 0.75, y: page.height - margin + 4, width: width * 0.25, height: 14),
                 size: 8, color: muted, align: .right)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    // MARK: - Sections

    private static func headerBlocks(_ report: Report, x: CGFloat, width: CGFloat) -> [Block] {
        var meta = "\(Fmt.range(report.filter.interval)) · Prepared by \(report.userName) · Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))"
        if report.rounding != .none { meta += " · \(report.rounding.title)" }
        let figures: [(String, String)] = [
            ("Total hours", Fmt.decimal(report.totalHours)),
            ("Billable hours", Fmt.decimal(report.billableHours)),
            ("Non-billable", Fmt.decimal(report.nonBillableHours)),
            report.hasRates ? ("Billable amount", Fmt.money(report.amount, code: report.currencyCode))
                            : ("Utilisation", Fmt.percent(report.utilization)),
        ]
        return [
            Block(height: 34) { y in
                text(report.title, in: CGRect(x: x, y: y, width: width, height: 30), size: 22, weight: .bold)
            },
            Block(height: 30) { y in
                text(meta, in: CGRect(x: x, y: y, width: width, height: 16), size: 9.5, color: muted)
            },
            Block(height: 74) { y in
                let tileWidth = (width - 3 * 10) / 4
                for (index, figure) in figures.enumerated() {
                    let rect = CGRect(x: x + CGFloat(index) * (tileWidth + 10), y: y, width: tileWidth, height: 52)
                    band.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                    text(figure.0.uppercased(), in: rect.insetBy(dx: 10, dy: 8), size: 7.5, weight: .semibold, color: muted)
                    text(figure.1, in: CGRect(x: rect.minX + 10, y: rect.minY + 22, width: rect.width - 20, height: 22),
                         size: 15, weight: .semibold)
                }
            },
        ]
    }

    private static func summaryBlocks(_ report: Report, x: CGFloat, width: CGFloat) -> [Block] {
        guard !report.byClient.isEmpty else { return [] }
        let numberWidth: CGFloat = 66
        let amountWidth: CGFloat = 84
        let nameWidth = width - numberWidth * 4 - amountWidth
        let columns: [(String, CGFloat, NSTextAlignment)] = [
            ("Client", nameWidth, .left), ("Hours", numberWidth, .right), ("Billable", numberWidth, .right),
            (report.isInProgress ? "To date" : "Allocated", numberWidth, .right), ("Variance", numberWidth, .right), ("Amount", amountWidth, .right),
        ]
        var blocks = [sectionTitle("Summary by client", x: x, width: width, keepWithNext: true),
                      tableHeader(columns, x: x, width: width)]
        for group in report.byClient {
            let values = [
                group.name, Fmt.decimal(group.hours), Fmt.decimal(group.billableHours),
                group.allocated.map { Fmt.decimal($0) } ?? "",
                group.variance.map { ($0 > 0 ? "+" : "") + Fmt.decimal($0) } ?? "",
                group.amount > 0 ? Fmt.money(group.amount, code: report.currencyCode) : "",
            ]
            blocks.append(Block(height: 22) { y in
                var cx = x
                NSColor(hex: group.colorHex).setFill()
                NSBezierPath(ovalIn: CGRect(x: cx, y: y + 7, width: 7, height: 7)).fill()
                for (index, column) in columns.enumerated() {
                    let inset: CGFloat = index == 0 ? 13 : 0
                    let isOver = index == 4 && report.isOver(group)
                    text(values[index], in: CGRect(x: cx + inset, y: y + 4, width: column.1 - inset - 4, height: 16),
                         size: 9.5, weight: index == 0 ? .medium : .regular, color: isOver ? .systemRed : ink, align: column.2)
                    cx += column.1
                }
                hairline(x: x, y: y + 21.5, width: width)
            })
        }
        blocks.append(Block(height: 34) { y in
            let totals = ["Total", Fmt.decimal(report.totalHours), Fmt.decimal(report.billableHours), "", "",
                          report.amount > 0 ? Fmt.money(report.amount, code: report.currencyCode) : ""]
            var cx = x
            for (index, column) in columns.enumerated() {
                text(totals[index], in: CGRect(x: cx, y: y + 5, width: column.1 - 4, height: 16), size: 9.5, weight: .bold, align: column.2)
                cx += column.1
            }
        })
        return blocks
    }

    private static let entryColumns: [(String, CGFloat, NSTextAlignment)] = [
        ("Time", 0.15, .left), ("Client and project", 0.27, .left), ("Activity", 0.15, .left), ("Notes", 0.32, .left), ("Hours", 0.11, .right),
    ]

    private static func entryHeaderBlock(x: CGFloat, width: CGFloat) -> Block {
        tableHeader(entryColumns.map { ($0.0, $0.1 * width, $0.2) }, x: x, width: width)
    }

    private static func entryBlocks(_ report: Report, x: CGFloat, width: CGFloat) -> [Block] {
        guard !report.rows.isEmpty else {
            return [Block(height: 30) { y in
                text("No time was tracked in this period.", in: CGRect(x: x, y: y + 6, width: width, height: 16), size: 10, color: muted)
            }]
        }
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: report.rows) { calendar.startOfDay(for: $0.start) }
        var blocks = [sectionTitle("Time entries", x: x, width: width, keepWithNext: true), entryHeaderBlock(x: x, width: width)]
        let widths = entryColumns.map { $0.1 * width }

        for day in byDay.keys.sorted() {
            let rows = byDay[day] ?? []
            let total = rows.reduce(0) { $0 + $1.hours }
            var dayBlock = Block(height: 24) { y in
                band.setFill()
                NSBezierPath(rect: CGRect(x: x, y: y + 2, width: width, height: 20)).fill()
                text(Fmt.day(day), in: CGRect(x: x + 6, y: y + 6, width: width * 0.7, height: 14), size: 9.5, weight: .semibold)
                text(Fmt.decimal(total), in: CGRect(x: x, y: y + 6, width: width - 6, height: 14), size: 9.5, weight: .semibold, align: .right)
            }
            dayBlock.isEntryRow = true
            dayBlock.keepWithNext = true
            blocks.append(dayBlock)

            for row in rows {
                let timeText = "\(Fmt.time(row.start)) to \(row.end.map(Fmt.time) ?? "now")"
                let clientText = row.projectName.isEmpty ? row.clientName : "\(row.clientName)\n\(row.projectName)"
                let activityText = row.activityName + (row.isBillable ? "" : "\nNon-billable")
                let cells = [timeText, clientText, activityText, row.notes, Fmt.decimal(row.hours)]
                let contentHeight = zip(cells, widths).map { measure($0, width: $1 - 6, size: 9) }.max() ?? 12
                var block = Block(height: max(22, contentHeight + 10)) { y in
                    var cx = x
                    for (index, cell) in cells.enumerated() {
                        let rect = CGRect(x: cx + (index == 0 ? 6 : 0), y: y + 5, width: widths[index] - 6, height: contentHeight + 2)
                        text(cell, in: rect, size: 9, weight: index == 4 ? .medium : .regular,
                             color: index == 2 || index == 0 ? muted : ink, align: entryColumns[index].2, wraps: true)
                        cx += widths[index]
                    }
                    hairline(x: x, y: y + max(22, contentHeight + 10) - 0.5, width: width)
                }
                block.isEntryRow = true
                blocks.append(block)
            }
        }
        return blocks
    }

    // MARK: - Drawing helpers

    private static func sectionTitle(_ title: String, x: CGFloat, width: CGFloat, keepWithNext: Bool) -> Block {
        Block(height: 34, keepWithNext: keepWithNext) { y in
            text(title, in: CGRect(x: x, y: y + 12, width: width, height: 18), size: 12.5, weight: .semibold)
        }
    }

    private static func tableHeader(_ columns: [(String, CGFloat, NSTextAlignment)], x: CGFloat, width: CGFloat) -> Block {
        Block(height: 22, keepWithNext: true) { y in
            var cx = x
            for (index, column) in columns.enumerated() {
                let inset: CGFloat = index == 0 ? 6 : 0
                text(column.0.uppercased(), in: CGRect(x: cx + inset, y: y + 5, width: column.1 - inset - 4, height: 12),
                     size: 7.5, weight: .semibold, color: muted, align: column.2)
                cx += column.1
            }
            hairline(x: x, y: y + 21.5, width: width, color: muted)
        }
    }

    private static func hairline(x: CGFloat, y: CGFloat, width: CGFloat, color: NSColor = rule) {
        color.setFill()
        NSBezierPath(rect: CGRect(x: x, y: y, width: width, height: 0.5)).fill()
    }

    private static func attributes(size: CGFloat, weight: NSFont.Weight, color: NSColor, align: NSTextAlignment, wraps: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static func text(_ string: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular,
                             color: NSColor = ink, align: NSTextAlignment = .left, wraps: Bool = false) {
        NSAttributedString(string: string, attributes: attributes(size: size, weight: weight, color: color, align: align, wraps: wraps))
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func measure(_ string: String, width: CGFloat, size: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let bounds = NSAttributedString(string: string, attributes: attributes(size: size, weight: .regular, color: ink, align: .left, wraps: true))
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return ceil(bounds.height)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        guard cleaned.count == 6 else {
            self.init(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
            return
        }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
