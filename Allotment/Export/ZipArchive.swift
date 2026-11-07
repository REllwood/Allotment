import Foundation

/// Writes an uncompressed ZIP archive, which is all an .xlsx file needs.
struct ZipArchive {
    private struct Entry {
        let name: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var entries: [Entry] = []
    private var body = Data()
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = .now) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        dosDate = UInt16((((c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    mutating func add(_ name: String, _ data: Data) {
        let crc = CRC32.checksum(data)
        let nameBytes = Data(name.utf8)
        let offset = UInt32(body.count)
        body.appendUInt32(0x0403_4B50)
        body.appendUInt16(20)
        body.appendUInt16(0x0800)
        body.appendUInt16(0)
        body.appendUInt16(dosTime)
        body.appendUInt16(dosDate)
        body.appendUInt32(crc)
        body.appendUInt32(UInt32(data.count))
        body.appendUInt32(UInt32(data.count))
        body.appendUInt16(UInt16(nameBytes.count))
        body.appendUInt16(0)
        body.append(nameBytes)
        body.append(data)
        entries.append(Entry(name: name, data: data, crc: crc, offset: offset))
    }

    mutating func add(_ name: String, _ text: String) {
        add(name, Data(text.utf8))
    }

    func finish() -> Data {
        var archive = body
        var directory = Data()
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            directory.appendUInt32(0x0201_4B50)
            directory.appendUInt16(20)
            directory.appendUInt16(20)
            directory.appendUInt16(0x0800)
            directory.appendUInt16(0)
            directory.appendUInt16(dosTime)
            directory.appendUInt16(dosDate)
            directory.appendUInt32(entry.crc)
            directory.appendUInt32(UInt32(entry.data.count))
            directory.appendUInt32(UInt32(entry.data.count))
            directory.appendUInt16(UInt16(nameBytes.count))
            directory.appendUInt16(0)
            directory.appendUInt16(0)
            directory.appendUInt16(0)
            directory.appendUInt16(0)
            directory.appendUInt32(0)
            directory.appendUInt32(entry.offset)
            directory.append(nameBytes)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.appendUInt32(0x0605_4B50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt32(UInt32(directory.count))
        archive.appendUInt32(directoryOffset)
        archive.appendUInt16(0)
        return archive
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(value & 0xFFFF))
        appendUInt16(UInt16(value >> 16))
    }
}
