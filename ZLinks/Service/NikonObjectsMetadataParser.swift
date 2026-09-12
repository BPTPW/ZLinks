//
//  NikonObjectsMetadataParser.swift
//  ZLinks
//

import Foundation

struct NikonObjectMetadata: Equatable, Sendable {
    let handle: UInt32
    let attribute: UInt32
    let unknown: UInt8
    let captureDate: Date?
}

struct NikonObjectsMetadata: Equatable, Sendable {
    let header: UInt32
    let records: [NikonObjectMetadata]
}

enum NikonObjectsMetadataParserError: Error, Equatable {
    case truncatedHeader(actualBytes: Int)
    case invalidPayloadLength(expected: Int, actual: Int)
    case recordCountOverflow(UInt32)
}

enum NikonObjectsMetadataParser {
    nonisolated static let headerSize = 8
    nonisolated static let recordSize = 16

    nonisolated static func parse(
        _ data: Data,
        timeZone: TimeZone = .current
    ) throws -> NikonObjectsMetadata {
        guard data.count >= headerSize else {
            throw NikonObjectsMetadataParserError.truncatedHeader(actualBytes: data.count)
        }

        let header = data.littleEndianUInt32(at: 0)
        let rawCount = data.littleEndianUInt32(at: 4)
        guard let count = Int(exactly: rawCount) else {
            throw NikonObjectsMetadataParserError.recordCountOverflow(rawCount)
        }
        let (recordsBytes, multipliedOverflow) = count.multipliedReportingOverflow(by: recordSize)
        let (expectedBytes, addedOverflow) = headerSize.addingReportingOverflow(recordsBytes)
        guard !multipliedOverflow, !addedOverflow else {
            throw NikonObjectsMetadataParserError.recordCountOverflow(rawCount)
        }
        guard expectedBytes == data.count else {
            throw NikonObjectsMetadataParserError.invalidPayloadLength(
                expected: expectedBytes,
                actual: data.count
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var indexedRecords: [(index: Int, record: NikonObjectMetadata)] = []
        indexedRecords.reserveCapacity(count)

        for index in 0..<count {
            let offset = headerSize + index * recordSize
            let second = Int(data[offset + 9])
            let minute = Int(data[offset + 10])
            let hour = Int(data[offset + 11])
            let day = Int(data[offset + 12])
            let month = Int(data[offset + 13])
            let year = Int(data.littleEndianUInt16(at: offset + 14))
            let captureDate = makeDate(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second,
                calendar: calendar
            )

            indexedRecords.append((
                index,
                NikonObjectMetadata(
                    handle: data.littleEndianUInt32(at: offset),
                    attribute: data.littleEndianUInt32(at: offset + 4),
                    unknown: data[offset + 8],
                    captureDate: captureDate
                )
            ))
        }

        return NikonObjectsMetadata(
            header: header,
            records: sortedRecords(indexedRecords.map(\.record))
        )
    }

    nonisolated static func sortedRecords(
        _ records: [NikonObjectMetadata]
    ) -> [NikonObjectMetadata] {
        let indexedRecords = records.enumerated().map { (index: $0.offset, record: $0.element) }
        return indexedRecords.sorted { lhs, rhs in
            switch (lhs.record.captureDate, rhs.record.captureDate) {
            case (let left?, let right?):
                if left != right { return left > right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if lhs.record.handle != rhs.record.handle {
                return lhs.record.handle > rhs.record.handle
            }
            return lhs.index < rhs.index
        }.map(\.record)
    }

    nonisolated private static func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        calendar: Calendar
    ) -> Date? {
        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second),
              (1...9999).contains(year)
        else {
            return nil
        }

        let components = DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == second
        else {
            return nil
        }
        return date
    }
}

private extension Data {
    nonisolated func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    nonisolated func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
