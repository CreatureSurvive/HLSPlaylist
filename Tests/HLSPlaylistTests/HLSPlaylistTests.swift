import Foundation
import Testing
@testable import HLSPlaylist

@Suite("Attribute lists")
struct AttributeListTests {
    @Test func parsesQuotedCommasAndTypedValues() {
        let list = AttributeList.parse(#"BANDWIDTH=1280000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720,IV=0x1A2B,FRAME-RATE=29.970,NAME="a=b""#)
        #expect(list.keys == ["BANDWIDTH", "CODECS", "RESOLUTION", "IV", "FRAME-RATE", "NAME"])
        #expect(list["BANDWIDTH"]?.integer == 1_280_000)
        #expect(list["CODECS"] == .quoted("avc1.4d401f,mp4a.40.2"))
        #expect(list["RESOLUTION"]?.resolution == Resolution(width: 1280, height: 720))
        #expect(list["IV"]?.hexBytes == [0x1A, 0x2B])
        #expect(list["FRAME-RATE"]?.double == 29.97)
        #expect(list["NAME"]?.rawValue == "a=b")
    }

    @Test func toleratesWhitespaceAndMalformedEntries() {
        let list = AttributeList.parse(#" A = 1 , BOGUS, B="x" ,C=,"#)
        #expect(list["A"]?.integer == 1)
        #expect(list["B"]?.rawValue == "x")
        #expect(list["C"]?.rawValue == "")
        #expect(list["BOGUS"] == nil)
    }

    @Test func unterminatedQuoteRunsToEnd() {
        let list = AttributeList.parse(#"URI="abc,def"#)
        #expect(list["URI"]?.rawValue == "abc,def")
    }

    @Test func serializesInOrder() {
        var list = AttributeList()
        list["B"] = .unquoted("1")
        list["A"] = .quoted("x,y")
        list["B"] = .unquoted("2")
        #expect(list.serialized == #"B=2,A="x,y""#)
        list["B"] = nil
        #expect(list.serialized == #"A="x,y""#)
    }
}

@Suite("Multivariant playlists")
struct MultivariantTests {
    let playlist = try! Playlist(Fixtures.multivariant).multivariant!

    @Test func parsesHeaderAndCollections() {
        #expect(playlist.version == 6)
        #expect(playlist.independentSegments)
        #expect(playlist.variants.count == 5)
        #expect(playlist.renditions.count == 4)
        #expect(playlist.iFrameVariants.count == 1)
        #expect(playlist.sessionData.first?.value == "Example")
    }

    @Test func parsesVariantAttributes() throws {
        let first = try #require(playlist.variants.first)
        #expect(first.uri == "v5/prog_index.m3u8")
        #expect(first.bandwidth == 2_177_116)
        #expect(first.averageBandwidth == 2_168_183)
        #expect(first.codecs == ["avc1.640020", "mp4a.40.2"])
        #expect(first.resolution == Resolution(width: 960, height: 540))
        #expect(first.frameRate == 60)
        #expect(first.audioGroupID == "aud1")
        #expect(first.closedCaptionsGroupID == "cc1")
        #expect(first.hasVideo)

        let hdr = playlist.variants[4]
        #expect(hdr.closedCaptionsNone)
        #expect(hdr.closedCaptionsGroupID == nil)
        #expect(hdr.videoRange == "PQ")
        #expect(playlist.iFrameVariants[0].uri == "v9/iframe_index.m3u8")
    }

    @Test func groupsRenditions() throws {
        let variant = playlist.variants[0]
        #expect(playlist.audioRenditions(for: variant).map(\.uri) == ["a1/prog_index.m3u8"])
        #expect(playlist.subtitleRenditions(for: variant).first?.isDefault == true)
        #expect(playlist.renditions(inGroup: "aud2").first?.channelCount == 6)
        let cc = try #require(playlist.renditions.first { $0.type == .closedCaptions })
        #expect(cc.instreamID == "CC1")
        #expect(cc.uri == nil)
    }

    @Test func selectsPreferredVariant() {
        #expect(playlist.preferredVariant()?.uri == "h9/prog_index.m3u8")
        #expect(playlist.preferredVariant(isCodecSupported: { CodecFamily(codec: $0) != .hevc })?.uri == "v9/prog_index.m3u8")
        #expect(playlist.preferredVariant(maxBandwidth: 7_000_000)?.uri == "v8/prog_index.m3u8")
        #expect(playlist.preferredVariant(maxResolution: Resolution(width: 1280, height: 720))?.uri == "v5/prog_index.m3u8")
        // Nothing fits: fall back to the lowest bandwidth.
        #expect(playlist.preferredVariant(maxBandwidth: 1000)?.uri == "v2/prog_index.m3u8")
        #expect(playlist.variantsByBandwidth.first?.uri == "v2/prog_index.m3u8")
    }

    @Test func roundTrips() throws {
        let rendered = playlist.render()
        let reparsed = try #require(try Playlist(rendered).multivariant)
        #expect(reparsed == playlist)
        #expect(rendered.contains(#"CLOSED-CAPTIONS=NONE"#))
        #expect(rendered.contains(#"CODECS="avc1.640020,mp4a.40.2""#))
    }

    @Test func rewritesAndResolvesURIs() {
        let base = URL(string: "https://cdn.example.com/show/master.m3u8?token=abc")!
        let resolved = playlist.resolvingURIs(against: base)
        #expect(resolved.variants[0].uri == "https://cdn.example.com/show/v5/prog_index.m3u8")
        #expect(resolved.renditions[0].uri == "https://cdn.example.com/show/a1/prog_index.m3u8")
        #expect(resolved.iFrameVariants[0].uri == "https://cdn.example.com/show/v9/iframe_index.m3u8")

        var roles: [URIRole] = []
        _ = playlist.mapURIs { uri, role in
            roles.append(role)
            return "proxy://" + uri
        }
        #expect(roles.filter { $0 == .variant }.count == 5)
        #expect(roles.filter { $0 == .rendition }.count == 3) // CC rendition has no URI
    }
}

@Suite("Media playlists")
struct MediaPlaylistTests {
    @Test func parsesEncryptedVOD() throws {
        let playlist = try #require(try Playlist(Fixtures.encryptedVOD).media)
        #expect(playlist.version == 7)
        #expect(playlist.playlistType == .vod)
        #expect(!playlist.isLive)
        #expect(playlist.segments.count == 5)
        #expect(abs(playlist.duration - 25.512) < 0.0001)

        let s0 = playlist.segments[0]
        #expect(s0.title == "Intro")
        #expect(s0.map == MediaInitializationSection(uri: "init.mp4", byteRange: ByteRange(length: 720, offset: 0)))
        #expect(s0.keys.first?.method == .aes128)
        #expect(s0.keys.first?.iv?.last == 0x0A)
        #expect(s0.isEncrypted)

        #expect(playlist.segments[1].byteRange == ByteRange(length: 1000, offset: 720))
        #expect(playlist.segments[2].byteRange == ByteRange(length: 2000))
        #expect(playlist.segments[2].keys == s0.keys) // key carries forward

        let ad = playlist.segments[3]
        #expect(ad.discontinuity)
        #expect(ad.keys.isEmpty)
        #expect(ad.map?.uri == "ad-init.mp4")

        let drm = playlist.segments[4]
        #expect(drm.keys.count == 2) // FairPlay + Widevine coexist
        #expect(drm.keys.map(\.method) == [.sampleAES, .sampleAES])
        #expect(drm.map?.uri == "ad-init.mp4")
    }

    @Test func derivesIVFromMediaSequence() {
        let key = EncryptionKey(method: .aes128, uri: "k")
        #expect(key.initializationVector(forMediaSequence: 0x0102) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2])
    }

    @Test func roundTripsEncryptedVOD() throws {
        let playlist = try #require(try Playlist(Fixtures.encryptedVOD).media)
        let rendered = playlist.render()
        #expect(try Playlist(rendered).media == playlist)
        // Keys and maps are emitted only when they change.
        #expect(rendered.components(separatedBy: "#EXT-X-MAP").count - 1 == 2)
        #expect(rendered.contains("#EXT-X-KEY:METHOD=NONE"))
        #expect(rendered.contains("IV=0x0000000000000000000000000000000A"))
    }

    @Test func parsesLowLatency() throws {
        let playlist = try #require(try Playlist(Fixtures.lowLatency).media)
        #expect(playlist.isLive)
        #expect(playlist.isLowLatency)
        #expect(playlist.partTarget == 0.33334)
        #expect(playlist.serverControl?.canBlockReload == true)
        #expect(playlist.serverControl?.canSkipUntil == 12)
        #expect(playlist.recommendedLiveOffset == 1.0)
        #expect(playlist.segments.count == 3)
        #expect(playlist.segments[2].parts.count == 2)
        #expect(playlist.segments[2].parts[0].independent)
        #expect(playlist.trailingParts.map(\.uri) == ["filePart269.0.mp4", "filePart269.1.mp4"])
        #expect(playlist.preloadHints.first?.uri == "filePart269.2.mp4")
        #expect(playlist.renditionReports.map(\.lastMediaSequence) == [269, 269])
        #expect(playlist.mediaSequence(ofSegmentAt: 2) == 268)
        #expect(try Playlist(playlist.render()).media == playlist)
    }

    @Test func parsesDateRangesAndPreservesUnknownTags() throws {
        let playlist = try #require(try Playlist(Fixtures.liveWithDateRanges).media)
        #expect(playlist.discontinuitySequence == 3)
        #expect(playlist.unknownTags == ["#EXT-X-PLEX-VENDOR:foo"])
        let range = try #require(playlist.segments[1].dateRanges.first)
        #expect(range.id == "splice-6FFFFFF0")
        #expect(range.plannedDuration == 59.993)
        #expect(range.scte35Out?.hasPrefix("0xFC002F") == true)
        #expect(range.otherAttributes["X-COM-EXAMPLE-AD-ID"]?.rawValue == "XYZ123")
        #expect(playlist.segments[1].unknownTags == ["#EXT-X-CUE-OUT:DURATION=60"])
        #expect(range.startDate == Date(timeIntervalSince1970: 1_790_485_210))

        let rendered = playlist.render()
        #expect(rendered.contains("#EXT-X-CUE-OUT:DURATION=60"))
        #expect(try Playlist(rendered).media == playlist)
    }

    @Test func extrapolatesProgramDateTimes() throws {
        let playlist = try #require(try Playlist(Fixtures.liveWithDateRanges).media)
        let dates = playlist.programDateTimes
        #expect(dates[0] == Date(timeIntervalSince1970: 1_790_485_200))
        #expect(dates[2] == Date(timeIntervalSince1970: 1_790_485_220))
    }

    @Test func locatesSegmentsByTime() throws {
        let playlist = try #require(try Playlist(Fixtures.liveWithDateRanges).media)
        #expect(playlist.segmentStartTimes == [0, 10, 20])
        #expect(playlist.segmentIndex(containing: 0) == 0)
        #expect(playlist.segmentIndex(containing: 19.99) == 1)
        #expect(playlist.segmentIndex(containing: 29.4) == 2)
        #expect(playlist.segmentIndex(containing: 29.5) == nil)
    }

    @Test func rewritesEveryURIKind() throws {
        let vod = try #require(try Playlist(Fixtures.encryptedVOD).media)
        let proxied = vod.mapURIs { uri, role in "http://127.0.0.1:8080/\(role)?u=\(uri)" }
        #expect(proxied.segments[0].uri == "http://127.0.0.1:8080/segment?u=main.mp4")
        #expect(proxied.segments[0].map?.uri == "http://127.0.0.1:8080/initializationSection?u=init.mp4")
        #expect(proxied.segments[1].keys.first?.uri == "http://127.0.0.1:8080/key?u=https://keys.example.com/k1")
        // Shared key is still shared after rewriting, so it is emitted once.
        #expect(proxied.render().components(separatedBy: "keys.example.com").count - 1 == 1)

        let ll = try #require(try Playlist(Fixtures.lowLatency).media)
        let resolved = ll.resolvingURIs(against: URL(string: "https://example.com/live/2M/index.m3u8")!)
        #expect(resolved.trailingParts[0].uri == "https://example.com/live/2M/filePart269.0.mp4")
        #expect(resolved.preloadHints[0].uri == "https://example.com/live/2M/filePart269.2.mp4")
        #expect(resolved.renditionReports[0].uri == "https://example.com/live/1M/waitForMSN.php")
    }

    @Test func buildsPlaylistsProgrammatically() throws {
        var playlist = MediaPlaylist(targetDuration: 6, playlistType: .vod, hasEndList: true, version: 3)
        for index in 0..<3 {
            playlist.segments.append(Segment(uri: "seg\(index).ts", duration: 6))
        }
        playlist.segments[2].discontinuity = true
        let text = playlist.render()
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:6,
        seg0.ts
        #EXTINF:6,
        seg1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6,
        seg2.ts
        #EXT-X-ENDLIST

        """)
    }
}

@Suite("Parsing behavior")
struct ParsingBehaviorTests {
    @Test func rejectsMissingHeader() {
        #expect(throws: PlaylistError.missingHeader) { try Playlist("#EXTINF:1,\na.ts") }
        #expect(throws: PlaylistError.missingHeader) { try Playlist("") }
    }

    @Test func toleratesBOMCRLFAndBlankLines() throws {
        let text = "\u{FEFF}#EXTM3U\r\n\r\n#EXT-X-TARGETDURATION:2\r\n#EXTINF:2,\r\na.ts\r\n"
        let playlist = try #require(try Playlist(text).media)
        #expect(playlist.segments.map(\.uri) == ["a.ts"])
    }

    @Test func rejectsAmbiguousPlaylists() {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8\n#EXTINF:1,\nb.ts\n"
        #expect(throws: PlaylistError.ambiguousPlaylistType) { try Playlist(text) }
    }

    @Test func collectsWarningsLenientlyAndThrowsStrictly() throws {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\norphan.ts\n#EXTINF:abc,\nb.ts\n"
        let result = try PlaylistParser().parse(text)
        #expect(result.warnings.count == 2)
        #expect(result.playlist.media?.segments.map(\.uri) == ["b.ts"])
        #expect(throws: PlaylistError.self) { try PlaylistParser(options: ParseOptions(strict: true)).parse(text) }
    }

    @Test func substitutesVariables() throws {
        let text = """
        #EXTM3U
        #EXT-X-DEFINE:NAME="host",VALUE="https://cdn.example.com"
        #EXT-X-DEFINE:QUERYPARAM="token"
        #EXT-X-DEFINE:IMPORT="lang"
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="{$host}/init.mp4"
        #EXTINF:4,
        {$host}/{$lang}/seg.m4s?t={$token}
        """
        let options = ParseOptions(importedVariables: ["lang": "en"], playlistURL: URL(string: "https://x/p.m3u8?token=s3cr3t")!)
        let result = try PlaylistParser(options: options).parse(text)
        let playlist = try #require(result.playlist.media)
        #expect(playlist.segments[0].uri == "https://cdn.example.com/en/seg.m4s?t=s3cr3t")
        #expect(playlist.segments[0].map?.uri == "https://cdn.example.com/init.mp4")
        #expect(result.variables == ["host": "https://cdn.example.com", "token": "s3cr3t", "lang": "en"])
        #expect(playlist.definitions.count == 3)
        #expect(result.warnings.isEmpty)
    }

    @Test func undefinedVariablesWarnOrThrow() throws {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\n{$missing}/a.ts\n"
        let result = try PlaylistParser().parse(text)
        #expect(result.playlist.media?.segments.first?.uri == "{$missing}/a.ts")
        #expect(result.warnings.count == 1)
        #expect(throws: PlaylistError.undefinedVariable(name: "missing", line: 4)) {
            try PlaylistParser(options: ParseOptions(strict: true)).parse(text)
        }
    }

    @Test func parsesDateVariants() {
        #expect(HLSDate.parse("2026-09-27T05:00:00Z") == Date(timeIntervalSince1970: 1_790_485_200))
        #expect(HLSDate.parse("2026-09-27T05:00:00.500Z") == Date(timeIntervalSince1970: 1_790_485_200.5))
        #expect(HLSDate.parse("2026-09-27T07:00:00+0200") == Date(timeIntervalSince1970: 1_790_485_200))
        #expect(HLSDate.parse("not a date") == nil)
        #expect(HLSDate.parse("2024-02-29T23:59:59.25-05:30") == Date(timeIntervalSince1970: 1_709_270_999.25))
        #expect(HLSDate.parse("1999-12-31T23:59:59Z") == Date(timeIntervalSince1970: 946_684_799))
        // Fast path agrees with ISO8601DateFormatter across many dates.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for step in stride(from: -2_000_000_000.0, through: 4_000_000_000.0, by: 7_654_321.125) {
            let date = Date(timeIntervalSince1970: step)
            let text = formatter.string(from: date)
            #expect(HLSDate.fastParse(text) == formatter.date(from: text), "\(text)")
        }
    }

    @Test func classifiesCodecs() {
        #expect(CodecFamily(codec: "avc1.640028") == .h264)
        #expect(CodecFamily(codec: "hvc1.2.4.L153.B0") == .hevc)
        #expect(CodecFamily(codec: "dvh1.05.06") == .dolbyVision)
        #expect(CodecFamily(codec: "mp4a.40.2") == .aac)
        #expect(CodecFamily(codec: "mp4a.69") == .mp3)
        #expect(CodecFamily(codec: "ec-3") == .eac3)
        #expect(CodecFamily(codec: "wvtt") == .webVTT)
        #expect(CodecFamily(codec: "xyz") == nil)
    }

    @Test func largePlaylistPerformance() throws {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<20_000 {
            text += "#EXT-X-PROGRAM-DATE-TIME:2026-09-27T05:00:00.000Z\n#EXTINF:6.006,\nsegment_\(index).ts\n"
        }
        text += "#EXT-X-ENDLIST\n"
        let clock = ContinuousClock()
        var playlist: MediaPlaylist?
        let elapsed = try clock.measure { playlist = try Playlist(text).media }
        #expect(playlist?.segments.count == 20_000)
        #expect(elapsed < .seconds(5), "Parsing 20k segments took \(elapsed)")
    }
}
