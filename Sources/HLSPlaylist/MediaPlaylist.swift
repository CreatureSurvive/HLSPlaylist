import Foundation

/// `EXT-X-PART`: a partial segment (Low-Latency HLS).
public struct PartialSegment: Sendable, Hashable {
    public var uri: String
    public var duration: Double
    public var independent: Bool
    public var byteRange: ByteRange?
    public var gap: Bool
    public var otherAttributes: AttributeList

    public init(uri: String, duration: Double, independent: Bool = false, byteRange: ByteRange? = nil, gap: Bool = false) {
        self.uri = uri
        self.duration = duration
        self.independent = independent
        self.byteRange = byteRange
        self.gap = gap
        self.otherAttributes = AttributeList()
    }

    init(attributes a: AttributeList) {
        uri = a["URI"]?.rawValue ?? ""
        duration = a["DURATION"]?.double ?? 0
        independent = a.bool("INDEPENDENT") ?? false
        byteRange = a["BYTERANGE"].flatMap { ByteRange($0.rawValue) }
        gap = a.bool("GAP") ?? false
        otherAttributes = a.excluding(["URI", "DURATION", "INDEPENDENT", "BYTERANGE", "GAP"])
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("DURATION", double: duration)
        a.set("URI", quoted: uri)
        if independent { a.set("INDEPENDENT", bool: true) }
        a.set("BYTERANGE", quoted: byteRange?.description)
        if gap { a.set("GAP", bool: true) }
        a.merge(otherAttributes)
        return a
    }
}

/// A media segment and the tags that apply to it.
public struct Segment: Sendable, Hashable {
    public var uri: String
    /// `EXTINF` duration in seconds.
    public var duration: Double
    /// `EXTINF` title (after the comma).
    public var title: String?
    public var byteRange: ByteRange?
    /// `EXT-X-DISCONTINUITY` precedes this segment.
    public var discontinuity: Bool
    /// Keys in effect for this segment (empty when unencrypted).
    public var keys: [EncryptionKey]
    /// Initialization section in effect for this segment.
    public var map: MediaInitializationSection?
    /// Explicit `EXT-X-PROGRAM-DATE-TIME` for this segment.
    public var programDateTime: Date?
    /// `EXT-X-DATERANGE` tags that appeared before this segment.
    public var dateRanges: [DateRange]
    public var gap: Bool
    /// `EXT-X-BITRATE` in effect, in kbps.
    public var bitrate: Int?
    /// Partial segments that make up this segment (LL-HLS).
    public var parts: [PartialSegment]
    /// Unrecognized tags that preceded this segment, preserved verbatim.
    public var unknownTags: [String]

    public init(uri: String, duration: Double, title: String? = nil, byteRange: ByteRange? = nil, discontinuity: Bool = false, keys: [EncryptionKey] = [], map: MediaInitializationSection? = nil, programDateTime: Date? = nil) {
        self.uri = uri
        self.duration = duration
        self.title = title
        self.byteRange = byteRange
        self.discontinuity = discontinuity
        self.keys = keys
        self.map = map
        self.programDateTime = programDateTime
        self.dateRanges = []
        self.gap = false
        self.parts = []
        self.unknownTags = []
    }

    /// Whether any key in effect actually encrypts the segment.
    public var isEncrypted: Bool { keys.contains { $0.method != .none } }
}

/// `EXT-X-SERVER-CONTROL` (LL-HLS and delta updates).
public struct ServerControl: Sendable, Hashable {
    public var canSkipUntil: Double?
    public var canSkipDateRanges: Bool
    public var holdBack: Double?
    public var partHoldBack: Double?
    public var canBlockReload: Bool
    public var otherAttributes: AttributeList

    public init(canSkipUntil: Double? = nil, canSkipDateRanges: Bool = false, holdBack: Double? = nil, partHoldBack: Double? = nil, canBlockReload: Bool = false) {
        self.canSkipUntil = canSkipUntil
        self.canSkipDateRanges = canSkipDateRanges
        self.holdBack = holdBack
        self.partHoldBack = partHoldBack
        self.canBlockReload = canBlockReload
        self.otherAttributes = AttributeList()
    }

    init(attributes a: AttributeList) {
        canSkipUntil = a["CAN-SKIP-UNTIL"]?.double
        canSkipDateRanges = a.bool("CAN-SKIP-DATERANGES") ?? false
        holdBack = a["HOLD-BACK"]?.double
        partHoldBack = a["PART-HOLD-BACK"]?.double
        canBlockReload = a.bool("CAN-BLOCK-RELOAD") ?? false
        otherAttributes = a.excluding(["CAN-SKIP-UNTIL", "CAN-SKIP-DATERANGES", "HOLD-BACK", "PART-HOLD-BACK", "CAN-BLOCK-RELOAD"])
    }

    var attributes: AttributeList {
        var a = AttributeList()
        if canBlockReload { a.set("CAN-BLOCK-RELOAD", bool: true) }
        a.set("CAN-SKIP-UNTIL", double: canSkipUntil)
        if canSkipDateRanges { a.set("CAN-SKIP-DATERANGES", bool: true) }
        a.set("HOLD-BACK", double: holdBack)
        a.set("PART-HOLD-BACK", double: partHoldBack)
        a.merge(otherAttributes)
        return a
    }
}

/// `EXT-X-PRELOAD-HINT`.
public struct PreloadHint: Sendable, Hashable {
    public var type: String
    public var uri: String
    public var byteRangeStart: Int?
    public var byteRangeLength: Int?

    public init(type: String, uri: String, byteRangeStart: Int? = nil, byteRangeLength: Int? = nil) {
        self.type = type
        self.uri = uri
        self.byteRangeStart = byteRangeStart
        self.byteRangeLength = byteRangeLength
    }

    init(attributes a: AttributeList) {
        type = a["TYPE"]?.rawValue ?? ""
        uri = a["URI"]?.rawValue ?? ""
        byteRangeStart = a["BYTERANGE-START"]?.integer
        byteRangeLength = a["BYTERANGE-LENGTH"]?.integer
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("TYPE", unquoted: type)
        a.set("URI", quoted: uri)
        a.set("BYTERANGE-START", int: byteRangeStart)
        a.set("BYTERANGE-LENGTH", int: byteRangeLength)
        return a
    }
}

/// `EXT-X-RENDITION-REPORT`.
public struct RenditionReport: Sendable, Hashable {
    public var uri: String
    public var lastMediaSequence: Int?
    public var lastPart: Int?

    public init(uri: String, lastMediaSequence: Int? = nil, lastPart: Int? = nil) {
        self.uri = uri
        self.lastMediaSequence = lastMediaSequence
        self.lastPart = lastPart
    }

    init(attributes a: AttributeList) {
        uri = a["URI"]?.rawValue ?? ""
        lastMediaSequence = a["LAST-MSN"]?.integer
        lastPart = a["LAST-PART"]?.integer
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("URI", quoted: uri)
        a.set("LAST-MSN", int: lastMediaSequence)
        a.set("LAST-PART", int: lastPart)
        return a
    }
}

/// A media playlist: a list of segments.
public struct MediaPlaylist: Sendable, Hashable {
    public enum PlaylistType: String, Sendable, Hashable {
        case event = "EVENT"
        case vod = "VOD"
    }

    public var version: Int?
    public var targetDuration: Int
    public var mediaSequence: Int
    public var discontinuitySequence: Int
    public var playlistType: PlaylistType?
    public var iFramesOnly: Bool
    public var independentSegments: Bool
    public var start: StartPoint?
    public var definitions: [VariableDefinition]
    public var segments: [Segment]
    /// `EXT-X-ENDLIST` is present: no more segments will be added.
    public var hasEndList: Bool
    public var serverControl: ServerControl?
    /// `EXT-X-PART-INF:PART-TARGET`.
    public var partTarget: Double?
    /// `EXT-X-SKIP:SKIPPED-SEGMENTS` in a delta update.
    public var skippedSegments: Int?
    public var recentlyRemovedDateRanges: String?
    /// Partial segments after the last complete segment (LL-HLS live edge).
    public var trailingParts: [PartialSegment]
    public var preloadHints: [PreloadHint]
    public var renditionReports: [RenditionReport]
    /// Date ranges after the last segment.
    public var trailingDateRanges: [DateRange]
    /// Unrecognized header tags, preserved verbatim.
    public var unknownTags: [String]
    /// Unrecognized tags after the last segment, preserved verbatim.
    public var trailingUnknownTags: [String]

    public init(targetDuration: Int, mediaSequence: Int = 0, playlistType: PlaylistType? = nil, segments: [Segment] = [], hasEndList: Bool = false, version: Int? = nil) {
        self.version = version
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.discontinuitySequence = 0
        self.playlistType = playlistType
        self.iFramesOnly = false
        self.independentSegments = false
        self.definitions = []
        self.segments = segments
        self.hasEndList = hasEndList
        self.trailingParts = []
        self.preloadHints = []
        self.renditionReports = []
        self.trailingDateRanges = []
        self.unknownTags = []
        self.trailingUnknownTags = []
    }

    // MARK: Queries

    /// Sum of all segment durations, in seconds.
    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Whether the playlist may still grow (no `EXT-X-ENDLIST`).
    public var isLive: Bool { !hasEndList && playlistType != .vod }

    /// Whether the playlist uses Low-Latency HLS features.
    public var isLowLatency: Bool { partTarget != nil || segments.contains { !$0.parts.isEmpty } || !trailingParts.isEmpty }

    /// The media sequence number of the segment at `index`.
    public func mediaSequence(ofSegmentAt index: Int) -> Int { mediaSequence &+ index }

    /// Start time (seconds from the beginning of the playlist) of each segment.
    public var segmentStartTimes: [Double] {
        var time = 0.0
        return segments.map { segment in
            defer { time += segment.duration }
            return time
        }
    }

    /// The index of the segment containing `time` (seconds from the start).
    public func segmentIndex(containing time: Double) -> Int? {
        guard time >= 0 else { return nil }
        var start = 0.0
        for (index, segment) in segments.enumerated() {
            if time < start + segment.duration { return index }
            start += segment.duration
        }
        return nil
    }

    /// Program date-time of every segment, extrapolated from the nearest
    /// preceding explicit `EXT-X-PROGRAM-DATE-TIME` (or following one, for
    /// segments before the first explicit tag).
    public var programDateTimes: [Date?] {
        var result = [Date?](repeating: nil, count: segments.count)
        var anchor: (date: Date, index: Int)?
        var offsets = [Double](repeating: 0, count: segments.count)
        var running = 0.0
        for (index, segment) in segments.enumerated() {
            offsets[index] = running
            running += segment.duration
        }
        for (index, segment) in segments.enumerated() {
            if let date = segment.programDateTime { anchor = (date, index) }
            if let anchor { result[index] = anchor.date.addingTimeInterval(offsets[index] - offsets[anchor.index]) }
        }
        if let first = segments.firstIndex(where: { $0.programDateTime != nil }), let date = segments[first].programDateTime {
            for index in 0..<first { result[index] = date.addingTimeInterval(offsets[index] - offsets[first]) }
        }
        return result
    }

    /// The recommended distance from the live edge to start playback:
    /// `HOLD-BACK` if present, otherwise three target durations.
    public var recommendedLiveOffset: Double {
        if isLowLatency, let partHoldBack = serverControl?.partHoldBack { return partHoldBack }
        return serverControl?.holdBack ?? Double(targetDuration * 3)
    }
}

/// A parsed HLS playlist.
public enum Playlist: Sendable, Hashable {
    case multivariant(MultivariantPlaylist)
    case media(MediaPlaylist)

    public var multivariant: MultivariantPlaylist? {
        if case .multivariant(let playlist) = self { return playlist }
        return nil
    }

    public var media: MediaPlaylist? {
        if case .media(let playlist) = self { return playlist }
        return nil
    }
}
