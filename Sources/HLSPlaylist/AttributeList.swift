import Foundation

/// A single attribute value from an HLS attribute list.
///
/// HLS distinguishes quoted strings from unquoted values (integers, floats,
/// hexadecimal sequences, resolutions and enumerated strings). The
/// distinction is preserved so playlists re-serialize faithfully.
public enum AttributeValue: Sendable, Hashable, CustomStringConvertible {
    case quoted(String)
    case unquoted(String)

    /// The raw text without quotes.
    public var rawValue: String {
        switch self {
        case .quoted(let value), .unquoted(let value): value
        }
    }

    public var description: String {
        switch self {
        case .quoted(let value): "\"\(value)\""
        case .unquoted(let value): value
        }
    }

    public var integer: Int? { Int(rawValue) }
    public var double: Double? { Double(rawValue) }

    /// A `0x`-prefixed hexadecimal sequence as bytes.
    public var hexBytes: [UInt8]? {
        var text = rawValue
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return nil }
        text.removeFirst(2)
        if text.count % 2 == 1 { text = "0" + text }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// A `WIDTHxHEIGHT` resolution.
    public var resolution: Resolution? { Resolution(rawValue) }
}

/// An ordered list of `KEY=VALUE` attributes.
public struct AttributeList: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var entries: [(key: String, value: AttributeValue)]

    public init() { entries = [] }

    public init(_ entries: [(String, AttributeValue)]) {
        self.entries = entries.map { (key: $0.0, value: $0.1) }
    }

    public init(dictionaryLiteral elements: (String, AttributeValue)...) {
        self.init(elements)
    }

    public subscript(key: String) -> AttributeValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key: key, value: newValue))
            }
        }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var keys: [String] { entries.map(\.key) }

    public func makeIterator() -> IndexingIterator<[(key: String, value: AttributeValue)]> {
        entries.makeIterator()
    }

    /// Removes and returns the attributes whose keys are not in `known`.
    func excluding(_ known: Set<String>) -> AttributeList {
        var copy = self
        copy.entries.removeAll { known.contains($0.key) }
        return copy
    }

    mutating func merge(_ other: AttributeList) {
        for (key, value) in other where self[key] == nil {
            entries.append((key: key, value: value))
        }
    }

    public static func == (lhs: AttributeList, rhs: AttributeList) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for (key, value) in entries {
            hasher.combine(key)
            hasher.combine(value)
        }
    }

    // MARK: Parsing & serialization

    /// Parses an attribute list such as `BANDWIDTH=1280000,CODECS="avc1.4d401f,mp4a.40.2"`.
    ///
    /// Parsing is lenient: whitespace around separators is tolerated, and an
    /// unterminated quoted string runs to the end of the line.
    public static func parse(_ text: Substring) -> AttributeList {
        var list = AttributeList()
        var index = text.startIndex

        func skipWhitespace() {
            while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
        }

        while index < text.endIndex {
            skipWhitespace()
            let keyStart = index
            while index < text.endIndex, text[index] != "=", text[index] != "," { index = text.index(after: index) }
            let key = text[keyStart..<index].trimmingCharacters(in: .whitespaces)
            guard index < text.endIndex, text[index] == "=" else {
                // Malformed entry without a value; skip it.
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            index = text.index(after: index)
            skipWhitespace()
            let value: AttributeValue
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                let valueStart = index
                while index < text.endIndex, text[index] != "\"" { index = text.index(after: index) }
                value = .quoted(String(text[valueStart..<index]))
                if index < text.endIndex { index = text.index(after: index) }
                while index < text.endIndex, text[index] != "," { index = text.index(after: index) }
            } else {
                let valueStart = index
                while index < text.endIndex, text[index] != "," { index = text.index(after: index) }
                value = .unquoted(text[valueStart..<index].trimmingCharacters(in: .whitespaces))
            }
            if index < text.endIndex { index = text.index(after: index) }
            if !key.isEmpty { list.entries.append((key: key, value: value)) }
        }
        return list
    }

    public var serialized: String {
        entries.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
}

// MARK: - Builders used by the typed models

extension AttributeList {
    mutating func set(_ key: String, quoted value: String?) {
        if let value { self[key] = .quoted(value) }
    }

    mutating func set(_ key: String, unquoted value: String?) {
        if let value { self[key] = .unquoted(value) }
    }

    mutating func set(_ key: String, int value: Int?) {
        if let value { self[key] = .unquoted(String(value)) }
    }

    mutating func set(_ key: String, double value: Double?) {
        if let value { self[key] = .unquoted(formatDecimal(value)) }
    }

    mutating func set(_ key: String, bool value: Bool?) {
        if let value { self[key] = .unquoted(value ? "YES" : "NO") }
    }

    func bool(_ key: String) -> Bool? {
        guard let raw = self[key]?.rawValue else { return nil }
        return raw.uppercased() == "YES"
    }
}

/// Formats a decimal without exponent notation or a trailing `.0` noise
/// beyond what is needed (up to millisecond precision is preserved).
func formatDecimal(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e15 {
        return String(Int64(value))
    }
    var text = String(format: "%.6f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

/// A video resolution, `WIDTHxHEIGHT`.
public struct Resolution: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        self.init(width: width, height: height)
    }

    public var pixelCount: Int { width * height }
    public var description: String { "\(width)x\(height)" }

    public static func < (lhs: Resolution, rhs: Resolution) -> Bool { lhs.pixelCount < rhs.pixelCount }
}
