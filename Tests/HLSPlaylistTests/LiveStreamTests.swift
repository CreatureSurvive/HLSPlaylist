import Foundation
import Testing
import HLSPlaylist

/// Parses Apple's public example streams. Run with `HLS_LIVE_TESTS=1 swift test`.
@Suite("Live streams", .enabled(if: ProcessInfo.processInfo.environment["HLS_LIVE_TESTS"] == "1"))
struct LiveStreamTests {
    static let masters = [
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
    ]

    @Test(arguments: masters)
    func parsesAndRoundTripsAppleExamples(_ address: String) async throws {
        let url = try #require(URL(string: address))
        let (data, _) = try await URLSession.shared.data(from: url)
        let result = try PlaylistParser(options: ParseOptions(playlistURL: url)).parse(data)
        let master = try #require(result.playlist.multivariant)
        #expect(!master.variants.isEmpty)
        #expect(try Playlist(master.render()).multivariant == master)

        // Fetch every distinct media playlist referenced by the master.
        let resolved = master.resolvingURIs(against: url)
        let uris = Set(resolved.variants.map(\.uri) + resolved.renditions.compactMap(\.uri) + resolved.iFrameVariants.map(\.uri))
        for uri in uris.sorted() {
            let mediaURL = try #require(URL(string: uri))
            let (mediaData, _) = try await URLSession.shared.data(from: mediaURL)
            let parsed = try PlaylistParser(options: ParseOptions(playlistURL: mediaURL)).parse(mediaData)
            let media = try #require(parsed.playlist.media, "\(uri)")
            #expect(!media.segments.isEmpty, "\(uri)")
            #expect(parsed.warnings.isEmpty, "\(uri): \(parsed.warnings)")
            #expect(try Playlist(media.render()).media == media, "\(uri)")
        }
    }
}
