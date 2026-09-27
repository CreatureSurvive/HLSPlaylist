import Foundation

/// Errors thrown while parsing a playlist.
public enum PlaylistError: Error, Sendable, Equatable, LocalizedError {
    /// The text does not start with `#EXTM3U`.
    case missingHeader
    /// The playlist contains both multivariant and media tags.
    case ambiguousPlaylistType
    /// A `{$name}` reference has no definition (strict mode only).
    case undefinedVariable(name: String, line: Int)
    /// A tag is malformed (strict mode only).
    case invalidTag(String, line: Int)
    /// The data is not valid UTF-8.
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .missingHeader: "The playlist does not begin with #EXTM3U."
        case .ambiguousPlaylistType: "The playlist mixes multivariant and media playlist tags."
        case .undefinedVariable(let name, let line): "Undefined variable \"\(name)\" on line \(line)."
        case .invalidTag(let tag, let line): "Invalid tag \"\(tag)\" on line \(line)."
        case .invalidEncoding: "The playlist is not valid UTF-8."
        }
    }
}

/// A non-fatal problem encountered while parsing leniently.
public struct ParseWarning: Sendable, Hashable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

/// Configures playlist parsing.
public struct ParseOptions: Sendable {
    /// Throw on malformed tags and undefined variables instead of warning.
    public var strict = false
    /// Resolve `{$name}` references using `EXT-X-DEFINE`.
    public var substitutesVariables = true
    /// Values available to `EXT-X-DEFINE:IMPORT` (from the multivariant playlist).
    public var importedVariables: [String: String] = [:]
    /// The playlist's URL, used for `EXT-X-DEFINE:QUERYPARAM`.
    public var playlistURL: URL?

    public init(strict: Bool = false, substitutesVariables: Bool = true, importedVariables: [String: String] = [:], playlistURL: URL? = nil) {
        self.strict = strict
        self.substitutesVariables = substitutesVariables
        self.importedVariables = importedVariables
        self.playlistURL = playlistURL
    }
}

/// The result of parsing: the playlist plus any warnings.
public struct ParseResult: Sendable {
    public var playlist: Playlist
    public var warnings: [ParseWarning]
    /// Variables defined by the playlist (for passing to child playlists).
    public var variables: [String: String]
}

extension Playlist {
    /// Parses playlist text.
    public init(_ text: String, options: ParseOptions = ParseOptions()) throws {
        self = try PlaylistParser(options: options).parse(text).playlist
    }

    /// Parses UTF-8 playlist data.
    public init(data: Data, options: ParseOptions = ParseOptions()) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw PlaylistError.invalidEncoding }
        try self.init(text, options: options)
    }
}

/// Parses HLS playlists (RFC 8216 and draft-pantos-hls-rfc8216bis).
public struct PlaylistParser: Sendable {
    public var options: ParseOptions

    public init(options: ParseOptions = ParseOptions()) {
        self.options = options
    }

    public func parse(_ data: Data) throws -> ParseResult {
        guard let text = String(data: data, encoding: .utf8) else { throw PlaylistError.invalidEncoding }
        return try parse(text)
    }

    public func parse(_ text: String) throws -> ParseResult {
        var state = ParserState(options: options)
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).makeIterator()
        var lineNumber = 0

        // Header (tolerate a BOM and leading blank lines).
        var sawHeader = false
        while let raw = lines.next() {
            lineNumber += 1
            var line = Substring(raw)
            if line.first == "\u{FEFF}" { line = line.dropFirst() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed == "#EXTM3U" || trimmed.hasPrefix("#EXTM3U ") else { throw PlaylistError.missingHeader }
            sawHeader = true
            break
        }
        guard sawHeader else { throw PlaylistError.missingHeader }

        while let raw = lines.next() {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            try state.consume(line, lineNumber: lineNumber)
        }
        return try state.finish()
    }
}

// MARK: - Parser state machine

private struct ParserState {
    let options: ParseOptions
    var warnings: [ParseWarning] = []
    var variables: [String: String] = [:]
    var definitions: [VariableDefinition] = []

    // Common header
    var version: Int?
    var independentSegments = false
    var start: StartPoint?
    var headerUnknown: [String] = []

    // Multivariant
    var isMultivariant = false
    var variants: [Variant] = []
    var iFrameVariants: [Variant] = []
    var renditions: [Rendition] = []
    var sessionData: [SessionData] = []
    var sessionKeys: [EncryptionKey] = []
    var contentSteering: AttributeList?
    var pendingStreamInf: AttributeList?

    // Media
    var isMedia = false
    var media = MediaPlaylist(targetDuration: 0)
    var pendingInf: (duration: Double, title: String?)?
    var pendingByteRange: ByteRange?
    var pendingDiscontinuity = false
    var pendingProgramDateTime: Date?
    var pendingDateRanges: [DateRange] = []
    var pendingGap = false
    var pendingParts: [PartialSegment] = []
    var pendingUnknown: [String] = []
    var currentKeys: [EncryptionKey] = []
    var currentMap: MediaInitializationSection?
    var currentBitrate: Int?

    init(options: ParseOptions) {
        self.options = options
    }

    mutating func warn(_ message: String, _ line: Int) throws {
        if options.strict { throw PlaylistError.invalidTag(message, line: line) }
        warnings.append(ParseWarning(line: line, message: message))
    }

    mutating func consume(_ rawLine: String, lineNumber: Int) throws {
        if rawLine.hasPrefix("#EXT-X-DEFINE:") {
            try define(AttributeList.parse(rawLine.dropFirst("#EXT-X-DEFINE:".count)), lineNumber)
            return
        }
        let line = try substitute(rawLine, lineNumber)

        guard line.hasPrefix("#") else {
            try uri(line, lineNumber)
            return
        }
        guard line.hasPrefix("#EXT") else { return } // comment

        let name: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
        } else {
            name = Substring(line)
            value = ""
        }
        let attributes = { AttributeList.parse(value) }

        switch name {
        // Basic / shared
        case "#EXT-X-VERSION": version = Int(value)
        case "#EXT-X-INDEPENDENT-SEGMENTS": independentSegments = true
        case "#EXT-X-START":
            start = StartPoint(attributes: attributes())
            if start == nil { try warn("EXT-X-START without TIME-OFFSET", lineNumber) }

        // Multivariant
        case "#EXT-X-STREAM-INF":
            isMultivariant = true
            if pendingStreamInf != nil { try warn("EXT-X-STREAM-INF without URI", lineNumber) }
            pendingStreamInf = attributes()
        case "#EXT-X-I-FRAME-STREAM-INF":
            isMultivariant = true
            let a = attributes()
            iFrameVariants.append(Variant(uri: a["URI"]?.rawValue ?? "", attributes: a))
        case "#EXT-X-MEDIA":
            isMultivariant = true
            renditions.append(Rendition(attributes: attributes()))
        case "#EXT-X-SESSION-DATA":
            isMultivariant = true
            sessionData.append(SessionData(attributes: attributes()))
        case "#EXT-X-SESSION-KEY":
            isMultivariant = true
            sessionKeys.append(EncryptionKey(attributes: attributes()))
        case "#EXT-X-CONTENT-STEERING":
            isMultivariant = true
            contentSteering = attributes()

        // Media
        case "#EXTINF":
            isMedia = true
            let parts = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard let duration = parts.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else {
                try warn("Invalid EXTINF duration", lineNumber)
                pendingInf = (0, nil)
                return
            }
            let title = parts.count > 1 ? String(parts[1]) : nil
            pendingInf = (duration, title?.isEmpty == true ? nil : title)
        case "#EXT-X-TARGETDURATION":
            isMedia = true
            if let target = Int(value) ?? Double(value).map({ Int($0.rounded(.up)) }) {
                media.targetDuration = target
            } else {
                try warn("Invalid EXT-X-TARGETDURATION", lineNumber)
            }
        case "#EXT-X-MEDIA-SEQUENCE":
            isMedia = true
            media.mediaSequence = Int(value) ?? 0
        case "#EXT-X-DISCONTINUITY-SEQUENCE":
            isMedia = true
            media.discontinuitySequence = Int(value) ?? 0
        case "#EXT-X-PLAYLIST-TYPE":
            isMedia = true
            media.playlistType = MediaPlaylist.PlaylistType(rawValue: String(value))
        case "#EXT-X-I-FRAMES-ONLY":
            isMedia = true
            media.iFramesOnly = true
        case "#EXT-X-ENDLIST":
            isMedia = true
            media.hasEndList = true
        case "#EXT-X-BYTERANGE":
            isMedia = true
            pendingByteRange = ByteRange(String(value))
            if pendingByteRange == nil { try warn("Invalid EXT-X-BYTERANGE", lineNumber) }
        case "#EXT-X-DISCONTINUITY":
            isMedia = true
            pendingDiscontinuity = true
        case "#EXT-X-KEY":
            isMedia = true
            let key = EncryptionKey(attributes: attributes())
            if key.method == .none {
                currentKeys = []
            } else {
                currentKeys.removeAll { ($0.keyFormat ?? "identity") == (key.keyFormat ?? "identity") }
                currentKeys.append(key)
            }
        case "#EXT-X-MAP":
            isMedia = true
            currentMap = MediaInitializationSection(attributes: attributes())
        case "#EXT-X-PROGRAM-DATE-TIME":
            isMedia = true
            pendingProgramDateTime = HLSDate.parse(String(value))
            if pendingProgramDateTime == nil { try warn("Invalid EXT-X-PROGRAM-DATE-TIME", lineNumber) }
        case "#EXT-X-DATERANGE":
            pendingDateRanges.append(DateRange(attributes: attributes()))
        case "#EXT-X-GAP":
            isMedia = true
            pendingGap = true
        case "#EXT-X-BITRATE":
            isMedia = true
            currentBitrate = Int(value)
        case "#EXT-X-PART":
            isMedia = true
            pendingParts.append(PartialSegment(attributes: attributes()))
        case "#EXT-X-PART-INF":
            isMedia = true
            media.partTarget = attributes()["PART-TARGET"]?.double
        case "#EXT-X-SERVER-CONTROL":
            isMedia = true
            media.serverControl = ServerControl(attributes: attributes())
        case "#EXT-X-SKIP":
            isMedia = true
            let a = attributes()
            media.skippedSegments = a["SKIPPED-SEGMENTS"]?.integer
            media.recentlyRemovedDateRanges = a["RECENTLY-REMOVED-DATERANGES"]?.rawValue
        case "#EXT-X-PRELOAD-HINT":
            isMedia = true
            media.preloadHints.append(PreloadHint(attributes: attributes()))
        case "#EXT-X-RENDITION-REPORT":
            isMedia = true
            media.renditionReports.append(RenditionReport(attributes: attributes()))
        default:
            if isMedia, !media.segments.isEmpty || pendingInf != nil || !pendingParts.isEmpty {
                pendingUnknown.append(line)
            } else if pendingStreamInf != nil || !variants.isEmpty {
                pendingUnknown.append(line)
            } else {
                headerUnknown.append(line)
            }
        }
    }

    mutating func uri(_ line: String, _ lineNumber: Int) throws {
        if let streamInf = pendingStreamInf {
            var variant = Variant(uri: line, attributes: streamInf)
            variant.unknownTags = pendingUnknown
            pendingUnknown = []
            variants.append(variant)
            pendingStreamInf = nil
            return
        }
        guard let inf = pendingInf else {
            try warn("URI without EXTINF or EXT-X-STREAM-INF: \(line)", lineNumber)
            return
        }
        var segment = Segment(
            uri: line,
            duration: inf.duration,
            title: inf.title,
            byteRange: pendingByteRange,
            discontinuity: pendingDiscontinuity,
            keys: currentKeys,
            map: currentMap,
            programDateTime: pendingProgramDateTime
        )
        segment.dateRanges = pendingDateRanges
        segment.gap = pendingGap
        segment.bitrate = currentBitrate
        segment.parts = pendingParts
        segment.unknownTags = pendingUnknown
        media.segments.append(segment)

        pendingInf = nil
        pendingByteRange = nil
        pendingDiscontinuity = false
        pendingProgramDateTime = nil
        pendingDateRanges = []
        pendingGap = false
        pendingParts = []
        pendingUnknown = []
    }

    mutating func define(_ attributes: AttributeList, _ lineNumber: Int) throws {
        guard let definition = VariableDefinition(attributes: attributes) else {
            try warn("EXT-X-DEFINE without NAME, IMPORT or QUERYPARAM", lineNumber)
            return
        }
        definitions.append(definition)
        switch definition {
        case .value(let name, let value):
            variables[name] = value
        case .import(let name):
            if let value = options.importedVariables[name] {
                variables[name] = value
            } else {
                try warn("Imported variable \"\(name)\" is not available", lineNumber)
            }
        case .queryParameter(let name):
            let items = options.playlistURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            if let value = items?.first(where: { $0.name == name })?.value {
                variables[name] = value
            } else {
                try warn("Query parameter \"\(name)\" is not available", lineNumber)
            }
        }
    }

    mutating func substitute(_ line: String, _ lineNumber: Int) throws -> String {
        guard options.substitutesVariables, line.contains("{$") else { return line }
        var output = ""
        var rest = Substring(line)
        while let open = rest.range(of: "{$") {
            output += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                output += rest[open.lowerBound...]
                return output
            }
            let name = String(rest[open.upperBound..<close])
            if let value = variables[name] {
                output += value
            } else {
                if options.strict { throw PlaylistError.undefinedVariable(name: name, line: lineNumber) }
                warnings.append(ParseWarning(line: lineNumber, message: "Undefined variable \"\(name)\""))
                output += rest[open.lowerBound...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return output + rest
    }

    mutating func finish() throws -> ParseResult {
        if isMultivariant && isMedia { throw PlaylistError.ambiguousPlaylistType }
        if pendingStreamInf != nil { try warn("Trailing EXT-X-STREAM-INF without URI", 0) }

        if isMultivariant {
            var playlist = MultivariantPlaylist(version: version, independentSegments: independentSegments, variants: variants, renditions: renditions)
            playlist.start = start
            playlist.definitions = definitions
            playlist.iFrameVariants = iFrameVariants
            playlist.sessionData = sessionData
            playlist.sessionKeys = sessionKeys
            playlist.contentSteering = contentSteering
            playlist.unknownTags = headerUnknown + pendingUnknown
            return ParseResult(playlist: .multivariant(playlist), warnings: warnings, variables: variables)
        }

        if pendingInf != nil { try warn("Trailing EXTINF without URI", 0) }
        media.version = version
        media.independentSegments = independentSegments
        media.start = start
        media.definitions = definitions
        media.unknownTags = headerUnknown
        media.trailingParts = pendingParts
        media.trailingDateRanges = pendingDateRanges
        media.trailingUnknownTags = pendingUnknown
        return ParseResult(playlist: .media(media), warnings: warnings, variables: variables)
    }
}
