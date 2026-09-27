# HLSPlaylist

[![CI](https://github.com/CreatureSurvive/HLSPlaylist/actions/workflows/ci.yml/badge.svg)](https://github.com/CreatureSurvive/HLSPlaylist/actions/workflows/ci.yml)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-blue)](#requirements)
[![Swift Package Manager](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](#installation)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

A fast, lossless, pure-Swift parser and writer for HTTP Live Streaming (`.m3u8`) playlists.

HLSPlaylist covers the full tag set of RFC 8216 and its successor
[draft-pantos-hls-rfc8216bis](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/),
including Low-Latency HLS, variable substitution, content steering, date ranges and multiple DRM
keys. It has no dependencies, is `Sendable` throughout, and runs on every Apple platform.

```swift
import HLSPlaylist

let playlist = try Playlist(data: data)

switch playlist {
case .multivariant(let master):
    let best = master.preferredVariant(maxResolution: Resolution(width: 1920, height: 1080))
    let audio = master.audioRenditions(for: best!)
case .media(let media):
    print(media.duration, media.isLive, media.segments.count)
}
```

## Why

AVFoundation plays HLS but gives you no way to *read or write* a playlist. Apps end up needing
to do that for a lot of reasons:

- rewriting segment URLs for a local proxy, `AVAssetResourceLoader`, or signed CDN tokens
- choosing a variant or audio/subtitle rendition yourself (for example for Chromecast, downloads,
  or custom players)
- building offline or DVR playlists, stitching ads, or trimming live windows
- reading `EXT-X-PROGRAM-DATE-TIME` or `EXT-X-DATERANGE` (SCTE-35) for live TV guides and ad markers
- validating or debugging a media server's output

The existing Swift options are unmaintained (last updated 2017–2019), partial (media playlists
only, no LL-HLS), or Objective-C.

## Features

- **Complete model**: multivariant playlists (variants, I-frame variants, renditions, session
  data and keys, content steering) and media playlists (segments, byte ranges, key rotation,
  init sections, discontinuities, program date-time, date ranges, gaps, bitrate, partial segments,
  server control, skip, preload hints, rendition reports).
- **Lossless round-trips**: unknown tags and unmodeled attributes are preserved in place, and
  quoted and unquoted values stay distinct. `parse → render → parse` is identity. This is verified
  against Apple's reference streams.
- **Effective state**: each segment carries the keys and `EXT-X-MAP` in effect for it, and the
  writer emits them only where they change.
- **Variable substitution**: `EXT-X-DEFINE` with `NAME`/`VALUE`, `IMPORT` and `QUERYPARAM`.
- **Lenient by default, strict on request**: problems are collected as `ParseWarning`s, and
  `ParseOptions(strict: true)` throws instead. Handles BOMs, CRLF, whitespace, unterminated quotes
  and colon-less time-zone offsets.
- **Utilities**: variant selection, rendition lookup, codec classification, segment timing and
  lookup by time, program-date-time extrapolation, live offset (`HOLD-BACK`/`PART-HOLD-BACK`),
  IV derivation, URI resolution and rewriting.
- **Fast**: 20,000 segments with program-date-times parse in about 0.25 s (release build).
  Dates use an allocation-free ISO 8601 fast path.

## Installation

Add HLSPlaylist to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/CreatureSurvive/HLSPlaylist.git", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["HLSPlaylist"]),
]
```

Or in Xcode, choose **File › Add Package Dependencies…** and enter
`https://github.com/CreatureSurvive/HLSPlaylist`.

### Requirements

| Platform | Minimum |
| --- | --- |
| iOS | 15.0 |
| macOS | 12.0 |
| tvOS | 15.0 |
| watchOS | 8.0 |
| visionOS | 1.0 |

Swift 6.0 (Xcode 16) or later, in Swift 6 language mode. No third-party dependencies.

## Usage

### Parsing

```swift
let playlist = try Playlist(text)                        // String
let playlist = try Playlist(data: data)                  // Data

// Warnings, variables and options
let result = try PlaylistParser(options: ParseOptions(
    strict: false,
    importedVariables: masterResult.variables,           // for EXT-X-DEFINE:IMPORT
    playlistURL: url                                     // for EXT-X-DEFINE:QUERYPARAM
)).parse(data)
result.warnings.forEach { print($0) }
```

### Selecting streams

```swift
let master = try Playlist(data: data).multivariant!

let variant = master.preferredVariant(
    maxBandwidth: 6_000_000,
    maxResolution: Resolution(width: 1920, height: 1080),
    isCodecSupported: { CodecFamily(codec: $0) != .av1 }
)
let audioTracks = master.audioRenditions(for: variant!)       // [Rendition]
let subtitles = master.subtitleRenditions(for: variant!)
```

### Media playlists

```swift
let media = try Playlist(data: data).media!

media.duration                  // total seconds
media.isLive                    // no ENDLIST and not VOD
media.segmentIndex(containing: 125.0)
media.programDateTimes          // wall-clock time for every segment
media.recommendedLiveOffset     // HOLD-BACK, PART-HOLD-BACK or 3 × target duration

for segment in media.segments where segment.isEncrypted {
    print(segment.uri, segment.keys.map(\.method), segment.map?.uri ?? "-")
}
```

### Rewriting URIs (proxies, tokens, offline playback)

```swift
let proxied = media.mapURIs { uri, role in
    switch role {
    case .key: return uri                         // leave keys alone
    default: return "http://127.0.0.1:8080/proxy?u=\(uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
    }
}
let text = proxied.render()

let absolute = master.resolvingURIs(against: masterURL)
```

### Writing

```swift
var playlist = MediaPlaylist(targetDuration: 6, playlistType: .vod, hasEndList: true, version: 3)
playlist.segments = files.map { Segment(uri: $0.name, duration: $0.duration) }
try playlist.render().write(to: outputURL, atomically: true, encoding: .utf8)
```

## Design notes

- Typed properties are the source of truth. Anything this library doesn't model lands in
  `otherAttributes` (per tag) or `unknownTags` (per position), so vendor extensions such as
  `#EXT-X-CUE-OUT` or `#EXT-X-PLEX-*` survive editing.
- `Segment.keys` models the effective key set, so multiple `KEYFORMAT`s (FairPlay plus Widevine)
  can coexist, and `METHOD=NONE` clears them.
- Partial segments are attached to the segment they complete. Parts at the live edge are in
  `MediaPlaylist.trailingParts`.

## Testing

`swift test` runs the unit suite: spec fixtures, round-trips, key rotation, LL-HLS, variable
substitution, date edge cases, and a 20k-segment performance check.
`HLS_LIVE_TESTS=1 swift test` also fetches, parses and round-trips every playlist in Apple's public
example streams.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Releases follow [Semantic Versioning](https://semver.org).

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a pull request, and
add tests for new behavior.

## License

Available under the MIT license. See [LICENSE](LICENSE) for details.
