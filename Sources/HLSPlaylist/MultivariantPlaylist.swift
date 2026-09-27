import Foundation

/// `EXT-X-STREAM-INF` followed by its URI: one variant stream.
public struct Variant: Sendable, Hashable {
    public var uri: String
    /// Peak bits per second.
    public var bandwidth: Int
    public var averageBandwidth: Int?
    public var score: Double?
    /// RFC 6381 codec strings, e.g. `["avc1.64001f", "mp4a.40.2"]`.
    public var codecs: [String]
    public var supplementalCodecs: String?
    public var resolution: Resolution?
    public var frameRate: Double?
    public var hdcpLevel: String?
    public var allowedCPC: String?
    /// `SDR`, `HLG` or `PQ`.
    public var videoRange: String?
    public var requiredVideoLayout: String?
    public var stableVariantID: String?
    public var audioGroupID: String?
    public var videoGroupID: String?
    public var subtitlesGroupID: String?
    /// Group ID, or `nil`. `closedCaptionsNone` indicates `CLOSED-CAPTIONS=NONE`.
    public var closedCaptionsGroupID: String?
    public var closedCaptionsNone: Bool
    public var pathwayID: String?
    public var programID: Int?
    public var otherAttributes: AttributeList
    /// Unrecognized tags that appeared between the previous URI and this variant.
    public var unknownTags: [String]

    public init(uri: String, bandwidth: Int, averageBandwidth: Int? = nil, codecs: [String] = [], resolution: Resolution? = nil, frameRate: Double? = nil, audioGroupID: String? = nil, subtitlesGroupID: String? = nil) {
        self.uri = uri
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.codecs = codecs
        self.resolution = resolution
        self.frameRate = frameRate
        self.audioGroupID = audioGroupID
        self.subtitlesGroupID = subtitlesGroupID
        self.closedCaptionsNone = false
        self.otherAttributes = AttributeList()
        self.unknownTags = []
    }

    static let known: Set<String> = [
        "BANDWIDTH", "AVERAGE-BANDWIDTH", "SCORE", "CODECS", "SUPPLEMENTAL-CODECS", "RESOLUTION", "FRAME-RATE",
        "HDCP-LEVEL", "ALLOWED-CPC", "VIDEO-RANGE", "REQ-VIDEO-LAYOUT", "STABLE-VARIANT-ID", "AUDIO", "VIDEO",
        "SUBTITLES", "CLOSED-CAPTIONS", "PATHWAY-ID", "PROGRAM-ID", "URI",
    ]

    init(uri: String, attributes a: AttributeList) {
        self.uri = uri
        bandwidth = a["BANDWIDTH"]?.integer ?? 0
        averageBandwidth = a["AVERAGE-BANDWIDTH"]?.integer
        score = a["SCORE"]?.double
        codecs = a["CODECS"].map { Variant.splitCodecs($0.rawValue) } ?? []
        supplementalCodecs = a["SUPPLEMENTAL-CODECS"]?.rawValue
        resolution = a["RESOLUTION"]?.resolution
        frameRate = a["FRAME-RATE"]?.double
        hdcpLevel = a["HDCP-LEVEL"]?.rawValue
        allowedCPC = a["ALLOWED-CPC"]?.rawValue
        videoRange = a["VIDEO-RANGE"]?.rawValue
        requiredVideoLayout = a["REQ-VIDEO-LAYOUT"]?.rawValue
        stableVariantID = a["STABLE-VARIANT-ID"]?.rawValue
        audioGroupID = a["AUDIO"]?.rawValue
        videoGroupID = a["VIDEO"]?.rawValue
        subtitlesGroupID = a["SUBTITLES"]?.rawValue
        if case .unquoted("NONE")? = a["CLOSED-CAPTIONS"] {
            closedCaptionsNone = true
            closedCaptionsGroupID = nil
        } else {
            closedCaptionsNone = false
            closedCaptionsGroupID = a["CLOSED-CAPTIONS"]?.rawValue
        }
        pathwayID = a["PATHWAY-ID"]?.rawValue
        programID = a["PROGRAM-ID"]?.integer
        otherAttributes = a.excluding(Self.known)
        unknownTags = []
    }

    func attributes(includeURI: Bool) -> AttributeList {
        var a = AttributeList()
        a.set("BANDWIDTH", int: bandwidth)
        a.set("AVERAGE-BANDWIDTH", int: averageBandwidth)
        a.set("SCORE", double: score)
        if !codecs.isEmpty { a.set("CODECS", quoted: codecs.joined(separator: ",")) }
        a.set("SUPPLEMENTAL-CODECS", quoted: supplementalCodecs)
        a.set("RESOLUTION", unquoted: resolution?.description)
        a.set("FRAME-RATE", unquoted: frameRate.map { String(format: "%.3f", $0) })
        a.set("HDCP-LEVEL", unquoted: hdcpLevel)
        a.set("ALLOWED-CPC", quoted: allowedCPC)
        a.set("VIDEO-RANGE", unquoted: videoRange)
        a.set("REQ-VIDEO-LAYOUT", quoted: requiredVideoLayout)
        a.set("STABLE-VARIANT-ID", quoted: stableVariantID)
        a.set("AUDIO", quoted: audioGroupID)
        a.set("VIDEO", quoted: videoGroupID)
        a.set("SUBTITLES", quoted: subtitlesGroupID)
        if closedCaptionsNone { a.set("CLOSED-CAPTIONS", unquoted: "NONE") } else { a.set("CLOSED-CAPTIONS", quoted: closedCaptionsGroupID) }
        a.set("PATHWAY-ID", quoted: pathwayID)
        a.set("PROGRAM-ID", int: programID)
        if includeURI { a.set("URI", quoted: uri) }
        a.merge(otherAttributes)
        return a
    }

    static func splitCodecs(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether the variant carries video (by resolution or a video codec).
    public var hasVideo: Bool {
        resolution != nil || codecs.contains { CodecFamily(codec: $0)?.isVideo == true }
    }

    /// Whether the variant is audio-only.
    public var isAudioOnly: Bool {
        !hasVideo && !codecs.isEmpty && codecs.allSatisfy { CodecFamily(codec: $0)?.isVideo == false }
    }

    /// The bandwidth used for adaptive decisions: average if known, else peak.
    public var effectiveBandwidth: Int { averageBandwidth ?? bandwidth }
}

/// `EXT-X-MEDIA`: an alternative rendition (audio track, subtitles, …).
public struct Rendition: Sendable, Hashable {
    public enum MediaType: Sendable, Hashable, CustomStringConvertible {
        case audio, video, subtitles, closedCaptions
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "AUDIO": self = .audio
            case "VIDEO": self = .video
            case "SUBTITLES": self = .subtitles
            case "CLOSED-CAPTIONS": self = .closedCaptions
            default: self = .other(raw)
            }
        }

        public var description: String {
            switch self {
            case .audio: "AUDIO"
            case .video: "VIDEO"
            case .subtitles: "SUBTITLES"
            case .closedCaptions: "CLOSED-CAPTIONS"
            case .other(let raw): raw
            }
        }
    }

    public var type: MediaType
    public var groupID: String
    public var name: String
    public var uri: String?
    public var language: String?
    public var associatedLanguage: String?
    public var stableRenditionID: String?
    public var isDefault: Bool
    public var autoselect: Bool
    public var forced: Bool
    /// e.g. `CC1` or `SERVICE3`.
    public var instreamID: String?
    public var bitDepth: Int?
    public var sampleRate: Int?
    /// Comma-separated UTIs, e.g. `public.accessibility.describes-video`.
    public var characteristics: String?
    /// e.g. `2`, `6`, `16/JOC`.
    public var channels: String?
    public var otherAttributes: AttributeList

    public init(type: MediaType, groupID: String, name: String, uri: String? = nil, language: String? = nil, isDefault: Bool = false, autoselect: Bool = false, forced: Bool = false, channels: String? = nil) {
        self.type = type
        self.groupID = groupID
        self.name = name
        self.uri = uri
        self.language = language
        self.isDefault = isDefault
        self.autoselect = autoselect
        self.forced = forced
        self.channels = channels
        self.otherAttributes = AttributeList()
    }

    static let known: Set<String> = [
        "TYPE", "URI", "GROUP-ID", "LANGUAGE", "ASSOC-LANGUAGE", "NAME", "STABLE-RENDITION-ID", "DEFAULT",
        "AUTOSELECT", "FORCED", "INSTREAM-ID", "BIT-DEPTH", "SAMPLE-RATE", "CHARACTERISTICS", "CHANNELS",
    ]

    init(attributes a: AttributeList) {
        type = MediaType(a["TYPE"]?.rawValue ?? "")
        groupID = a["GROUP-ID"]?.rawValue ?? ""
        name = a["NAME"]?.rawValue ?? ""
        uri = a["URI"]?.rawValue
        language = a["LANGUAGE"]?.rawValue
        associatedLanguage = a["ASSOC-LANGUAGE"]?.rawValue
        stableRenditionID = a["STABLE-RENDITION-ID"]?.rawValue
        isDefault = a.bool("DEFAULT") ?? false
        autoselect = a.bool("AUTOSELECT") ?? false
        forced = a.bool("FORCED") ?? false
        instreamID = a["INSTREAM-ID"]?.rawValue
        bitDepth = a["BIT-DEPTH"]?.integer
        sampleRate = a["SAMPLE-RATE"]?.integer
        characteristics = a["CHARACTERISTICS"]?.rawValue
        channels = a["CHANNELS"]?.rawValue
        otherAttributes = a.excluding(Self.known)
    }

    var attributes: AttributeList {
        var a = AttributeList()
        a.set("TYPE", unquoted: type.description)
        a.set("GROUP-ID", quoted: groupID)
        a.set("NAME", quoted: name)
        a.set("LANGUAGE", quoted: language)
        a.set("ASSOC-LANGUAGE", quoted: associatedLanguage)
        a.set("STABLE-RENDITION-ID", quoted: stableRenditionID)
        if isDefault { a.set("DEFAULT", bool: true) }
        if autoselect { a.set("AUTOSELECT", bool: true) }
        if forced { a.set("FORCED", bool: true) }
        a.set("INSTREAM-ID", quoted: instreamID)
        a.set("BIT-DEPTH", int: bitDepth)
        a.set("SAMPLE-RATE", int: sampleRate)
        a.set("CHARACTERISTICS", quoted: characteristics)
        a.set("CHANNELS", quoted: channels)
        a.set("URI", quoted: uri)
        a.merge(otherAttributes)
        return a
    }

    /// The number of audio channels, parsed from ``channels``.
    public var channelCount: Int? {
        channels?.split(separator: "/").first.flatMap { Int($0) }
    }
}

/// A multivariant (a.k.a. master) playlist listing variant streams and renditions.
public struct MultivariantPlaylist: Sendable, Hashable {
    public var version: Int?
    public var independentSegments: Bool
    public var start: StartPoint?
    public var definitions: [VariableDefinition]
    public var variants: [Variant]
    /// `EXT-X-I-FRAME-STREAM-INF` variants (URI is the attribute).
    public var iFrameVariants: [Variant]
    public var renditions: [Rendition]
    public var sessionData: [SessionData]
    public var sessionKeys: [EncryptionKey]
    /// `EXT-X-CONTENT-STEERING` attributes.
    public var contentSteering: AttributeList?
    /// Tags this library does not model, preserved verbatim (in order, at the end of the header).
    public var unknownTags: [String]

    public init(version: Int? = nil, independentSegments: Bool = false, variants: [Variant] = [], renditions: [Rendition] = []) {
        self.version = version
        self.independentSegments = independentSegments
        self.definitions = []
        self.variants = variants
        self.iFrameVariants = []
        self.renditions = renditions
        self.sessionData = []
        self.sessionKeys = []
        self.unknownTags = []
    }

    // MARK: Queries

    /// Renditions belonging to a group.
    public func renditions(inGroup groupID: String, type: Rendition.MediaType? = nil) -> [Rendition] {
        renditions.filter { $0.groupID == groupID && (type == nil || $0.type == type) }
    }

    /// Audio renditions available with `variant`.
    public func audioRenditions(for variant: Variant) -> [Rendition] {
        variant.audioGroupID.map { renditions(inGroup: $0, type: .audio) } ?? []
    }

    /// Subtitle renditions available with `variant`.
    public func subtitleRenditions(for variant: Variant) -> [Rendition] {
        variant.subtitlesGroupID.map { renditions(inGroup: $0, type: .subtitles) } ?? []
    }

    /// Variants ordered from lowest to highest bandwidth.
    public var variantsByBandwidth: [Variant] {
        variants.sorted { $0.effectiveBandwidth < $1.effectiveBandwidth }
    }

    /// Chooses the best variant within the given constraints: the highest
    /// bandwidth that fits, falling back to the lowest-bandwidth variant
    /// when nothing fits.
    ///
    /// - Parameters:
    ///   - maxBandwidth: Upper bound on ``Variant/effectiveBandwidth``.
    ///   - maxResolution: Upper bound on width and height.
    ///   - isCodecSupported: Filters out variants with any unsupported codec.
    public func preferredVariant(
        maxBandwidth: Int? = nil,
        maxResolution: Resolution? = nil,
        isCodecSupported: (String) -> Bool = { _ in true }
    ) -> Variant? {
        let playable = variants.filter { $0.codecs.allSatisfy(isCodecSupported) }
        let candidates = playable.filter { variant in
            if let maxBandwidth, variant.effectiveBandwidth > maxBandwidth { return false }
            if let maxResolution, let resolution = variant.resolution,
               resolution.width > maxResolution.width || resolution.height > maxResolution.height { return false }
            return true
        }
        let ranked: (Variant, Variant) -> Bool = {
            ($0.score ?? 0, $0.effectiveBandwidth, $0.resolution?.pixelCount ?? 0)
                < ($1.score ?? 0, $1.effectiveBandwidth, $1.resolution?.pixelCount ?? 0)
        }
        return candidates.max(by: ranked) ?? playable.min { $0.effectiveBandwidth < $1.effectiveBandwidth }
    }
}

/// Broad codec families derived from RFC 6381 codec strings.
public enum CodecFamily: Sendable, Hashable {
    case h264, hevc, av1, vp9, dolbyVision
    case aac, ac3, eac3, ac4, mp3, opus, flac, alac
    case webVTT, imsc

    public init?(codec: String) {
        let prefix = codec.lowercased().split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "avc1", "avc3": self = .h264
        case "hvc1", "hev1": self = .hevc
        case "av01": self = .av1
        case "vp09": self = .vp9
        case "dvh1", "dvhe", "dva1", "dvav", "dav1": self = .dolbyVision
        case "mp4a":
            // mp4a.40.x is AAC, mp4a.69/6B is MP3.
            let lower = codec.lowercased()
            self = lower.hasPrefix("mp4a.69") || lower.hasPrefix("mp4a.6b") ? .mp3 : .aac
        case "ac-3": self = .ac3
        case "ec-3": self = .eac3
        case "ac-4": self = .ac4
        case "mp3": self = .mp3
        case "opus": self = .opus
        case "flac", "fLaC".lowercased(): self = .flac
        case "alac": self = .alac
        case "wvtt": self = .webVTT
        case "stpp": self = .imsc
        default: return nil
        }
    }

    public var isVideo: Bool {
        switch self {
        case .h264, .hevc, .av1, .vp9, .dolbyVision: true
        default: false
        }
    }
}
