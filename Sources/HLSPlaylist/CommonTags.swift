import Foundation

/// A byte range, `length[@offset]`.
public struct ByteRange: Sendable, Hashable, CustomStringConvertible {
    public var length: Int
    /// Start offset; `nil` means "immediately after the previous range".
    public var offset: Int?

    public init(length: Int, offset: Int? = nil) {
        self.length = length
        self.offset = offset
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "@", maxSplits: 1)
        guard let first = parts.first, let length = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        self.length = length
        if parts.count == 2 {
            guard let offset = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            self.offset = offset
        }
    }

    public var description: String { offset.map { "\(length)@\($0)" } ?? "\(length)" }
}

/// `EXT-X-KEY` / `EXT-X-SESSION-KEY`: how media segments are encrypted.
public struct EncryptionKey: Sendable, Hashable {
    public enum Method: Sendable, Hashable, CustomStringConvertible {
        case none, aes128, sampleAES, sampleAESCTR
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "NONE": self = .none
            case "AES-128": self = .aes128
            case "SAMPLE-AES": self = .sampleAES
            case "SAMPLE-AES-CTR": self = .sampleAESCTR
            default: self = .other(raw)
            }
        }

        public var description: String {
            switch self {
            case .none: "NONE"
            case .aes128: "AES-128"
            case .sampleAES: "SAMPLE-AES"
            case .sampleAESCTR: "SAMPLE-AES-CTR"
            case .other(let raw): raw
            }
        }
    }

    public var method: Method
    public var uri: String?
    /// 128-bit initialization vector.
    public var iv: [UInt8]?
    public var keyFormat: String?
    public var keyFormatVersions: String?
    /// Attributes not modeled above, preserved verbatim.
    public var otherAttributes: AttributeList

    public init(method: Method, uri: String? = nil, iv: [UInt8]? = nil, keyFormat: String? = nil, keyFormatVersions: String? = nil, otherAttributes: AttributeList = AttributeList()) {
        self.method = method
        self.uri = uri
        self.iv = iv
        self.keyFormat = keyFormat
        self.keyFormatVersions = keyFormatVersions
        self.otherAttributes = otherAttributes
    }

    static let known: Set<String> = ["METHOD", "URI", "IV", "KEYFORMAT", "KEYFORMATVERSIONS"]

    init(attributes a: AttributeList) {
        method = Method(a["METHOD"]?.rawValue ?? "NONE")
        uri = a["URI"]?.rawValue
        iv = a["IV"]?.hexBytes
        keyFormat = a["KEYFORMAT"]?.rawValue
        keyFormatVersions = a["KEYFORMATVERSIONS"]?.rawValue
        otherAttributes = a.excluding(Self.known)
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("METHOD", unquoted: method.description)
        a.set("URI", quoted: uri)
        a.set("IV", unquoted: iv.map { "0x" + $0.map { String(format: "%02X", $0) }.joined() })
        a.set("KEYFORMAT", quoted: keyFormat)
        a.set("KEYFORMATVERSIONS", quoted: keyFormatVersions)
        a.merge(otherAttributes)
        return a
    }

    /// The IV to use for a segment: the explicit IV, or (per RFC 8216) the
    /// segment's media sequence number as a big-endian 128-bit integer.
    public func initializationVector(forMediaSequence sequence: Int) -> [UInt8] {
        if let iv { return iv }
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(truncatingIfNeeded: sequence)
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        return bytes
    }
}

/// `EXT-X-MAP`: the media initialization section (e.g. an fMP4 `init.mp4`).
public struct MediaInitializationSection: Sendable, Hashable {
    public var uri: String
    public var byteRange: ByteRange?
    public var otherAttributes: AttributeList

    public init(uri: String, byteRange: ByteRange? = nil, otherAttributes: AttributeList = AttributeList()) {
        self.uri = uri
        self.byteRange = byteRange
        self.otherAttributes = otherAttributes
    }

    init(attributes a: AttributeList) {
        uri = a["URI"]?.rawValue ?? ""
        byteRange = a["BYTERANGE"].flatMap { ByteRange($0.rawValue) }
        otherAttributes = a.excluding(["URI", "BYTERANGE"])
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("URI", quoted: uri)
        a.set("BYTERANGE", quoted: byteRange?.description)
        a.merge(otherAttributes)
        return a
    }
}

/// `EXT-X-START`: the preferred point at which to start playback.
public struct StartPoint: Sendable, Hashable {
    /// Seconds from the start (positive) or end (negative) of the playlist.
    public var timeOffset: Double
    public var precise: Bool

    public init(timeOffset: Double, precise: Bool = false) {
        self.timeOffset = timeOffset
        self.precise = precise
    }

    init?(attributes a: AttributeList) {
        guard let offset = a["TIME-OFFSET"]?.double else { return nil }
        timeOffset = offset
        precise = a.bool("PRECISE") ?? false
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("TIME-OFFSET", double: timeOffset)
        if precise { a.set("PRECISE", bool: true) }
        return a
    }
}

/// `EXT-X-DEFINE`: a variable definition.
public enum VariableDefinition: Sendable, Hashable {
    /// `NAME="x",VALUE="y"`
    case value(name: String, value: String)
    /// `IMPORT="x"` — imported from the multivariant playlist.
    case `import`(name: String)
    /// `QUERYPARAM="x"` — taken from the playlist URL's query string.
    case queryParameter(name: String)

    init?(attributes a: AttributeList) {
        if let name = a["NAME"]?.rawValue {
            self = .value(name: name, value: a["VALUE"]?.rawValue ?? "")
        } else if let name = a["IMPORT"]?.rawValue {
            self = .import(name: name)
        } else if let name = a["QUERYPARAM"]?.rawValue {
            self = .queryParameter(name: name)
        } else {
            return nil
        }
    }

    var attributes: AttributeList {
        switch self {
        case .value(let name, let value): ["NAME": .quoted(name), "VALUE": .quoted(value)]
        case .import(let name): ["IMPORT": .quoted(name)]
        case .queryParameter(let name): ["QUERYPARAM": .quoted(name)]
        }
    }
}

/// `EXT-X-SESSION-DATA`: arbitrary session metadata.
public struct SessionData: Sendable, Hashable {
    public var dataID: String
    public var value: String?
    public var uri: String?
    public var language: String?
    public var otherAttributes: AttributeList

    public init(dataID: String, value: String? = nil, uri: String? = nil, language: String? = nil, otherAttributes: AttributeList = AttributeList()) {
        self.dataID = dataID
        self.value = value
        self.uri = uri
        self.language = language
        self.otherAttributes = otherAttributes
    }

    init(attributes a: AttributeList) {
        dataID = a["DATA-ID"]?.rawValue ?? ""
        value = a["VALUE"]?.rawValue
        uri = a["URI"]?.rawValue
        language = a["LANGUAGE"]?.rawValue
        otherAttributes = a.excluding(["DATA-ID", "VALUE", "URI", "LANGUAGE"])
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("DATA-ID", quoted: dataID)
        a.set("VALUE", quoted: value)
        a.set("URI", quoted: uri)
        a.set("LANGUAGE", quoted: language)
        a.merge(otherAttributes)
        return a
    }
}

/// `EXT-X-DATERANGE`: metadata about a range of time (ads, program boundaries, …).
public struct DateRange: Sendable, Hashable {
    public var id: String
    public var classIdentifier: String?
    public var startDate: Date?
    public var cue: String?
    public var endDate: Date?
    public var duration: Double?
    public var plannedDuration: Double?
    public var endOnNext: Bool
    /// `SCTE35-CMD`, `SCTE35-OUT`, `SCTE35-IN` as hex strings.
    public var scte35Command: String?
    public var scte35Out: String?
    public var scte35In: String?
    /// `X-` client attributes and any other unmodeled attributes.
    public var otherAttributes: AttributeList

    public init(id: String, startDate: Date?, classIdentifier: String? = nil, duration: Double? = nil, plannedDuration: Double? = nil, endDate: Date? = nil, endOnNext: Bool = false, otherAttributes: AttributeList = AttributeList()) {
        self.id = id
        self.startDate = startDate
        self.classIdentifier = classIdentifier
        self.duration = duration
        self.plannedDuration = plannedDuration
        self.endDate = endDate
        self.endOnNext = endOnNext
        self.otherAttributes = otherAttributes
    }

    static let known: Set<String> = ["ID", "CLASS", "START-DATE", "CUE", "END-DATE", "DURATION", "PLANNED-DURATION", "END-ON-NEXT", "SCTE35-CMD", "SCTE35-OUT", "SCTE35-IN"]

    init(attributes a: AttributeList) {
        id = a["ID"]?.rawValue ?? ""
        classIdentifier = a["CLASS"]?.rawValue
        startDate = a["START-DATE"].flatMap { HLSDate.parse($0.rawValue) }
        cue = a["CUE"]?.rawValue
        endDate = a["END-DATE"].flatMap { HLSDate.parse($0.rawValue) }
        duration = a["DURATION"]?.double
        plannedDuration = a["PLANNED-DURATION"]?.double
        endOnNext = a.bool("END-ON-NEXT") ?? false
        scte35Command = a["SCTE35-CMD"]?.rawValue
        scte35Out = a["SCTE35-OUT"]?.rawValue
        scte35In = a["SCTE35-IN"]?.rawValue
        otherAttributes = a.excluding(Self.known)
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("ID", quoted: id)
        a.set("CLASS", quoted: classIdentifier)
        a.set("START-DATE", quoted: startDate.map(HLSDate.format))
        a.set("CUE", quoted: cue)
        a.set("END-DATE", quoted: endDate.map(HLSDate.format))
        a.set("DURATION", double: duration)
        a.set("PLANNED-DURATION", double: plannedDuration)
        if endOnNext { a.set("END-ON-NEXT", bool: true) }
        a.set("SCTE35-CMD", unquoted: scte35Command)
        a.set("SCTE35-OUT", unquoted: scte35Out)
        a.set("SCTE35-IN", unquoted: scte35In)
        a.merge(otherAttributes)
        return a
    }
}

/// ISO 8601 date handling for `EXT-X-PROGRAM-DATE-TIME` and `EXT-X-DATERANGE`.
enum HLSDate {
    // ISO8601DateFormatter is thread-safe; creating one is expensive.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = fastParse(trimmed) { return date }
        if let date = fractional.date(from: trimmed) ?? plain.date(from: trimmed) { return date }
        // Some encoders emit offsets without a colon (e.g. +0000).
        if let match = trimmed.range(of: #"[+-]\d{4}$"#, options: .regularExpression) {
            var fixed = trimmed
            fixed.insert(":", at: fixed.index(match.lowerBound, offsetBy: 3))
            return fractional.date(from: fixed) ?? plain.date(from: fixed)
        }
        return nil
    }

    /// Allocation-free parser for `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH[:]MM)`,
    /// which is what virtually every packager emits. Returns `nil` for
    /// anything else so the caller can fall back to `ISO8601DateFormatter`.
    static func fastParse(_ text: String) -> Date? {
        var utf8 = text.utf8.makeIterator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        while let byte = utf8.next() {
            bytes.append(byte)
            if bytes.count > 40 { return nil }
        }
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for index in start..<(start + count) {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes.count >= 20,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 116, bytes[13] == 58, bytes[16] == 58,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            var scale = 0.1
            let start = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }
        guard index < bytes.count else { return nil }
        var offsetSeconds = 0
        switch bytes[index] {
        case 90, 122: // Z
            guard index + 1 == bytes.count else { return nil }
        case 43, 45: // + -
            let sign = bytes[index] == 45 ? -1 : 1
            guard let hours = digits(index + 1, 2) else { return nil }
            var minuteStart = index + 3
            if minuteStart < bytes.count, bytes[minuteStart] == 58 { minuteStart += 1 }
            guard let minutes = digits(minuteStart, 2), minuteStart + 2 == bytes.count else { return nil }
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
        default:
            return nil
        }

        // Days from civil (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    static func format(_ date: Date) -> String {
        fractional.string(from: date)
    }
}
