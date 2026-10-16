import Foundation
import Testing
@testable import HLSPlaylist

@Suite("Content steering and interstitial URI rewriting")
struct URIRewritingTests {
    static let master = """
    #EXTM3U
    #EXT-X-VERSION:10
    #EXT-X-CONTENT-STEERING:SERVER-URI="../steering.json?token=a,b",PATHWAY-ID="cdn-a"
    #EXT-X-STREAM-INF:BANDWIDTH=1000000,PATHWAY-ID="cdn-a",STABLE-VARIANT-ID="main",CLOSED-CAPTIONS=NONE
    video/index.m3u8
    """

    static let media = """
    #EXTM3U
    #EXT-X-VERSION:10
    #EXT-X-TARGETDURATION:6
    #EXT-X-PROGRAM-DATE-TIME:2026-10-16T12:00:00Z
    #EXT-X-DATERANGE:ID="asset",CLASS="com.apple.hls.interstitial",START-DATE="2026-10-16T12:00:00Z",X-ASSET-URI="../ads/asset.m3u8",X-RESUME-OFFSET=0
    #EXT-X-DATERANGE:ID="list",CLASS="com.apple.hls.interstitial",START-DATE="2026-10-16T12:00:06Z",X-ASSET-LIST="/ads/list.json?token=a,b",X-RESTRICT="SKIP,JUMP"
    #EXT-X-DATERANGE:ID="metadata",CLASS="com.example.metadata",START-DATE="2026-10-16T12:00:00Z",X-ASSET-URI="metadata.txt",X-ASSET-LIST="metadata.json"
    #EXT-X-DATERANGE:ID="empty",CLASS="com.apple.hls.interstitial",START-DATE="2026-10-16T12:00:12Z"
    #EXTINF:6,
    first.ts
    #EXT-X-DATERANGE:ID="later",CLASS="com.apple.hls.interstitial",START-DATE="2026-10-16T12:00:06Z",X-ASSET-URI="https://ads.example.com/second.m3u8"
    #EXTINF:6,
    second.ts
    #EXT-X-ENDLIST
    """

    @Test func rewritesContentSteeringAndPreservesAttributes() throws {
        let playlist = try #require(try Playlist(Self.master).multivariant)
        var roles: [URIRole] = []
        let mapped = playlist.mapURIs { uri, role in
            roles.append(role)
            return "proxy://" + uri
        }
        #expect(roles == [.variant, .contentSteering])
        #expect(mapped.contentSteering?["SERVER-URI"] == .quoted("proxy://../steering.json?token=a,b"))
        #expect(mapped.contentSteering?["PATHWAY-ID"] == playlist.contentSteering?["PATHWAY-ID"])
        #expect(mapped.contentSteering?.keys == playlist.contentSteering?.keys)
        #expect(playlist.contentSteering?["SERVER-URI"] == .quoted("../steering.json?token=a,b"))
        #expect(try Playlist(mapped.render()).multivariant == mapped)
    }

    @Test func rewritesInterstitialsAndPreservesOtherDateRanges() throws {
        let playlist = try #require(try Playlist(Self.media).media)
        var roles: [URIRole] = []
        let mapped = playlist.mapURIs { uri, role in
            roles.append(role)
            return "proxy://" + uri
        }
        #expect(roles == [.segment, .interstitialAsset, .interstitialAssetList, .segment, .interstitialAsset])
        let ranges = mapped.segments[0].dateRanges
        #expect(ranges[0].otherAttributes["X-ASSET-URI"] == .quoted("proxy://../ads/asset.m3u8"))
        #expect(ranges[1].otherAttributes["X-ASSET-LIST"] == .quoted("proxy:///ads/list.json?token=a,b"))
        #expect(ranges[0].otherAttributes["X-RESUME-OFFSET"] == .unquoted("0"))
        #expect(ranges[1].otherAttributes["X-RESTRICT"] == .quoted("SKIP,JUMP"))
        #expect(ranges[0].otherAttributes.keys == playlist.segments[0].dateRanges[0].otherAttributes.keys)
        #expect(ranges[2] == playlist.segments[0].dateRanges[2])
        #expect(ranges[3] == playlist.segments[0].dateRanges[3])
        #expect(mapped.segments[1].dateRanges[0].otherAttributes["X-ASSET-URI"] == .quoted("proxy://https://ads.example.com/second.m3u8"))
        #expect(playlist.segments[0].dateRanges[0].otherAttributes["X-ASSET-URI"] == .quoted("../ads/asset.m3u8"))
        #expect(try Playlist(mapped.render()).media == mapped)
    }

    @Test func resolvesExtensionURIsThroughPlaylist() throws {
        let base = URL(string: "https://cdn.example.com/show/index.m3u8")!
        let master = try Playlist(Self.master).resolvingURIs(against: base)
        #expect(master.multivariant?.contentSteering?["SERVER-URI"] == .quoted("https://cdn.example.com/steering.json?token=a,b"))
        let media = try Playlist(Self.media).resolvingURIs(against: base)
        #expect(media.media?.segments[0].dateRanges[0].otherAttributes["X-ASSET-URI"] == .quoted("https://cdn.example.com/ads/asset.m3u8"))
        #expect(media.media?.segments[0].dateRanges[1].otherAttributes["X-ASSET-LIST"] == .quoted("https://cdn.example.com/ads/list.json?token=a,b"))
        #expect(media.media?.segments[1].dateRanges[0].otherAttributes["X-ASSET-URI"] == .quoted("https://ads.example.com/second.m3u8"))
    }

    @Test func leavesMissingSteeringURIsAlone() {
        var playlist = MultivariantPlaylist()
        #expect(playlist.mapURIs { _, _ in Issue.record("Unexpected URI"); return "" } == playlist)
        playlist.contentSteering = ["PATHWAY-ID": .quoted("cdn-a")]
        #expect(playlist.mapURIs { _, _ in Issue.record("Unexpected URI"); return "" } == playlist)
    }

    @Test func rewritesTrailingInterstitialDateRanges() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        first.ts
        #EXT-X-DATERANGE:ID="asset",CLASS="com.apple.hls.interstitial",START-DATE="2026-10-16T12:00:06Z",X-ASSET-URI="ads/asset.m3u8"
        #EXT-X-DATERANGE:ID="list",CLASS="com.apple.hls.interstitial",START-DATE="2026-10-16T12:00:12Z",X-ASSET-LIST="ads/list.json"
        """
        let playlist = try #require(try Playlist(text).media)
        #expect(playlist.trailingDateRanges.count == 2)
        var roles: [URIRole] = []
        let mapped = playlist.mapURIs { uri, role in
            roles.append(role)
            return "proxy://" + uri
        }
        #expect(roles == [.segment, .interstitialAsset, .interstitialAssetList])
        #expect(mapped.trailingDateRanges[0].otherAttributes["X-ASSET-URI"] == .quoted("proxy://ads/asset.m3u8"))
        #expect(mapped.trailingDateRanges[1].otherAttributes["X-ASSET-LIST"] == .quoted("proxy://ads/list.json"))
        #expect(playlist.trailingDateRanges[0].otherAttributes["X-ASSET-URI"] == .quoted("ads/asset.m3u8"))
        #expect(try Playlist(mapped.render()).media == mapped)
        let resolved = playlist.resolvingURIs(against: URL(string: "https://example.com/live/index.m3u8")!)
        #expect(resolved.trailingDateRanges[1].otherAttributes["X-ASSET-LIST"] == .quoted("https://example.com/live/ads/list.json"))
        #expect(throws: TransformError.rejected) {
            try playlist.mapURIs { uri, role in
                if role == .interstitialAssetList { throw TransformError.rejected }
                return uri
            }
        }
    }

    private enum TransformError: Error { case rejected }

    @Test(arguments: [URIRole.contentSteering, .interstitialAsset, .interstitialAssetList])
    func propagatesTransformErrors(_ rejectedRole: URIRole) throws {
        let playlist = try Playlist(rejectedRole == .contentSteering ? Self.master : Self.media)
        #expect(throws: TransformError.rejected) {
            try playlist.mapURIs { uri, role in
                if role == rejectedRole { throw TransformError.rejected }
                return uri
            }
        }
    }
}
